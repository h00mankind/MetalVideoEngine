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

    /// Ring of canvas-sized MTLTextures for `renderTexture`. Allocating
    /// a fresh ~8MB texture per frame would dominate the overlay path's
    /// cost, but a SINGLE reused texture is racy: the engine keeps up
    /// to `maxInflight` (default 5) command buffers in flight, each
    /// sampling the texture we returned for its frame, so `replace()`
    /// must never touch bytes the GPU may still read. We rotate to the
    /// next ring slot on every re-upload; `ringSize` of 8 covers the
    /// default inflight depth with headroom even when every frame
    /// changes (karaoke sweeps). Slots allocate lazily — a render whose
    /// captions change rarely only ever creates one or two.
    private var textureRing: [MTLTexture] = []
    private var ringCursor = 0
    private let ringSize = 8

    /// detect_change cache: the texture (or nil for "no active cue")
    /// returned by the previous `renderTexture` call. When libass
    /// reports the frame is unchanged, this is returned as-is and the
    /// CPU blend + ~8MB upload are skipped entirely.
    private var lastTexture: MTLTexture?
    private var hasRenderedOnce = false

    /// Reused CPU compose buffer (canvas-sized BGRA). Zeroed and
    /// re-blended only on frames where libass reports a change, instead
    /// of allocating ~8MB per frame.
    private var scratch: [UInt8] = []

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
        // frame that's ~8 MB; we allocate per call because this path is
        // probe-only (`mve libass`) — the engine's per-frame path is
        // `renderTexture`, which reuses a scratch buffer.
        let stride = canvasWidth * 4
        var dst = [UInt8](repeating: 0, count: canvasHeight * stride)
        composeImages(head, into: &dst, stride: stride)
        return Frame(width: canvasWidth, height: canvasHeight, bytes: dst)
    }

    /// Render and upload to a pooled MTLTexture in one call. Returns
    /// nil when no cue is active at `timeMs` — the caller's overlay
    /// composite should be skipped entirely (don't blend a zero
    /// texture, that's a redundant ~2M-pixel pass).
    ///
    /// Fast path: libass's `detect_change` flag tells us when the
    /// composite at `timeMs` is pixel-identical to the previous call's
    /// (the common case — caption cues hold for seconds at a time). We
    /// return the previously uploaded texture untouched and skip the
    /// CPU blend and the ~8MB texture upload entirely.
    ///
    /// The returned texture is owned by `LibassRenderer`. It stays
    /// valid (contents frozen) while in flight: re-uploads rotate
    /// through a small ring rather than overwriting the texture earlier
    /// frames may still be sampling.
    public func renderTexture(timeMs: Int64, device: MTLDevice) throws -> MTLTexture? {
        guard let rend = renderer, let trk = track else {
            throw MVEError.pipelineStateFailed("libass: renderTexture called before loadTrack")
        }
        var detectChange: Int32 = 0
        let head = ass_render_frame(rend, trk, timeMs, &detectChange)
        // detect_change == 0 → libass guarantees this frame's output is
        // identical to the previous ass_render_frame call's. Reuse the
        // cached result (including a cached "no cue" nil).
        if hasRenderedOnce && detectChange == 0 { return lastTexture }
        hasRenderedOnce = true

        guard let head else {
            lastTexture = nil
            return nil
        }

        // Changed content — recompose on the CPU into the reused
        // scratch buffer, then upload into the next ring slot.
        let stride = canvasWidth * 4
        let byteCount = canvasHeight * stride
        if scratch.count != byteCount {
            scratch = [UInt8](repeating: 0, count: byteCount)
        } else {
            scratch.withUnsafeMutableBytes { ptr in
                _ = memset(ptr.baseAddress!, 0, ptr.count)
            }
        }
        composeImages(head, into: &scratch, stride: stride)

        let tex = try nextRingTexture(device: device)
        let region = MTLRegionMake2D(0, 0, canvasWidth, canvasHeight)
        scratch.withUnsafeBytes { ptr in
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: ptr.baseAddress!, bytesPerRow: stride)
        }
        lastTexture = tex
        return tex
    }

    /// Walk the ASS_Image linked list and src-over blend each glyph
    /// bitmap into `dst`. Shared by the probe path (`render`) and the
    /// engine path (`renderTexture`).
    private func composeImages(
        _ head: UnsafeMutablePointer<ASS_Image>,
        into dst: inout [UInt8],
        stride: Int
    ) {
        var node: UnsafeMutablePointer<ASS_Image>? = head
        while let n = node {
            let img = n.pointee
            blendASSImage(img, into: &dst, dstStride: stride)
            node = img.next
        }
    }

    private func nextRingTexture(device: MTLDevice) throws -> MTLTexture {
        if textureRing.count < ringSize {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: canvasWidth, height: canvasHeight, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let t = device.makeTexture(descriptor: desc) else {
                throw MVEError.pipelineStateFailed("libass: cannot allocate ring texture")
            }
            textureRing.append(t)
            return t
        }
        // Ring full — recycle the least-recently-uploaded slot.
        let t = textureRing[ringCursor]
        ringCursor = (ringCursor + 1) % ringSize
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
                // Coverage alpha α = (maskByte/255)·(colorAlpha/255).
                // a16 = maskByte·colorAlpha ∈ 0..65025, so α = a16/65025.
                let a16 = maskByte * colorAlpha
                if a16 == 0 { continue }
                // Premultiplied src channels = srcChannel · α, in 0..255.
                // This MUST divide by 65025 (= 255·255), not 255: srcR is
                // 0..255 and a16 is 0..65025, so (srcR·a16)/255 overshoots
                // by 255× and clamps to full saturation — which blew out
                // every anti-aliased edge pixel to a hard opaque colour
                // and is what made the captions look jagged / not crisp.
                // Dividing by 65025 preserves the partial-coverage edge
                // gradients libass produces.
                let sR = (srcR * a16) / 65025
                let sG = (srcG * a16) / 65025
                let sB = (srcB * a16) / 65025
                // Premultiplied src alpha = 255·α = a16/255 (255·255/255).
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
