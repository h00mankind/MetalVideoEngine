import Foundation
import Metal
import CoreText
import CoreGraphics
import ImageIO

/// Static-overlay helpers — text + image rasterization into MTLTextures
/// the engine composites onto every frame in pass 3.
///
/// CoreText rasterizes branding text (channel name + extra texts) at
/// canvas resolution, with the same shadow + optional pill background
/// the ffmpeg drawtext filter produced. Output is a transparent BGRA
/// texture sized to the glyph bounds — the engine composites it at the
/// numpad-anchor rect via `graph.composite`.
///
/// Logo loading reads the user-uploaded PNG/JPG into a BGRA MTLTexture,
/// also at the destination-rect resolution (scaled once at job start,
/// so the per-frame composite doesn't redo the bilinear filter).
public enum Overlay {

    // ── Anchor math ────────────────────────────────────────────────────
    //
    // 9-cell numpad anchor map. Indices 1..9 map to the keypad layout:
    //
    //   7  8  9   (top-left,    top-center,    top-right)
    //   4  5  6   (middle-left, middle-center, middle-right)
    //   1  2  3   (bottom-left, bottom-center, bottom-right)
    //
    // Same map ffmpeg's pipeline uses via WATERMARK_CORNERS /
    // CHANNEL_NAME_POSITIONS. We hand-roll the conversion here so the
    // overlay shape (origin + size) is in dst pixels — the format
    // FilterGraph.composite already expects.

    /// 3% safe-area inset on each axis, in PlayRes (1080×1920) pixels.
    /// Matches `INSET_X` / `INSET_Y` in src/lib/server/staticOverlay.ts.
    public static let safeAreaInsetX: Float = 32
    public static let safeAreaInsetY: Float = 58

    /// Compute the dst-pixel origin for an overlay of size `size` on a
    /// canvas of size `canvas`, anchored at numpad position `position`
    /// (1..9) with `offset` applied in PlayRes pixels. The result is
    /// clamped so the overlay never leaves the frame regardless of how
    /// the user nudges it.
    ///
    /// `canvas` is the render frame (1080×1920 at 1080p). Insets scale
    /// linearly when `canvas != PlayRes`, so a 720p render gets a
    /// proportional safe area without separate math.
    public static func anchorRect(
        size: SIMD2<Float>,
        canvas: SIMD2<Float>,
        position: Int,
        offset: SIMD2<Float>
    ) -> SIMD2<Float> {
        // Scale the PlayRes inset to the actual canvas. At 1080p the
        // ratio is 1.0; at 720p it's ~0.667.
        let kx = canvas.x / 1080
        let ky = canvas.y / 1920
        let insetX = safeAreaInsetX * kx
        let insetY = safeAreaInsetY * ky

        let xLeft: Float = insetX
        let xCenter: Float = (canvas.x - size.x) / 2
        let xRight: Float = canvas.x - size.x - insetX
        let yTop: Float = insetY
        let yMiddle: Float = (canvas.y - size.y) / 2
        let yBottom: Float = canvas.y - size.y - insetY

        let baseX: Float
        let baseY: Float
        switch position {
        case 7: baseX = xLeft;   baseY = yTop
        case 8: baseX = xCenter; baseY = yTop
        case 9: baseX = xRight;  baseY = yTop
        case 4: baseX = xLeft;   baseY = yMiddle
        case 5: baseX = xCenter; baseY = yMiddle
        case 6: baseX = xRight;  baseY = yMiddle
        case 1: baseX = xLeft;   baseY = yBottom
        case 2: baseX = xCenter; baseY = yBottom
        case 3: baseX = xRight;  baseY = yBottom
        default: baseX = xCenter; baseY = yBottom  // safest fallback
        }
        // Same clamp the ffmpeg pipeline applies via clip(...). User
        // offsets are in PlayRes pixels — scale them to the actual
        // canvas first so a 720p render doesn't over-nudge.
        let dx = offset.x * kx
        let dy = offset.y * ky
        let x = max(0, min(canvas.x - size.x, baseX + dx))
        let y = max(0, min(canvas.y - size.y, baseY + dy))
        return SIMD2<Float>(x, y)
    }

    // ── Image loading ──────────────────────────────────────────────────

    /// Load a PNG/JPG from disk into a bgra8Unorm MTLTexture sized at
    /// the natural resolution of the source image. Caller scales /
    /// composites the result via `graph.composite` — this just hands
    /// over the raw pixel buffer.
    public static func loadImage(path: String, device: MTLDevice) throws -> MTLTexture {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw MVEError.pipelineStateFailed("Overlay.loadImage: cannot read \(path)")
        }
        return try textureFromCGImage(cg, device: device)
    }

    /// Wrap a CGImage as an MTLTexture (bgra8Unorm, premultipliedFirst,
    /// byteOrder32Little). Reused by `loadImage` + `rasterizeText` so
    /// both surfaces produce textures the engine's composite shader
    /// already knows how to read.
    public static func textureFromCGImage(_ cg: CGImage, device: MTLDevice) throws -> MTLTexture {
        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bm = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bm.rawValue
        ) else {
            throw MVEError.pipelineStateFailed("Overlay.textureFromCGImage: CGContext failed")
        }
        // Y-flip so the texture lands top-down (Metal sample convention)
        // regardless of the CGImage's underlying orientation.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw MVEError.pipelineStateFailed("Overlay.textureFromCGImage: makeTexture failed")
        }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: bytesPerRow
        )
        return tex
    }

    // ── Text rasterization (channel name + extra texts) ───────────────

    /// Optional background pill drawn behind the glyphs — opacity-baked
    /// colour + corner radius. The ffmpeg drawtext filter draws this
    /// via `box=1:boxcolor=…:boxborderw=12`; CoreText draws it as a
    /// filled rounded rect.
    public struct TextStyle {
        public struct Background {
            public var color: SIMD4<Float>   // RGB + alpha
            public var cornerRadius: CGFloat
            public init(color: SIMD4<Float>, cornerRadius: CGFloat) {
                self.color = color; self.cornerRadius = cornerRadius
            }
        }
        public var fontName: String
        public var fontSize: CGFloat
        public var color: SIMD4<Float>       // RGB + alpha
        public var bold: Bool
        public var shadow: Bool              // drop shadow on/off
        public var background: Background?

        public init(
            fontName: String = "Z06-Walone Bold",
            fontSize: CGFloat = 56,
            color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
            bold: Bool = true,
            shadow: Bool = true,
            background: Background? = nil
        ) {
            self.fontName = fontName; self.fontSize = fontSize
            self.color = color; self.bold = bold
            self.shadow = shadow; self.background = background
        }
    }

    /// Rasterize a single line of text into a transparent BGRA MTLTexture
    /// sized to glyph bounds + padding for shadow / pill margins. The
    /// engine composites the returned texture at a destination rect the
    /// host computes via `anchorRect(...)`.
    public static func rasterizeText(
        _ text: String,
        style: TextStyle,
        device: MTLDevice
    ) throws -> MTLTexture {
        // Resolve the font with bold trait. CoreText needs an explicit
        // trait apply when the family alone doesn't carry a bold member.
        let baseDesc = CTFontDescriptorCreateWithNameAndSize(style.fontName as CFString, style.fontSize)
        let desc: CTFontDescriptor
        if style.bold,
           let withTraits = CTFontDescriptorCreateCopyWithSymbolicTraits(baseDesc, .boldTrait, .boldTrait) {
            desc = withTraits
        } else {
            desc = baseDesc
        }
        let font = CTFontCreateWithFontDescriptor(desc, style.fontSize, nil)

        // Build the attributed string. Foreground colour + font are the
        // only attributes — single line, no paragraph styling.
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): srgbCGColor(style.color),
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)

        // Measure the glyph run. We use CTLine which is a single-line
        // typesetter — channel names + branding texts are never wrapped.
        let line = CTLineCreateWithAttributedString(attr)
        let typoBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textW = max(2, ceil(typoBounds.width))
        // CTLineGetBounds returns origin.y = -descent, height = ascent +
        // descent. We need the full height including descender bowls so
        // glyphs like 'y' / 'g' don't clip at the bottom.
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let textH = ceil(ascent + descent)

        // Padding budget for shadow + pill. Shadow offset (0, 2) means
        // we need 2 extra pixels below; pill bg adds `boxborderw=12` on
        // every side, matching the ffmpeg drawtext convention.
        let shadowPad: CGFloat = style.shadow ? 4 : 0
        let bgPad: CGFloat = style.background != nil ? 12 : 0
        let totalPad = shadowPad + bgPad
        let w = Int(textW + 2 * totalPad)
        let h = Int(textH + 2 * totalPad)

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bm = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: bm.rawValue
        ) else {
            throw MVEError.pipelineStateFailed("Overlay.rasterizeText: CGContext failed")
        }
        // Y-flip so the texture is top-down for the engine's sampler.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)

        // Pill background, drawn first so text + shadow paint on top.
        if let bg = style.background {
            let pillRect = CGRect(
                x: shadowPad,
                y: shadowPad,
                width: textW + 2 * bgPad,
                height: textH + 2 * bgPad
            )
            cg.setFillColor(srgbCGColor(bg.color))
            if bg.cornerRadius > 0 {
                let p = CGPath(roundedRect: pillRect,
                               cornerWidth: bg.cornerRadius,
                               cornerHeight: bg.cornerRadius,
                               transform: nil)
                cg.addPath(p); cg.fillPath()
            } else {
                cg.fill(pillRect)
            }
        }

        // Shadow setup — the next draw call inherits the shadow.
        // Offset matches the ffmpeg drawtext defaults (shadowx=0,
        // shadowy=2) so the two paths look visually identical for the
        // default "shadow on" case. CG y grows up; positive shadowY in
        // our convention (drop below the glyph) maps to a NEGATIVE CG
        // offset because the surrounding CTM flip inverts axis sign.
        if style.shadow {
            cg.setShadow(
                offset: CGSize(width: 0, height: -2),
                blur: 0,
                color: srgbCGColor(SIMD4<Float>(0, 0, 0, 0.6))
            )
        }

        // Draw the line. textPosition is in CG-y-up coordinates; we
        // offset by descent so the baseline sits where we want.
        cg.textPosition = CGPoint(x: totalPad, y: totalPad + descent)
        CTLineDraw(line, cg)

        guard let cgImage = cg.makeImage() else {
            throw MVEError.pipelineStateFailed("Overlay.rasterizeText: makeImage failed")
        }
        return try textureFromCGImage(cgImage, device: device)
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private static func srgbCGColor(_ v: SIMD4<Float>) -> CGColor {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let comps: [CGFloat] = [CGFloat(v.x), CGFloat(v.y), CGFloat(v.z), CGFloat(v.w)]
        return CGColor(colorSpace: cs, components: comps)!
    }
}
