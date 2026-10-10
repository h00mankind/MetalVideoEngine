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
    /// Single-input form. Either `input` or `inputs` is required;
    /// `inputs` wins when both are present.
    public var input: String?
    /// Playlist form: segments rendered back-to-back on one output
    /// timeline, with an optional transition at each boundary. Grade,
    /// bypass, subtitles, overlays, and animation all evaluate on the
    /// OUTPUT timeline, spanning segment boundaries.
    public var inputs: [SegmentSpec]?
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
    /// Job-level animation: keyframe tracks over grade/bypass fields
    /// plus whole-frame fade in/out. See `AnimateSpec`.
    public var animate: AnimateSpec?

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

    /// One playlist segment. `transition` describes the boundary into
    /// the NEXT segment (ignored on the last segment).
    public struct SegmentSpec: Codable {
        public var path: String
        public var transition: TransitionSpec?
    }

    /// Boundary transition. Types: "cut" (default), "crossfade",
    /// "dipToBlack", "wipeLeft"/"wipeRight"/"wipeUp"/"wipeDown",
    /// "slideLeft"/"slideRight"/"slideUp"/"slideDown" — directions name
    /// the edge the incoming clip enters from. `duration` defaults to
    /// 0.5s and is clamped to the shorter neighbouring segment.
    /// Overlapping types (crossfade/wipe/slide) shorten the output by
    /// their duration; cut and dipToBlack don't. `ease` shapes the
    /// progress curve (same values as keyframe `ease`, default linear).
    public struct TransitionSpec: Codable {
        public var type: String
        public var duration: Double?
        public var ease: String?
    }

    /// One point on a keyframe track: value `v` at output-timeline
    /// second `t`, interpolated from the previous key with `ease`
    /// ("hold" | "linear" | "easeIn" | "easeOut" | "easeInOut", or
    /// "cubicBezier(x1,y1,x2,y2)" like CSS cubic-bezier; x1/x2 are
    /// clamped to 0...1, y1/y2 may overshoot; default linear). An
    /// unknown string logs a warning and falls back to linear. The
    /// engine has no animation presets — the host compiles its named
    /// animations down to these lists.
    public struct KeyframeSpec: Codable {
        public var t: Double
        public var v: Float
        public var ease: String?
        public init(t: Double, v: Float, ease: String? = nil) {
            self.t = t; self.v = v; self.ease = ease
        }
    }

    /// Keyframe tracks over one overlay's animatable properties. All
    /// optional — absent tracks leave the property static.
    ///   - `opacity`: multiplied with the overlay's base opacity (0..1)
    ///   - `offsetX`/`offsetY`: additive offset from the anchored
    ///     position, PlayRes pixels
    ///   - `scale`: about the rect center; 1.0 = natural size
    ///   - `srcCenterX`/`srcCenterY`/`srcZoom` (image overlays only):
    ///     Ken Burns source window — normalized center (default 0.5)
    ///     and zoom ≥ 1 (default 1). The engine derives a
    ///     cover-semantics window so keyframes can't skew the image.
    public struct OverlayAnimateSpec: Codable {
        public var opacity: [KeyframeSpec]?
        public var offsetX: [KeyframeSpec]?
        public var offsetY: [KeyframeSpec]?
        public var scale: [KeyframeSpec]?
        public var srcCenterX: [KeyframeSpec]?
        public var srcCenterY: [KeyframeSpec]?
        public var srcZoom: [KeyframeSpec]?
    }

    /// Job-level animation: keyframe tracks over grade/bypass scalars
    /// (a keyed field overrides its static value for the whole render)
    /// plus whole-frame fade from/to black. Fades composite ABOVE
    /// subtitles and overlays.
    public struct AnimateSpec: Codable {
        public var grade: GradeTracksSpec?
        public var bypass: BypassTracksSpec?
        public var fadeInSeconds: Double?
        public var fadeOutSeconds: Double?

        public struct GradeTracksSpec: Codable {
            public var brightness: [KeyframeSpec]?
            public var contrast: [KeyframeSpec]?
            public var saturation: [KeyframeSpec]?
            public var tint: [KeyframeSpec]?
            public var lutMix: [KeyframeSpec]?
        }
        public struct BypassTracksSpec: Codable {
            public var zoom: [KeyframeSpec]?
            public var colorTintDeg: [KeyframeSpec]?  // degrees, like BypassSpec
            public var noise: [KeyframeSpec]?
            public var grain: [KeyframeSpec]?
            public var edgeBlur: [KeyframeSpec]?
        }
    }

    /// Image overlay (typically the user's logo/watermark). The engine
    /// scales the image to `widthFraction * canvas.width`, places it at
    /// the numpad `anchor` cell + (offsetX, offsetY) PlayRes pixels, and
    /// composites at the configured opacity. Output aspect ratio is
    /// preserved — height derives from the loaded image's natural ratio.
    ///
    /// `startSeconds`/`endSeconds` bound the overlay's visibility on
    /// the output timeline (absent → always visible). `animate` holds
    /// keyframe tracks; times inside it are absolute output-timeline
    /// seconds, not window-relative.
    public struct OverlaySpec: Codable {
        public var imagePath: String
        public var anchor: Int?         // numpad 1..9
        public var offsetX: Float?      // PlayRes pixels (1080×1920)
        public var offsetY: Float?
        public var widthFraction: Float? // 0..1 of canvas width
        public var opacity: Float?      // 0..1
        public var startSeconds: Double?
        public var endSeconds: Double?
        public var animate: OverlayAnimateSpec?
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
        public var bgRadius: Float?     // pill corner radius, PlayRes px (default 8)
        /// Visibility window + keyframe tracks — same semantics as
        /// `OverlaySpec` (src* tracks are ignored for text).
        public var startSeconds: Double?
        public var endSeconds: Double?
        public var animate: OverlayAnimateSpec?
    }

    public struct AudioSpec: Codable {
        public var narrationPath: String
        public var musicPath: String?
        public var musicVolume: Float?  // 0..1
        public var bitrate: Int?
    }
}

extension JobSpec {
    /// Every keyframe list in the spec with its field path, for example
    /// `texts[0].animate.opacity`. Mirror finds each track list, including
    /// ones added to the animate structs later, so this is the one place
    /// that knows which fields animate.
    public var keyframeLists: [(path: String, keys: [KeyframeSpec])] {
        func lists(_ container: Any?, _ prefix: String) -> [(path: String, keys: [KeyframeSpec])] {
            guard let container else { return [] }
            return Mirror(reflecting: container).children.compactMap { child in
                guard let label = child.label, let keys = child.value as? [KeyframeSpec] else { return nil }
                return ("\(prefix).\(label)", keys)
            }
        }
        var all: [(path: String, keys: [KeyframeSpec])] = []
        for (i, o) in (overlays ?? []).enumerated() { all += lists(o.animate, "overlays[\(i)].animate") }
        for (i, t) in (texts ?? []).enumerated() { all += lists(t.animate, "texts[\(i)].animate") }
        all += lists(animate?.grade, "animate.grade") + lists(animate?.bypass, "animate.bypass")
        return all
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

    /// The CoreText style `mve job` rasterizes a text overlay with.
    public static func textStyle(_ t: JobSpec.TextSpec) -> Overlay.TextStyle {
        let color = hexColor(t.colorHex) ?? SIMD4(1, 1, 1, 1)
        let bg: Overlay.TextStyle.Background? = {
            guard let cHex = t.bgColorHex, let opa = t.bgOpacity, opa > 0,
                  let c = hexColor(cHex) else { return nil }
            return Overlay.TextStyle.Background(
                color: SIMD4(c.x, c.y, c.z, opa),
                cornerRadius: CGFloat(t.bgRadius ?? 8)
            )
        }()
        return Overlay.TextStyle(
            fontName: t.fontName ?? "Helvetica",
            fontSize: CGFloat(t.fontSize ?? 56),
            color: color,
            bold: true,
            shadow: t.shadow ?? true,
            background: bg
        )
    }

    /// The playlist `spec.inputs` describes, or nil for the single-`input`
    /// form. An unknown transition type is a hard cut and an unknown ease
    /// is linear; `warn` hears each one. `cut` never reads its ease.
    public static func segments(
        of spec: JobSpec, warn: (String) -> Void = { _ in }
    ) -> [RenderEngine.Segment]? {
        guard let ins = spec.inputs, !ins.isEmpty else { return nil }
        return ins.map { s in
            var transition: RenderEngine.Transition? = nil
            if let t = s.transition {
                if let kind = RenderEngine.Transition.kind(from: t.type) {
                    if case .cut = kind {} else {
                        var ease = Easing.linear
                        if let raw = t.ease {
                            if let parsed = Easing.parse(raw) { ease = parsed }
                            else { warn("unknown ease '\(raw)' — using linear") }
                        }
                        transition = RenderEngine.Transition(
                            kind: kind, duration: t.duration ?? 0.5, ease: ease
                        )
                    }
                } else {
                    warn("unknown transition type '\(t.type)' — using cut")
                }
            }
            return RenderEngine.Segment(url: URL(fileURLWithPath: s.path), transition: transition)
        }
    }

    /// The audio mix `mve job` builds from `spec.audio`.
    public static func audioSpec(_ a: JobSpec.AudioSpec) -> AudioMix.Spec {
        AudioMix.Spec(
            narrationURL: URL(fileURLWithPath: a.narrationPath),
            musicURL: a.musicPath.map { URL(fileURLWithPath: $0) },
            musicVolume: a.musicVolume ?? 0.25,
            bitrate: a.bitrate ?? 192_000
        )
    }

    /// Rest rect of an image overlay on the canvas.
    public static func imageRect(
        _ o: JobSpec.OverlaySpec, pixelWidth: Int, pixelHeight: Int, canvas: SIMD2<Float>
    ) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let size = Overlay.imageSize(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            widthFraction: o.widthFraction ?? 0.12, canvasWidth: canvas.x
        )
        let origin = Overlay.anchorRect(
            size: size, canvas: canvas,
            position: o.anchor ?? 3,  // default bottom-right
            offset: SIMD2(o.offsetX ?? 0, o.offsetY ?? 0)
        )
        return (origin, size)
    }

    /// Rest origin of a text overlay whose raster measures `size`.
    public static func textOrigin(
        _ t: JobSpec.TextSpec, size: SIMD2<Float>, canvas: SIMD2<Float>
    ) -> SIMD2<Float> {
        Overlay.anchorRect(
            size: size, canvas: canvas,
            position: t.anchor ?? 9,  // default top-right
            offset: SIMD2(t.offsetX ?? 0, t.offsetY ?? 0)
        )
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
