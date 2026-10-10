import Foundation
import AVFoundation
import CoreText
import ImageIO
import simd

/// One finding of the pre-flight check (`mve inspect`). `subject` names
/// the JobSpec field it concerns, for example `texts[0].fontName`.
public struct Diagnostic: Codable, Equatable {
    public enum Kind: String, Codable {
        case missingMedia, fontFallback, textClipped
        case unknownEase, unknownTransition
        case windowOutsideTimeline, keyframeOutsideTimeline, emptyWindow
    }
    public enum Severity: String, Codable {
        case error, warning
    }

    public var kind: Kind
    public var severity: Severity
    public var subject: String
    public var message: String
    /// Output-timeline second the finding points at, when it has one.
    public var atSeconds: Double?

    public init(_ kind: Kind, _ severity: Severity, subject: String,
                message: String, atSeconds: Double? = nil) {
        self.kind = kind; self.severity = severity
        self.subject = subject; self.message = message
        self.atSeconds = atSeconds
    }
}

/// Pre-flight check of a JobSpec. It reads files and asks CoreText and
/// ImageIO for sizes. It decodes no video frame and creates no Metal
/// texture.
public enum Inspector {

    /// All findings, errors first.
    public static func inspect(_ spec: JobSpec) -> [Diagnostic] {
        if let dir = spec.subtitles?.fontsDir, !dir.isEmpty { Fonts.registerDirectory(dir) }
        for t in spec.texts ?? [] {
            if let fp = t.fontPath, !fp.isEmpty { _ = Fonts.register(path: fp) }
        }

        var found = missingMedia(spec)
        found += fontFallbacks(spec)
        found += geometry(spec)
        found += specDiagnostics(spec)
        found += timeline(spec)
        return found.filter { $0.severity == .error } + found.filter { $0.severity == .warning }
    }

    // ── Checks that need no duration ───────────────────────────────────

    /// Unknown ease and transition names, and empty visibility windows.
    static func specDiagnostics(_ spec: JobSpec) -> [Diagnostic] {
        var found: [Diagnostic] = []
        for (path, keys) in spec.keyframeLists {
            guard let key = keys.first(where: { $0.ease.map { Easing.parse($0) == nil } ?? false }),
                  let raw = key.ease else { continue }
            found.append(.init(.unknownEase, .error, subject: path,
                               message: "unknown ease '\(raw)'", atSeconds: key.t))
        }
        // The engine reads the transition of segment i for the boundary into
        // i + 1, ignores the last one, and never reads the ease of a cut or
        // of an unknown type.
        for (i, seg) in (spec.inputs ?? []).dropLast().enumerated() {
            guard let tr = seg.transition else { continue }
            guard let kind = RenderEngine.Transition.kind(from: tr.type) else {
                found.append(.init(.unknownTransition, .error,
                                   subject: "inputs[\(i)].transition.type",
                                   message: "unknown transition type '\(tr.type)'"))
                continue
            }
            if case .cut = kind { continue }
            if let raw = tr.ease, Easing.parse(raw) == nil {
                found.append(.init(.unknownEase, .error, subject: "inputs[\(i)].transition.ease",
                                   message: "unknown ease '\(raw)'"))
            }
        }

        // The engine shows an overlay while start <= t < end, from t = 0.
        func checkWindow(_ subject: String, _ start: Double?, _ end: Double?) {
            let begin = max(start ?? 0, 0)
            guard let end, end <= begin else { return }
            found.append(.init(.emptyWindow, .error, subject: subject,
                               message: "endSeconds \(fmt(end)) is not after the start at \(fmt(begin)) s",
                               atSeconds: begin))
        }
        for (i, o) in (spec.overlays ?? []).enumerated() {
            checkWindow("overlays[\(i)]", o.startSeconds, o.endSeconds)
        }
        for (i, t) in (spec.texts ?? []).enumerated() {
            checkWindow("texts[\(i)]", t.startSeconds, t.endSeconds)
        }
        return found
    }

    /// Windows and keyframes that start at or after the end of the Output
    /// timeline. Pure: the caller supplies the timeline length.
    static func timelineDiagnostics(_ spec: JobSpec, outputSeconds end: Double) -> [Diagnostic] {
        var found: [Diagnostic] = []
        func checkStart(_ subject: String, _ start: Double?) {
            guard let start, start >= end else { return }
            found.append(.init(.windowOutsideTimeline, .warning, subject: subject,
                               message: "window starts at \(fmt(start)) s but the output ends at \(fmt(end)) s",
                               atSeconds: start))
        }
        for (i, o) in (spec.overlays ?? []).enumerated() { checkStart("overlays[\(i)].startSeconds", o.startSeconds) }
        for (i, t) in (spec.texts ?? []).enumerated() { checkStart("texts[\(i)].startSeconds", t.startSeconds) }

        for (path, keys) in spec.keyframeLists {
            guard let late = keys.map(\.t).filter({ $0 > end }).min() else { continue }
            found.append(.init(.keyframeOutsideTimeline, .warning, subject: path,
                               message: "keyframe at \(fmt(late)) s is after the output end at \(fmt(end)) s",
                               atSeconds: late))
        }
        return found
    }

    // ── Media ──────────────────────────────────────────────────────────

    /// The input files the render reads, with the field each came from.
    private static func inputRefs(_ spec: JobSpec) -> [(subject: String, path: String)] {
        if let ins = spec.inputs, !ins.isEmpty {
            return ins.enumerated().map { ("inputs[\($0.offset)].path", $0.element.path) }
        }
        return spec.input.map { [("input", $0)] } ?? []
    }

    private static func missingMedia(_ spec: JobSpec) -> [Diagnostic] {
        var refs = inputRefs(spec).map { (subject: $0.subject, path: $0.path, directory: false) }
        var found: [Diagnostic] = []
        if refs.isEmpty {
            found.append(.init(.missingMedia, .error, subject: "input",
                               message: "spec needs `input` or a non-empty `inputs`"))
        }
        func add(_ subject: String, _ path: String, directory: Bool = false) {
            refs.append((subject, path, directory))
        }
        for (i, o) in (spec.overlays ?? []).enumerated() { add("overlays[\(i)].imagePath", o.imagePath) }
        if let p = spec.lutPath, !p.isEmpty { add("lutPath", p) }
        if let s = spec.subtitles {
            add("subtitles.assPath", s.assPath)
            if let d = s.fontsDir, !d.isEmpty { add("subtitles.fontsDir", d, directory: true) }
        }
        for (i, t) in (spec.texts ?? []).enumerated() {
            if let p = t.fontPath, !p.isEmpty { add("texts[\(i)].fontPath", p) }
        }
        if let a = spec.audio {
            add("audio.narrationPath", a.narrationPath)
            if let p = a.musicPath, JobHelpers.audioSpec(a).readsMusic { add("audio.musicPath", p) }
        }
        for ref in refs where !isReadable(ref.path, directory: ref.directory) {
            found.append(.init(.missingMedia, .error, subject: ref.subject,
                               message: "cannot read \(ref.path)"))
        }
        return found
    }

    /// `isReadableFile` is also true for a directory, which no reader accepts
    /// as a file.
    private static func isReadable(_ path: String, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue == directory
            && FileManager.default.isReadableFile(atPath: path)
    }

    /// Timeline checks against the real input durations. Skipped when an
    /// input is unreadable, because `missingMedia` already reports it.
    private static func timeline(_ spec: JobSpec) -> [Diagnostic] {
        let refs = inputRefs(spec)
        guard !refs.isEmpty,
              refs.allSatisfy({ isReadable($0.path, directory: false) }) else { return [] }
        var durations: [Double] = []
        var faults: [Diagnostic] = []
        for ref in refs {
            let asset = AVAsset(url: URL(fileURLWithPath: ref.path))
            let secs = CMTimeGetSeconds(asset.duration)
            if asset.tracks(withMediaType: .video).isEmpty || !secs.isFinite || secs <= 0 {
                faults.append(.init(.missingMedia, .error, subject: ref.subject,
                                    message: "\(ref.path) has no readable video track"))
            }
            durations.append(secs)
        }
        guard faults.isEmpty else { return faults }
        return timelineDiagnostics(spec, outputSeconds: outputSeconds(of: spec, segmentSeconds: durations))
    }

    /// Output timeline length for the given per-input durations, with the
    /// overlap of crossfade, wipe, and slide transitions removed. Uses the
    /// engine's own playlist and timeline code.
    static func outputSeconds(of spec: JobSpec, segmentSeconds: [Double]) -> Double {
        let segments = JobHelpers.segments(of: spec)
            ?? inputRefs(spec).map { RenderEngine.Segment(url: URL(fileURLWithPath: $0.path)) }
        return RenderEngine.Timeline.layout(segments: segments, segSecs: segmentSeconds).totalOutSecs
    }

    // ── Fonts ──────────────────────────────────────────────────────────

    /// CoreText answers a missing font with a default one, never an error.
    /// A request that matches none of the resolved font's names was
    /// replaced. The font is resolved without the bold trait that
    /// `rasterizeText` adds, because that trait changes the PostScript name.
    private static func fontFallbacks(_ spec: JobSpec) -> [Diagnostic] {
        var found: [Diagnostic] = []
        for (i, t) in (spec.texts ?? []).enumerated() {
            guard let name = t.fontName, !name.isEmpty else { continue }
            let font = Overlay.resolveFont(name: name, size: 12, bold: false)
            let names = [CTFontCopyFamilyName(font), CTFontCopyPostScriptName(font),
                         CTFontCopyFullName(font), CTFontCopyDisplayName(font)]
                .map { ($0 as String).lowercased() }
            guard !names.contains(name.lowercased()) else { continue }
            found.append(.init(.fontFallback, .warning, subject: "texts[\(i)].fontName",
                               message: "font '\(name)' not found; CoreText uses '\(CTFontCopyFamilyName(font))'"))
        }
        return found
    }

    // ── Overlay geometry ───────────────────────────────────────────────

    private static func geometry(_ spec: JobSpec) -> [Diagnostic] {
        let (w, h, _) = JobHelpers.resolvePreset(spec.preset)
        let canvas = SIMD2<Float>(Float(w), Float(h))
        var found: [Diagnostic] = []

        for (i, o) in (spec.overlays ?? []).enumerated() {
            guard isReadable(o.imagePath, directory: false) else { continue }
            guard let (pw, ph) = imagePixelSize(o.imagePath) else {
                found.append(.init(.missingMedia, .error, subject: "overlays[\(i)].imagePath",
                                   message: "\(o.imagePath) is not a readable image"))
                continue
            }
            let (origin, size) = JobHelpers.imageRect(o, pixelWidth: pw, pixelHeight: ph, canvas: canvas)
            found += rectDiagnostics(subject: "overlays[\(i)]", what: "image",
                                     origin: origin, size: size, canvas: canvas)
        }
        for (i, t) in (spec.texts ?? []).enumerated() {
            let layout = Overlay.layoutText(t.text, style: JobHelpers.textStyle(t))
            let size = SIMD2<Float>(Float(layout.width), Float(layout.height))
            let origin = JobHelpers.textOrigin(t, size: size, canvas: canvas)
            found += rectDiagnostics(subject: "texts[\(i)]", what: "text",
                                     origin: origin, size: size, canvas: canvas)
        }
        return found
    }

    /// Edge test for one rest rect. `anchorRect` clamps the origin into the
    /// canvas, so only a rect larger than the canvas crosses an edge. It also
    /// rounds the origin to whole pixels, so a 1 px overshoot is rounding.
    static func rectDiagnostics(
        subject: String, what: String,
        origin: SIMD2<Float>, size: SIMD2<Float>, canvas: SIMD2<Float>
    ) -> [Diagnostic] {
        let end = origin + size
        let desc = "\(what) rect \(Int(size.x))x\(Int(size.y)) at (\(Int(origin.x)), \(Int(origin.y))) on a \(Int(canvas.x))x\(Int(canvas.y)) canvas"
        let slack: Float = 1
        if origin.x < -slack || origin.y < -slack || end.x > canvas.x + slack || end.y > canvas.y + slack {
            return [.init(.textClipped, .warning, subject: subject, message: "\(desc) crosses the canvas edge")]
        }
        return []
    }

    /// Pixel size from the file header. ImageIO decodes no pixels here.
    private static func imagePixelSize(_ path: String) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    private static func fmt(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}
