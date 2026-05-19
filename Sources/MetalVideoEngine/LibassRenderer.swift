import Foundation
import CLibass
import CoreGraphics
import CoreText
import Metal

/// Thin Swift wrapper over libass (Homebrew 0.17.4). Renders ASS subtitle
/// frames into a pre-allocated BGRA buffer that the Metal compositor uploads
/// as a single overlay texture per video frame.
///
/// Why this exists: ffmpeg's `ass=` filter is libass, the browser preview
/// (JASSUB) is libass, and historically the Metal engine was the odd one
/// out — it rasterized SRT through CoreText to approximate the libass look.
/// Wiring real libass into Swift puts all three paths on the same renderer,
/// unlocks karaoke (`\k`, `\kf`) and override tags (`\pos`, `\fad`, `\c`),
/// and deletes the two-pass ffmpeg burn stage entirely.
///
/// Lifecycle:
///   let r = try LibassRenderer(canvasWidth: 1080, canvasHeight: 1920)
///   try r.loadTrack(content: assDocumentString)
///   if let blit = try r.render(timeMs: 1234) { /* upload blit.bytes */ }
///   // ...
///   // ARC handles ass_*_done() via deinit.
///
/// Threading: not thread-safe. Use one renderer per render job; the engine's
/// frame loop is single-threaded for the composite leg anyway.
///
/// Font discovery: we ask libass to use the CoreText font provider. Callers
/// must register their TTFs via `CTFontManagerRegisterFontsForURL(_:.process,_)`
/// (Fonts.swift in this project did this previously; the engine should do
/// the same registration before the first `render(timeMs:)` call).
public final class LibassRenderer {

    /// One rendered frame ready to upload to an MTLTexture. The buffer is
    /// BGRA8 premultiplied — same layout as the existing overlay textures
    /// produced by `Overlay.textureFromBGRABytes`.
    public struct Frame {
        public let width: Int
        public let height: Int
        public let bytes: [UInt8]   // BGRA, row-major, top-down
    }

    // MARK: - Lifecycle

    // libass declares ASS_Library and ASS_Renderer as forward-declared
    // opaque structs in ass_types.h — Swift imports incomplete-type
    // pointers as OpaquePointer. ASS_Track is a *complete* struct (the
    // header exposes its fields), so Swift imports it as a typed
    // UnsafeMutablePointer.
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    /// Keep the ASS document alive for the lifetime of the track. libass'
    /// `ass_read_memory` is documented to copy the buffer, but we hold a
    /// reference anyway to make the ownership story unambiguous.
    private var trackBuffer: [CChar] = []

    /// Reused MTLTexture sized to the canvas. Allocating a fresh ~8MB
    /// texture per frame would dominate the overlay path's cost on a
    /// fast Metal pipeline; reusing one keeps the IOSurface hot and the
    /// per-frame upload down to a single `replace(region:)` memcpy on
    /// UMA hardware. Created lazily on the first `renderTexture(...)`
    /// call (we don't have a device at init time).
    private var cachedTexture: MTLTexture?

    public let canvasWidth: Int
    public let canvasHeight: Int

    public init(canvasWidth: Int, canvasHeight: Int) throws {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight

        guard let lib = ass_library_init() else {
            throw MVEError.pipelineStateFailed("libass: ass_library_init failed")
        }
        self.library = lib

        guard let rend = ass_renderer_init(lib) else {
            ass_library_done(lib)
            self.library = nil
            throw MVEError.pipelineStateFailed("libass: ass_renderer_init failed")
        }
        self.renderer = rend

        // Frame size = video canvas. Storage size matches; we don't do
        // anamorphic source video here so par stays 1:1.
        ass_set_frame_size(rend, Int32(canvasWidth), Int32(canvasHeight))
        ass_set_storage_size(rend, Int32(canvasWidth), Int32(canvasHeight))

        // CoreText font provider. The 4th arg is ASS_FONTPROVIDER_CORETEXT.
        // `default_font` and `default_family` are the fallback used when
        // an event's font name isn't found in the registry — Helvetica is
        // ubiquitous so the fallback never produces unstyled glyphs.
        // `config` is fontconfig path; nil with CoreText.
        // `update` = 1 → libass loads the font system now.
        ass_set_fonts(
            rend,
            "Helvetica",          // default_font (fallback)
            "sans-serif",         // default_family
            Int32(ASS_FONTPROVIDER_CORETEXT.rawValue),
            nil,                  // fontconfig config (unused with CoreText)
            1                     // update font cache now
        )
    }

    deinit {
        if let t = track       { ass_free_track(t) }
        if let r = renderer    { ass_renderer_done(r) }
        if let l = library     { ass_library_done(l) }
    }

    // MARK: - Track loading

    /// Replace the active subtitle track. The caller's ASS string is
    /// converted to UTF-8 bytes and handed to `ass_read_memory`.
    public func loadTrack(content: String) throws {
        if let old = track {
            ass_free_track(old)
            track = nil
        }
        guard let lib = library else {
            throw MVEError.pipelineStateFailed("libass: loadTrack called on torn-down renderer")
        }

        // Convert to a mutable CChar buffer. ass_read_memory's signature
        // takes `char *` (not `const char *`); libass historically reused
        // the buffer briefly as a working area, so we hand it a copy we
        // own.
        let bytes = Array(content.utf8).map { CChar(bitPattern: $0) }
        trackBuffer = bytes
        let count = bytes.count
        let t = trackBuffer.withUnsafeMutableBufferPointer { buf in
            return ass_read_memory(lib, buf.baseAddress, count, nil)
        }
        guard let newTrack = t else {
            throw MVEError.pipelineStateFailed("libass: ass_read_memory returned NULL")
        }
        self.track = newTrack
    }

    // MARK: - Per-frame render

    /// Composite one rendered subtitle frame at `timeMs` into a BGRA buffer.
    /// Returns nil when libass produced no images for this PTS (no active
    /// cue) — the caller can skip the overlay composite entirely.
    public func render(timeMs: Int64) throws -> Frame? {
        guard let rend = renderer, let trk = track else {
            throw MVEError.pipelineStateFailed("libass: render called before loadTrack")
        }

        // detect_change is informational only; we recompose every frame
        // because integrating change-tracking into the engine's command-buffer
        // model isn't worth the complexity at our framerates.
        var detectChange: Int32 = 0
        guard let head = ass_render_frame(rend, trk, timeMs, &detectChange) else {
            return nil
        }

        // Pre-zero a BGRA destination buffer at canvas size. For a 1080×1920
        // frame that's ~8 MB; we allocate per call because the engine's
        // frame loop holds onto returned Frame values briefly and the GC
        // pressure is dwarfed by the GPU command buffer work.
        let stride = canvasWidth * 4
        var dst = [UInt8](repeating: 0, count: canvasHeight * stride)

        // Walk the linked list of ASS_Image. Each entry is an 8-bit alpha
        // bitmap + RGBA color (libass packs RGBA into a single uint32 with
        // A as inverted opacity: 0 = fully opaque, 255 = fully transparent).
        // We alpha-blend each one into `dst` using the standard "src-over"
        // composition: out = src + dst * (1 - src.a).
        var node: UnsafeMutablePointer<ASS_Image>? = head
        while let n = node {
            let img = n.pointee
            blendASSImage(img, into: &dst, dstStride: stride)
            node = img.next
        }

        return Frame(width: canvasWidth, height: canvasHeight, bytes: dst)
    }

    /// Render and upload to a cached MTLTexture in one call. Returns
    /// nil when no cue is active at `timeMs` — the caller's overlay
    /// composite should be skipped entirely (don't blend a zero
    /// texture, that's a redundant ~2M-pixel pass).
    ///
    /// The returned texture is owned by `LibassRenderer` and is reused
    /// across calls. Don't hold it past the next `renderTexture(...)`
    /// invocation — its contents will be overwritten.
    public func renderTexture(timeMs: Int64, device: MTLDevice) throws -> MTLTexture? {
        guard let f = try render(timeMs: timeMs) else { return nil }
        let tex = try ensureCachedTexture(device: device)
        let bytesPerRow = f.width * 4
        let region = MTLRegionMake2D(0, 0, f.width, f.height)
        f.bytes.withUnsafeBytes { ptr in
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: ptr.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return tex
    }

    private func ensureCachedTexture(device: MTLDevice) throws -> MTLTexture {
        if let t = cachedTexture { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canvasWidth, height: canvasHeight, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else {
            throw MVEError.pipelineStateFailed("libass: cannot allocate cached texture")
        }
        cachedTexture = t
        return t
    }
}

// MARK: - private blit

/// Composite a single ASS_Image onto the BGRA destination buffer.
///
/// The ASS_Image format:
///   - `bitmap` is an 8-bit alpha mask, `w` × `h`, stride `stride`.
///   - `color` packs RGBA with A as INVERTED opacity (0=opaque, 255=transparent).
///   - `dst_x`/`dst_y` is where the bitmap's top-left lands in the frame.
///
/// We src-over blend per pixel:
///   final_alpha = (mask / 255) * ((255 - A_inv) / 255)
///   out.bgr = src.bgr * final_alpha + dst.bgr * (1 - final_alpha)
///   out.a   = clamp(src.a * final_alpha + dst.a * (1 - final_alpha), 0, 255)
///
/// We write premultiplied BGRA8 (`premultipliedFirst + byteOrder32Little`) —
/// the exact format Metal's overlay shader samples via the existing
/// `Overlay.textureFromBGRABytes` upload path.
@inline(__always)
private func blendASSImage(
    _ img: ASS_Image,
    into dst: inout [UInt8],
    dstStride: Int
) {
    let w = Int(img.w)
    let h = Int(img.h)
    if w <= 0 || h <= 0 { return }
    let srcStride = Int(img.stride)
    let dstX = Int(img.dst_x)
    let dstY = Int(img.dst_y)

    // Unpack the libass color word. The fields are big-endian-packed into
    // a uint32: byte 3 = R, byte 2 = G, byte 1 = B, byte 0 = A_inverted.
    let c = img.color
    let srcR = UInt32((c >> 24) & 0xFF)
    let srcG = UInt32((c >> 16) & 0xFF)
    let srcB = UInt32((c >>  8) & 0xFF)
    let aInv = UInt32(c & 0xFF)
    // Skip fully-transparent draws — libass occasionally emits them.
    if aInv >= 255 { return }
    let colorAlpha = 255 - aInv   // 0..255 opaque scale

    guard let srcBase = img.bitmap else { return }

    let dstWidth = dstStride / 4
    let dstHeight = dst.count / dstStride

    dst.withUnsafeMutableBufferPointer { dstBuf in
        for row in 0..<h {
            let y = dstY + row
            if y < 0 || y >= dstHeight { continue }
            for col in 0..<w {
                let x = dstX + col
                if x < 0 || x >= dstWidth { continue }
                let maskByte = UInt32(srcBase[row * srcStride + col])
                if maskByte == 0 { continue }
                // final alpha in 0..65025 = maskByte * colorAlpha
                let a16 = maskByte * colorAlpha
                if a16 == 0 { continue }
                // Premultiplied src bytes in /65025 scale (8 bits effective).
                let sR = (srcR * a16) / 255
                let sG = (srcG * a16) / 255
                let sB = (srcB * a16) / 255
                let sA = a16 / 255
                let invA = 255 - sA   // for the dst contribution

                let off = y * dstStride + x * 4
                // BGRA premultipliedFirst + byteOrder32Little layout:
                //   byte 0 = B, byte 1 = G, byte 2 = R, byte 3 = A
                let dB = UInt32(dstBuf[off + 0])
                let dG = UInt32(dstBuf[off + 1])
                let dR = UInt32(dstBuf[off + 2])
                let dA = UInt32(dstBuf[off + 3])

                let oB = sB + (dB * invA) / 255
                let oG = sG + (dG * invA) / 255
                let oR = sR + (dR * invA) / 255
                let oA = sA + (dA * invA) / 255

                dstBuf[off + 0] = UInt8(min(255, oB))
                dstBuf[off + 1] = UInt8(min(255, oG))
                dstBuf[off + 2] = UInt8(min(255, oR))
                dstBuf[off + 3] = UInt8(min(255, oA))
            }
        }
    }
}
