import Foundation
import MetalVideoEngine
import simd
import Metal

// stderr logging — pipes never lose log lines (stdout default is fully
// buffered when redirected).
func logLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func usage() -> Never {
    let msg = """
    mve — Metal-accelerated render engine (base pass only)

    USAGE:
      mve render --in <src> --out <dst> [options]
      mve job <spec.json>
      mve frame <spec.json>     (spec.frame.{atSeconds, outPath} required)
      mve libass --ass <path> --time-ms <int> --out <png> [--w 1080 --h 1920]
      mve text --text <str> --out <png> [text options]

    TEXT PROBE (visually test CoreText rasterisation params → PNG):
      mve text --text "PART 1" --out /tmp/t.png \\
               [--font "Helvetica"] [--size 80] [--color ffffff]
               [--bold 0|1] [--shadow 0|1]
               [--bg 000000] [--bg-opacity 0..1] [--radius 8]
               [--bgfill checker|RRGGBB]   (canvas behind the raster;
                                            default transparent. 'checker'
                                            makes AA edges easy to see.)
      Rasterises one line through the exact production
      Overlay.rasterizeText path and writes a PNG — eyeball glyph
      crispness, shadow, pill geometry and AA without a full render.

    RENDER OPTIONS (one-shot CLI):
      --in <path>          input video (mp4/mov)
      --out <path>         output video (mp4 for h264/hevc, mov for prores422hq)
      --preset 720p|1080p  vertical 9:16 target (default 1080p)
      --bitrate <bps>      override bitrate (default: 5M/720p, 10M/1080p)
      --brightness <-1..1> additive (default 0)
      --contrast <0..2>    multiplicative around 0.5 (default 1)
      --saturation <0..2>  (default 1)
      --tint <-3.14..3.14> hue rotation in radians (default 0)
      --chunks <N>         parallel encoder pipelines (default 3, 1 disables)
      --codec h264|hevc|prores422hq
                            output codec (default h264; prores422hq writes .mov)

    JOB MODE (JSON spec — used by the Node server bridge):
      mve job /path/to/spec.json
      See Sources/MetalVideoEngine/Job.swift for the schema.

    NOTE: this engine renders the BASE video only (decode + scale +
    grade + bypass + audio mix). Captions, logo, and text branding are
    layered on by a downstream ffmpeg pass that consumes this engine's
    output. The production pipeline writes ProRes 422 HQ to
    intermediate.mov, then the Node bridge runs `ass=` + `overlay=`
    against it to produce the final mp4.
    """
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

func arg(_ name: String, _ argv: [String]) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

/// Parse the --codec flag (one-shot CLI) / spec.codec field (JSON mode).
/// Defaults to h264 on any unrecognised value so a typo doesn't silently
/// produce a giant ProRes file. The Node bridge always sends an explicit
/// value, so this only matters for hand-rolled CLI invocations.
func parseCodec(_ raw: String?) -> MetalVideoEngine.VideoEncoder.Codec {
    switch (raw ?? "h264").lowercased() {
    case "hevc":         return .hevc
    case "prores422hq",
         "prores":       return .proRes422HQ
    default:             return .h264
    }
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { usage() }

switch argv[1] {
case "render": runOneShot(argv: argv)
case "job":    runJob(argv: argv)
case "frame":  runFrame(argv: argv)
case "libass": runLibassProbe(argv: argv)
case "text":   runTextProbe(argv: argv)
default:       usage()
}

// MARK: - one-shot CLI mode

func runOneShot(argv: [String]) {
    guard let inPath = arg("--in", argv), let outPath = arg("--out", argv) else { usage() }
    let preset = arg("--preset", argv) ?? "1080p"
    let (w, h, defaultBitrate) = JobHelpers.resolvePreset(preset)
    let bitrate = Int(arg("--bitrate", argv) ?? "") ?? defaultBitrate
    var grade = MetalVideoEngine.FilterGraph.GradeParams()
    if let v = arg("--brightness", argv), let f = Float(v) { grade.brightness = f }
    if let v = arg("--contrast",   argv), let f = Float(v) { grade.contrast = f }
    if let v = arg("--saturation", argv), let f = Float(v) { grade.saturation = f }
    if let v = arg("--tint",       argv), let f = Float(v) { grade.tint = f }
    let chunks = Int(arg("--chunks", argv) ?? "") ?? 3
    let codec = parseCodec(arg("--codec", argv))

    let req = RenderEngine.Request(
        inputURL: URL(fileURLWithPath: inPath),
        outputURL: URL(fileURLWithPath: outPath),
        width: w, height: h, bitrate: bitrate,
        grade: grade, codec: codec
    )

    do {
        if chunks <= 1 {
            let engine = try RenderEngine()
            let s = try engine.render(req, log: logLine)
            logLine(String(format: "[done] frames=%d  src=%.2fs  wall=%.2fs  speed=%.2fx",
                           s.framesProcessed, s.sourceDurationSecs,
                           s.wallClockSecs, s.realtimeRatio))
        } else {
            let engine = try ParallelRenderEngine()
            let s = try engine.render(req, chunks: chunks, log: logLine)
            logLine(String(format: "[done] frames=%d  src=%.2fs  wall=%.2fs  speed=%.2fx  chunks=%d",
                           s.framesProcessed, s.sourceDurationSecs,
                           s.wallClockSecs, s.realtimeRatio, s.chunks))
        }
    } catch {
        FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - JSON job mode (Node server bridge)

func runJob(argv: [String]) {
    guard argv.count >= 3 else { usage() }
    let specPath = argv[2]
    let specURL = URL(fileURLWithPath: specPath)
    let data: Data
    do { data = try Data(contentsOf: specURL) }
    catch {
        FileHandle.standardError.write(Data("job: cannot read \(specPath): \(error)\n".utf8))
        exit(1)
    }
    let spec: JobSpec
    do { spec = try JSONDecoder().decode(JobSpec.self, from: data) }
    catch {
        FileHandle.standardError.write(Data("job: invalid spec JSON: \(error)\n".utf8))
        exit(1)
    }

    do { try executeJob(spec) }
    catch {
        FileHandle.standardError.write(Data("job failed: \(error)\n".utf8))
        exit(1)
    }
}

/// Single-frame mode entry point. Same spec format as `job`, but the
/// engine seeks to spec.frame.atSeconds, composites one frame, and
/// writes a PNG to spec.frame.outPath — no encode, no mux. Used by
/// the editor's "Render one frame" diff against the live DOM preview.
func runFrame(argv: [String]) {
    guard argv.count >= 3 else { usage() }
    let specPath = argv[2]
    let specURL = URL(fileURLWithPath: specPath)
    let data: Data
    do { data = try Data(contentsOf: specURL) }
    catch {
        FileHandle.standardError.write(Data("frame: cannot read \(specPath): \(error)\n".utf8))
        exit(1)
    }
    let spec: JobSpec
    do { spec = try JSONDecoder().decode(JobSpec.self, from: data) }
    catch {
        FileHandle.standardError.write(Data("frame: invalid spec JSON: \(error)\n".utf8))
        exit(1)
    }
    do { try executeFrame(spec) }
    catch {
        FileHandle.standardError.write(Data("frame failed: \(error)\n".utf8))
        exit(1)
    }
}

func executeJob(_ spec: JobSpec) throws {
    let engine = try RenderEngine()
    let req = try buildRenderRequest(spec, engine: engine)
    // engine.render() prints its own [done] line and the file is on
    // disk by the time it returns. We don't use the returned Stats
    // here — the [done] line is the protocol callers (the Node
    // bridge, this CLI) parse. The hard `exit(0)` skips Swift's
    // ARC tear-down of the engine's AVAssetWriter / dispatch queue
    // graph; without it, a final audio-feeder callback can fire
    // against a torn-down input and SIGTRAP (exit 133). The output
    // file is fully flushed before we get here — nothing to lose.
    _ = try engine.render(req, log: logLine)
    exit(0)
}

func executeFrame(_ spec: JobSpec) throws {
    guard let frame = spec.frame else {
        FileHandle.standardError.write(Data("frame: spec.frame is required for single-frame mode\n".utf8))
        exit(2)
    }
    let engine = try RenderEngine()
    let req = try buildRenderRequest(spec, engine: engine)
    let outURL = URL(fileURLWithPath: frame.outPath)
    try engine.renderFrame(req, atSeconds: frame.atSeconds, outURL: outURL, log: logLine)
    // Same hard exit as executeJob — the PNG is fully written before
    // renderFrame returns, but ARC tear-down of the AVAssetReader can
    // still SIGTRAP on the audio-queue graph teardown.
    exit(0)
}

/// Shared spec → RenderEngine.Request builder. Both job (full render)
/// and frame (single-PTS render) modes consume the same fields; the
/// only difference is which method on the engine is called next.
func buildRenderRequest(_ spec: JobSpec, engine: RenderEngine) throws -> RenderEngine.Request {
    let device = engine.ctx.device

    let (w, h, defaultBitrate) = JobHelpers.resolvePreset(spec.preset)
    let bitrate = spec.bitrate ?? defaultBitrate
    let codec = parseCodec(spec.codec)

    // grade + bypass — fold tint deg→rad and let bypass set the tint
    // half so user-grade and project-bypass values both apply.
    var grade = MetalVideoEngine.FilterGraph.GradeParams()
    if let g = spec.grade {
        if let v = g.brightness { grade.brightness = v }
        if let v = g.contrast   { grade.contrast = v }
        if let v = g.saturation { grade.saturation = v }
        if let v = g.tint       { grade.tint = v }
        if let v = g.lutMix     { grade.lutMix = v }
    }
    var bypass = MetalVideoEngine.FilterGraph.BypassParams()
    if let b = spec.bypass {
        if let v = b.mirror        { bypass.mirror = v }
        if let v = b.zoom          { bypass.zoom = v }
        if let v = b.cropPct       { bypass.cropPct = v / 100 }
        if let v = b.colorTintDeg  { bypass.colorTintRad = v * .pi / 180 }
        if let v = b.noise         { bypass.noise = v }
        if let v = b.grain         { bypass.grain = v }
        if let v = b.edgeBlur      { bypass.edgeBlurSigma = v }
        if let v = b.edgeBlurBand  { bypass.edgeBlurBand = v }
    }

    // LUT load (optional). Engine ignores when nil.
    var lut: MTLTexture? = nil
    if let p = spec.lutPath, !p.isEmpty {
        lut = try LUT.loadCube(path: p, device: device)
        if grade.lutMix == 0 { grade.lutMix = 1 }
    }

    // libass subtitle renderer (optional). Register the project's
    // fontsDir with CoreText first — libass's CoreText font provider
    // looks at the process-scope font registry, so a TTF referenced by
    // the ASS Style block (e.g. `Z06-Walone`) won't resolve unless we
    // register it here. We do this BEFORE constructing the renderer
    // because libass caches font lookups on first use.
    var libass: LibassRenderer? = nil
    if let s = spec.subtitles {
        if let dir = s.fontsDir, !dir.isEmpty {
            Fonts.registerDirectory(dir)
        }
        let doc = try String(contentsOfFile: s.assPath, encoding: .utf8)
        let r = try LibassRenderer(canvasWidth: w, canvasHeight: h)
        try r.loadTrack(content: doc)
        libass = r
    }

    // Static overlays — images first, then texts. Pre-rasterised once
    // here so the engine's per-frame work is just one graph.composite
    // per overlay. Painted AFTER the libass pass (in Engine.render's
    // pass 3) so branding sits on top of captions, matching the
    // ffmpeg fallback pipeline's z-order.
    var overlays: [RenderEngine.OverlayDef] = []
    let canvas = SIMD2<Float>(Float(w), Float(h))
    if let images = spec.overlays {
        for o in images {
            let tex = try Overlay.loadImage(path: o.imagePath, device: device)
            // Logo width is a fraction of the canvas width; height
            // follows the source aspect so we don't squish it.
            let widthFrac = o.widthFraction ?? 0.12
            let imgW = Float(w) * widthFrac
            let aspect = Float(tex.height) / Float(tex.width)
            let size = SIMD2<Float>(imgW, imgW * aspect)
            let origin = Overlay.anchorRect(
                size: size, canvas: canvas,
                position: o.anchor ?? 3,  // default bottom-right
                offset: SIMD2(o.offsetX ?? 0, o.offsetY ?? 0)
            )
            overlays.append(.init(
                texture: tex, rectOrigin: origin, rectSize: size,
                opacity: o.opacity ?? 1.0
            ))
        }
    }
    if let texts = spec.texts {
        for t in texts {
            // Texts can carry their own fontPath so a project that uses
            // different fonts for captions vs. channel-name branding
            // still resolves both. Idempotent — Fonts.register dedupes
            // by absolute path.
            if let fp = t.fontPath, !fp.isEmpty {
                _ = Fonts.register(path: fp)
            }
            let color = JobHelpers.hexColor(t.colorHex) ?? SIMD4(1, 1, 1, 1)
            let bg: Overlay.TextStyle.Background? = {
                guard let cHex = t.bgColorHex, let opa = t.bgOpacity, opa > 0,
                      let c = JobHelpers.hexColor(cHex) else { return nil }
                return Overlay.TextStyle.Background(
                    color: SIMD4(c.x, c.y, c.z, opa),
                    cornerRadius: 8
                )
            }()
            let style = Overlay.TextStyle(
                fontName: t.fontName ?? "Helvetica",
                fontSize: CGFloat(t.fontSize ?? 56),
                color: color,
                bold: true,
                shadow: t.shadow ?? true,
                background: bg
            )
            let tex = try Overlay.rasterizeText(t.text, style: style, device: device)
            let size = SIMD2<Float>(Float(tex.width), Float(tex.height))
            let origin = Overlay.anchorRect(
                size: size, canvas: canvas,
                position: t.anchor ?? 9,  // default top-right
                offset: SIMD2(t.offsetX ?? 0, t.offsetY ?? 0)
            )
            overlays.append(.init(texture: tex, rectOrigin: origin, rectSize: size))
        }
    }

    // Audio mix (optional).
    var audio: AudioMix.Spec? = nil
    if let a = spec.audio {
        audio = AudioMix.Spec(
            narrationURL: URL(fileURLWithPath: a.narrationPath),
            musicURL: a.musicPath.map { URL(fileURLWithPath: $0) },
            musicVolume: a.musicVolume ?? 0.25,
            bitrate: a.bitrate ?? 192_000
        )
    }

    // Quality profile + peak bitrate — delivery (default) tunes for
    // social-platform re-encoders; draft skips B-frames for faster
    // wall time on preview / batch encodes.
    let quality: VideoEncoder.QualityProfile = (spec.quality ?? "delivery").lowercased() == "draft"
        ? .draft : .delivery

    return RenderEngine.Request(
        inputURL: URL(fileURLWithPath: spec.input),
        outputURL: URL(fileURLWithPath: spec.output),
        width: w, height: h, bitrate: bitrate,
        peakBitrate: spec.peakBitrate,
        quality: quality,
        grade: grade, bypass: bypass, codec: codec,
        lut: lut,
        libass: libass,
        staticOverlays: overlays,
        maxInflight: spec.maxInflight ?? 5,
        audio: audio
    )
}

// MARK: - libass probe (smoke test the Swift wrapper end-to-end)

import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Standalone smoke test for `LibassRenderer`. Loads an ASS file, asks
/// libass to render one frame at `--time-ms`, and writes the BGRA buffer
/// as a PNG. This isolates the C bridge from the rest of the Metal engine
/// so we can confirm the libass integration works before plumbing it into
/// Engine.swift's per-frame composite.
///
/// Usage:
///   mve libass \
///     --ass /tmp/aligned.ass \
///     --time-ms 5000 \
///     --out /tmp/cue.png \
///     [--w 1080] [--h 1920] \
///     [--fontsdir /path/to/fonts]
func runLibassProbe(argv: [String]) {
    guard let assPath = arg("--ass", argv),
          let timeStr = arg("--time-ms", argv),
          let timeMs = Int64(timeStr),
          let outPath = arg("--out", argv) else { usage() }
    let w = Int(arg("--w", argv) ?? "1080") ?? 1080
    let h = Int(arg("--h", argv) ?? "1920") ?? 1920
    let fontsdir = arg("--fontsdir", argv)

    // Register every TTF/OTF in fontsdir with CoreText so libass's
    // CoreText font provider can resolve the project's caption font.
    // Without this libass falls back to Helvetica for any font name
    // not on the system — same drift the old CoreText path had.
    if let dir = fontsdir {
        let url = URL(fileURLWithPath: dir)
        if let files = try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: nil) {
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                var err: Unmanaged<CFError>?
                _ = CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err)
            }
        }
    }

    let assDoc: String
    do {
        assDoc = try String(contentsOfFile: assPath, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("libass: cannot read \(assPath): \(error)\n".utf8))
        exit(1)
    }

    let renderer: LibassRenderer
    do {
        renderer = try LibassRenderer(canvasWidth: w, canvasHeight: h)
        try renderer.loadTrack(content: assDoc)
    } catch {
        FileHandle.standardError.write(Data("libass: init failed: \(error)\n".utf8))
        exit(1)
    }

    let frame: LibassRenderer.Frame?
    do {
        frame = try renderer.render(timeMs: timeMs)
    } catch {
        FileHandle.standardError.write(Data("libass: render failed: \(error)\n".utf8))
        exit(1)
    }
    guard let f = frame else {
        FileHandle.standardError.write(Data("libass: no images at time_ms=\(timeMs) (no active cue)\n".utf8))
        exit(2)
    }

    // BGRA premultiplied-first + little-endian byte order is the exact
    // pixel format the engine's overlay shader samples from. CGImage
    // matches it via .premultipliedFirst + .byteOrder32Little.
    let bytesPerRow = f.width * 4
    let cs = CGColorSpaceCreateDeviceRGB()
    let bm = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(f.bytes) as CFData),
          let cg = CGImage(
            width: f.width, height: f.height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bm,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent),
          let dst = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("libass: PNG encode failed\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dst, cg, nil)
    guard CGImageDestinationFinalize(dst) else {
        FileHandle.standardError.write(Data("libass: PNG finalize failed\n".utf8))
        exit(1)
    }
    logLine("[libass] wrote \(outPath) (\(f.width)x\(f.height) BGRA, time_ms=\(timeMs))")
    exit(0)
}

// MARK: - text probe (CoreText rasterisation → PNG)

/// Rasterise one line of text through the exact production path
/// (`Overlay.rasterizeText`) and write it to a PNG so font / size /
/// shadow / pill / AA params can be eyeballed without a video render.
///
/// `--bgfill` paints a backdrop behind the (transparent) raster so the
/// anti-aliased edges are visible: `checker` draws an 8px checkerboard,
/// or pass an `RRGGBB` hex for a solid fill. Omit for a transparent PNG.
func runTextProbe(argv: [String]) {
    guard let text = arg("--text", argv), let outPath = arg("--out", argv) else { usage() }
    guard let device = MTLCreateSystemDefaultDevice() else {
        FileHandle.standardError.write(Data("text: no Metal device\n".utf8))
        exit(1)
    }

    // Register a font file if the name looks like a path; otherwise the
    // CoreText name resolver handles system families (e.g. "Helvetica").
    let fontName = arg("--font", argv) ?? "Helvetica"
    if fontName.contains("/"), !Fonts.register(path: fontName) {
        logLine("[text] warning: could not register font file \(fontName)")
    }
    let size = CGFloat(Double(arg("--size", argv) ?? "") ?? 80)
    let color = JobHelpers.hexColor(arg("--color", argv)) ?? SIMD4(1, 1, 1, 1)
    let bold = (arg("--bold", argv) ?? "1") != "0"
    let shadow = (arg("--shadow", argv) ?? "1") != "0"

    var bg: Overlay.TextStyle.Background? = nil
    if let bgHex = arg("--bg", argv),
       let opaStr = arg("--bg-opacity", argv), let opa = Float(opaStr), opa > 0,
       let c = JobHelpers.hexColor(bgHex) {
        let radius = CGFloat(Double(arg("--radius", argv) ?? "") ?? 8)
        bg = Overlay.TextStyle.Background(color: SIMD4(c.x, c.y, c.z, opa), cornerRadius: radius)
    }

    let style = Overlay.TextStyle(
        fontName: fontName, fontSize: size, color: color,
        bold: bold, shadow: shadow, background: bg
    )

    let tex: MTLTexture
    do {
        tex = try Overlay.rasterizeText(text, style: style, device: device)
    } catch {
        FileHandle.standardError.write(Data("text: rasterize failed: \(error)\n".utf8))
        exit(1)
    }

    // Read the texture back to a BGRA buffer (premultiplied-first +
    // little-endian — the same layout the overlay shader composites).
    let w = tex.width, h = tex.height
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
    pixels.withUnsafeMutableBytes { ptr in
        tex.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }

    // Optional backdrop so AA edges are visible. We composite the raster
    // OVER the backdrop in straight (premultiplied) src-over.
    if let fill = arg("--bgfill", argv) {
        let checker = fill.lowercased() == "checker"
        let solid = checker ? nil : JobHelpers.hexColor(fill)
        for y in 0..<h {
            for x in 0..<w {
                let off = y * bytesPerRow + x * 4
                let sB = Float(pixels[off + 0]), sG = Float(pixels[off + 1])
                let sR = Float(pixels[off + 2]), sA = Float(pixels[off + 3]) / 255
                // Backdrop colour (already-straight 0..255).
                let (bR, bG, bB): (Float, Float, Float)
                if checker {
                    let v: Float = ((x / 8) + (y / 8)) % 2 == 0 ? 90 : 160
                    (bR, bG, bB) = (v, v, v)
                } else if let s = solid {
                    (bR, bG, bB) = (s.x * 255, s.y * 255, s.z * 255)
                } else {
                    (bR, bG, bB) = (0, 0, 0)
                }
                // src is premultiplied; out = src + bg*(1-a).
                pixels[off + 0] = UInt8(min(255, sB + bB * (1 - sA)))
                pixels[off + 1] = UInt8(min(255, sG + bG * (1 - sA)))
                pixels[off + 2] = UInt8(min(255, sR + bR * (1 - sA)))
                pixels[off + 3] = 255
            }
        }
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let bm = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bm,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent),
          let dst = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("text: PNG encode failed\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dst, cg, nil)
    guard CGImageDestinationFinalize(dst) else {
        FileHandle.standardError.write(Data("text: PNG finalize failed\n".utf8))
        exit(1)
    }
    logLine("[text] wrote \(outPath) (\(w)x\(h)) — font=\(fontName) size=\(Int(size)) bold=\(bold) shadow=\(shadow) bg=\(bg != nil)")
    exit(0)
}
