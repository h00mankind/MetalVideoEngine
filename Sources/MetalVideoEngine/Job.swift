import Foundation
import simd

/// JSON-driven render spec for the Metal *base* pass of the hybrid
/// pipeline. Captions, logo overlays, and text branding are NOT in
/// scope — those layers are owned by the downstream ffmpeg burn stage
/// (`render-final-burn` in stages.ts) that reads the intermediate this
/// pass writes.
///
/// All paths are absolute. Field shapes deliberately mirror the
/// production project model (BypassSettings, etc.) so the JS-side
/// serializer is a thin field-by-field copy.
///
/// Optional fields are omitted (or `null`) when not needed. The
/// renderer treats every section as opt-in — a job with only `input` /
/// `output` / `preset` set produces a clean letterbox render with no
/// bypass and no audio.
public struct JobSpec: Codable {
    public var input: String
    public var output: String
    public var preset: String           // "720p" | "1080p" | "<W>x<H>"
    public var bitrate: Int?            // average bitrate, bits/sec
    /// Peak bitrate cap, bits/sec. Caps the instantaneous rate so a
    /// busy scene doesn't blow out into a spike the downstream
    /// social-platform re-encoder can't fit. Defaults to 1.5× bitrate.
    public var peakBitrate: Int?
    /// `delivery` (default) — B-frames on, peak-cap on. Final renders
    /// for social platforms. `draft` — B-frames off, no peak cap.
    /// Faster wall-time at ~8% lower visual quality.
    public var quality: String?         // "delivery" | "draft"
    public var codec: String?           // "h264" | "hevc" | "prores422hq" (default h264)
    public var maxInflight: Int?        // default 3

    public var grade: GradeSpec?
    public var bypass: BypassSpec?
    public var lutPath: String?         // .cube file
    public var subtitles: SubtitlesSpec?
    public var overlays: [OverlaySpec]? // logo PNG(s)
    public var texts: [TextSpec]?       // channel name + extra texts
    public var audio: AudioSpec?

    /// Single-frame mode override. When the engine is invoked as
    /// `mve frame <spec.json>`, this block tells it which PTS
    /// to seek to and where to write the PNG. `output` is ignored in
    /// that mode (no mp4 produced). When the engine is invoked via
    /// `mve job <spec.json>` this block is ignored.
    public var frame: FrameSpec?

    public struct FrameSpec: Codable {
        public var atSeconds: Double
        public var outPath: String      // absolute .png path
    }

    public struct GradeSpec: Codable {
        public var brightness: Float?
        public var contrast: Float?
        public var saturation: Float?
        public var tint: Float?
        public var lutMix: Float?
    }

    public struct BypassSpec: Codable {
        public var mirror: Bool?
        public var zoom: Float?
        public var cropPct: Float?      // 0..6 percent
        public var colorTintDeg: Float? // degrees; converted to radians
        public var noise: Float?
        public var grain: Float?
        public var edgeBlur: Float?
        public var edgeBlurBand: Float?
        public var speed: Float?        // PTS warp; reserved for future use
    }

    /// Subtitle burn spec. libass parses the ASS document itself — every
    /// style (font, size, colours, outline, shadow, MarginV, alignment,
    /// karaoke tags) lives inside the ASS file. The engine just needs:
    ///   - `assPath`: absolute path to the ASS document the Node bridge
    ///     wrote (same `aligned.ass` ffmpeg fallback + JASSUB preview consume)
    ///   - `fontsDir`: directory of project TTFs to register with CoreText
    ///     before rasterizing. Without registration libass falls back to
    ///     Helvetica when the ASS Style block references a non-system
    ///     font name (e.g. `Z06-Walone`).
    public struct SubtitlesSpec: Codable {
        public var assPath: String
        public var fontsDir: String?
    }

    /// Image overlay (typically the user's logo/watermark). The engine
    /// scales the image to `widthFraction * canvas.width`, places it at
    /// the numpad `anchor` cell + (offsetX, offsetY) PlayRes pixels, and
    /// composites at the configured opacity. Output aspect ratio is
    /// preserved — height derives from the loaded image's natural ratio.
    public struct OverlaySpec: Codable {
        public var imagePath: String
        public var anchor: Int?         // numpad 1..9
        public var offsetX: Float?      // PlayRes pixels (1080×1920)
        public var offsetY: Float?
        public var widthFraction: Float? // 0..1 of canvas width
        public var opacity: Float?      // 0..1
    }

    /// Single-line text overlay (channel name + extra texts). Rendered
    /// via CoreText at the engine, with the same shadow + optional pill
    /// background the ffmpeg drawtext pipeline produces. fontPath is
    /// registered with CTFontManager before rasterizing so non-system
    /// fonts (e.g. Z06-Walone) resolve.
    public struct TextSpec: Codable {
        public var text: String
        public var anchor: Int?         // numpad 1..9
        public var offsetX: Float?
        public var offsetY: Float?
        public var fontName: String?
        public var fontPath: String?    // see SubtitlesSpec.fontsDir
        public var fontSize: Float?     // PlayRes pixels
        public var colorHex: String?    // glyph fill, hex without `#`
        public var shadow: Bool?
        public var bgColorHex: String?
        public var bgOpacity: Float?    // 0..1 — pill enabled when > 0
    }

    public struct AudioSpec: Codable {
        public var narrationPath: String
        public var musicPath: String?
        public var musicVolume: Float?  // 0..1
        public var bitrate: Int?
    }
}

/// Decode helpers — small enough to keep here rather than spinning up a
/// separate module. Hex colour parsing is the only non-trivial bit.
public enum JobHelpers {
    /// "FFFFFF" or "#FFFFFF" → RGBA in [0,1], alpha=1.
    public static func hexColor(_ s: String?) -> SIMD4<Float>? {
        guard var s = s else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }
        if s.count == 6 {
            let r = Float((rgba >> 16) & 0xFF) / 255
            let g = Float((rgba >>  8) & 0xFF) / 255
            let b = Float( rgba        & 0xFF) / 255
            return SIMD4(r, g, b, 1)
        } else {
            let r = Float((rgba >> 24) & 0xFF) / 255
            let g = Float((rgba >> 16) & 0xFF) / 255
            let b = Float((rgba >>  8) & 0xFF) / 255
            let a = Float( rgba        & 0xFF) / 255
            return SIMD4(r, g, b, a)
        }
    }

    /// "720p"/"1080p" → (w, h, defaultBitrate). Anything else parsed as
    /// "<W>x<H>" with a sensible default bitrate.
    public static func resolvePreset(_ p: String) -> (Int, Int, Int) {
        switch p.lowercased() {
        case "720p":  return (720, 1280, 5_000_000)
        case "1080p": return (1080, 1920, 10_000_000)
        default:
            let parts = p.lowercased().split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 {
                let pixels = parts[0] * parts[1]
                // 0.05 bits per pixel = ~10 Mbps at 1080×1920 — same
                // ballpark the per-preset constants use.
                let br = max(2_000_000, pixels * 5 / 100)
                return (parts[0], parts[1], br)
            }
            return (1080, 1920, 10_000_000)
        }
    }
}
