import Foundation
import Metal
import CoreVideo
import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Top-level engine: takes a render request, runs decode → Metal filter
/// graph → encode, returns when the output file is finished.
///
/// Pipelining model:
///
///   decode thread  ──►  GPU command queue  ──►  encoder ingest
///        ▲                       │                       │
///        └── inflight semaphore ─┴───────────────────────┘
///
/// The decode thread pulls frames as fast as the AVAssetReader will
/// supply them, encodes a Metal compute pass against each, and commits
/// the command buffer with an `addCompletedHandler` that hands the
/// finished output CVPixelBuffer to the encoder. **No `waitUntilCompleted`
/// on the hot path** — decode/GPU/encode all overlap.
///
/// Scope: this engine writes the final mp4 in one Metal pass. Source
/// decode → scale/grade/bypass → libass subtitle composite → audio mix
/// → VideoToolbox h264 encode. Static-overlay branding (logo, channel
/// name) is the only knob NOT in scope; the Node bridge composites
/// that with a follow-up ffmpeg overlay step when needed.
///
/// Captions go through real libass via `LibassRenderer` (Homebrew
/// libass 0.17.4, CoreText font provider) — same renderer ffmpeg and
/// the JASSUB-based preview use, so all three paths produce identical
/// pixels. Replaces the older CoreText-only `SubtitleTrack`.
public final class RenderEngine {
    /// A static texture overlay composited on every frame after the
    /// libass subtitle pass — logo PNGs and CoreText-rasterised
    /// channel-name strings both hand in as this shape. The host
    /// pre-rasterises once at job start; per-frame cost is one
    /// graph.composite call per overlay.
    public struct OverlayDef {
        public var texture: MTLTexture
        public var rectOrigin: SIMD2<Float>
        public var rectSize: SIMD2<Float>
        public var opacity: Float
        public init(texture: MTLTexture, rectOrigin: SIMD2<Float>,
                    rectSize: SIMD2<Float>, opacity: Float = 1.0) {
            self.texture = texture; self.rectOrigin = rectOrigin
            self.rectSize = rectSize; self.opacity = opacity
        }
    }

    public struct Request {
        public var inputURL: URL
        public var outputURL: URL
        public var width: Int
        public var height: Int
        public var bitrate: Int
        /// Peak bitrate cap, bits/sec. nil → 1.5× `bitrate`.
        public var peakBitrate: Int?
        /// Delivery profile (B-frames + peak cap) vs. draft (IPPP only,
        /// faster). See VideoEncoder.QualityProfile for the trade-off.
        public var quality: VideoEncoder.QualityProfile
        public var grade: FilterGraph.GradeParams
        public var bypass: FilterGraph.BypassParams
        public var codec: VideoEncoder.Codec
        /// Optional 3D LUT (loaded via `LUT.loadCube`). When set, the
        /// `grade.lutMix` value in (0..1] activates trilinear sampling.
        public var lut: MTLTexture?
        /// Optional libass renderer pre-loaded with the project's ASS
        /// document. The engine calls `render(timeMs:)` per video frame
        /// and composites the returned BGRA buffer over the graded
        /// frame. nil → no subtitle composite path runs.
        public var libass: LibassRenderer?
        /// Static overlays composited on every frame in z-order, AFTER
        /// the libass subtitle pass — so text + logo branding sits on
        /// top of captions just like the ffmpeg fallback pipeline.
        public var staticOverlays: [OverlayDef]
        /// In-flight frame depth.
        public var maxInflight: Int
        /// Optional narration / music audio. Mixed and muxed into the
        /// output alongside the video stream. nil = silent output.
        public var audio: AudioMix.Spec?

        public init(
            inputURL: URL,
            outputURL: URL,
            width: Int,
            height: Int,
            bitrate: Int,
            peakBitrate: Int? = nil,
            quality: VideoEncoder.QualityProfile = .delivery,
            grade: FilterGraph.GradeParams = .init(),
            bypass: FilterGraph.BypassParams = .init(),
            codec: VideoEncoder.Codec = .h264,
            lut: MTLTexture? = nil,
            libass: LibassRenderer? = nil,
            staticOverlays: [OverlayDef] = [],
            maxInflight: Int = 5,
            audio: AudioMix.Spec? = nil
        ) {
            self.inputURL = inputURL; self.outputURL = outputURL
            self.width = width; self.height = height; self.bitrate = bitrate
            self.peakBitrate = peakBitrate
            self.quality = quality
            self.grade = grade; self.bypass = bypass; self.codec = codec
            self.lut = lut
            self.libass = libass
            self.staticOverlays = staticOverlays
            self.maxInflight = maxInflight
            self.audio = audio
        }
    }

    public struct Stats {
        public var framesProcessed: Int
        public var wallClockSecs: Double
        public var sourceDurationSecs: Double
        public var realtimeRatio: Double { wallClockSecs > 0 ? sourceDurationSecs / wallClockSecs : 0 }
    }

    public let ctx: MetalContext

    public init() throws {
        self.ctx = try MetalContext()
    }

    public func render(_ req: Request, log: @escaping (String) -> Void = { _ in }) throws -> Stats {
        let started = Date()

        let decoder = try VideoDecoder(url: req.inputURL)
        let frameRate = Int(decoder.nominalFrameRate.rounded())
        let fps = frameRate > 0 ? frameRate : 30

        // Decide whether the output mp4 needs an audio track. If yes, we
        // route writing through MuxWriter which owns both the video and
        // audio AVAssetWriterInputs; otherwise the standalone VideoEncoder
        // (video-only) keeps the simpler path.
        // Build the shared VideoEncoder.Settings once so both sinks
        // (audio+video MuxWriter, video-only VideoEncoder) encode
        // bit-identically — same peakBitrate, same quality profile,
        // same frame rate.
        let videoSettings = VideoEncoder.Settings(
            width: req.width, height: req.height,
            bitrate: req.bitrate,
            peakBitrate: req.peakBitrate,
            frameRate: fps,
            codec: req.codec,
            quality: req.quality
        )
        let writer: any AnyVideoSink
        if let audioSpec = req.audio {
            writer = try MuxWriter(
                url: req.outputURL,
                video: videoSettings,
                audio: audioSpec,
                log: log
            )
        } else {
            writer = try VideoEncoder(
                url: req.outputURL,
                settings: videoSettings
            )
        }
        let graph = try FilterGraph(ctx: ctx)

        log("[engine] decoder ready: \(Int(decoder.naturalSize.width))x\(Int(decoder.naturalSize.height)) @ \(fps)fps")
        log("[engine] output: \(req.width)x\(req.height) @ \(req.bitrate / 1000) kbps  codec=\(codecName(req.codec))  inflight=\(req.maxInflight)")
        if req.audio != nil { log("[engine] audio: enabled") }

        let inflight = DispatchSemaphore(value: req.maxInflight)
        let encoderLock = NSLock()
        let errorLock = NSLock()
        var firstError: Error?
        func storeError(_ e: Error) {
            errorLock.lock(); defer { errorLock.unlock() }
            if firstError == nil { firstError = e }
        }
        func currentError() -> Error? {
            errorLock.lock(); defer { errorLock.unlock() }
            return firstError
        }

        var frameCount = 0
        var lastLogFrame = 0

        decodeLoop: while true {
            if let e = currentError() { throw e }
            guard let frame = decoder.nextFrame() else { break }

            guard let yTex = ctx.texture(from: frame.pixelBuffer, plane: 0, pixelFormat: .r8Unorm),
                  let cbcrTex = ctx.texture(from: frame.pixelBuffer, plane: 1, pixelFormat: .rg8Unorm) else {
                log("[engine] skip frame: cannot wrap CVPixelBuffer planes")
                continue
            }
            guard let outPB = writer.dequeueBuffer(),
                  let dstTex = ctx.texture(from: outPB, pixelFormat: .bgra8Unorm) else {
                log("[engine] skip frame: cannot acquire output buffer")
                continue
            }

            inflight.wait()

            guard let cb = ctx.queue.makeCommandBuffer() else {
                inflight.signal()
                continue
            }
            cb.label = "frame \(frameCount)"

            // Pass 1 — scale+grade+bypass into the encoder's destination
            // texture. Same pass that produced the (formerly intermediate)
            // base frame.
            graph.encodeMain(
                in: cb,
                ySrc: yTex, cbcrSrc: cbcrTex, dst: dstTex,
                grade: req.grade, bypass: req.bypass,
                frameIndex: UInt32(frameCount), lut: req.lut
            )

            // Pass 2 — libass subtitle composite, if a track is loaded.
            // libass rasterizes at canvas resolution and places each glyph
            // at frame-absolute (dst_x, dst_y), so we composite the full
            // canvas-sized BGRA buffer at the origin with no offset.
            // `composite()` does src-over alpha blending; the buffer is
            // premultiplied BGRA already (see LibassRenderer.blendASSImage).
            // `renderTexture` returns nil between cues — skip the whole
            // composite encoder in that case so we don't dispatch a
            // 2M-pixel no-op pass against a transparent texture.
            if let libass = req.libass {
                let ptsMs = Int64(CMTimeGetSeconds(frame.presentationTime) * 1000.0)
                if let subsTex = try? libass.renderTexture(timeMs: ptsMs, device: ctx.device) {
                    graph.composite(
                        in: cb, overlay: subsTex, dst: dstTex,
                        rectOrigin: SIMD2<Float>(0, 0),
                        rectSize: SIMD2<Float>(Float(req.width), Float(req.height)),
                        opacity: 1.0
                    )
                }
            }

            // Pass 3 — static overlays in z-order (logo + branding text).
            // Pre-rasterised once at job start by the host; per-frame cost
            // here is just an alpha-over composite per overlay. Painted
            // AFTER the libass pass so branding always sits on top of
            // captions, matching the ffmpeg fallback pipeline's ordering.
            for ov in req.staticOverlays {
                graph.composite(
                    in: cb, overlay: ov.texture, dst: dstTex,
                    rectOrigin: ov.rectOrigin, rectSize: ov.rectSize,
                    opacity: ov.opacity
                )
            }

            let pts = frame.presentationTime
            let srcPB = frame.pixelBuffer
            cb.addCompletedHandler { _ in
                defer { inflight.signal() }
                _ = srcPB
                encoderLock.lock()
                do {
                    try writer.append(buffer: outPB, pts: pts)
                } catch {
                    storeError(error)
                }
                encoderLock.unlock()
            }
            cb.commit()

            frameCount += 1
            if frameCount - lastLogFrame >= 60 {
                lastLogFrame = frameCount
                let elapsed = Date().timeIntervalSince(started)
                let srcSecs = CMTimeGetSeconds(pts)
                let ratio = elapsed > 0 ? srcSecs / elapsed : 0
                log(String(format: "[engine] frame %d  src=%.2fs  wall=%.2fs  speed=%.2fx",
                           frameCount, srcSecs, elapsed, ratio))
            }
        }

        for _ in 0..<req.maxInflight { inflight.wait() }
        if let e = firstError { throw e }

        try writer.finish()
        let wall = Date().timeIntervalSince(started)
        let srcDur = CMTimeGetSeconds(decoder.duration)
        let stats = Stats(framesProcessed: frameCount, wallClockSecs: wall, sourceDurationSecs: srcDur)
        log(String(format: "[done] frames=%d  src=%.2fs  wall=%.2fs  speed=%.2fx",
                   stats.framesProcessed, stats.sourceDurationSecs,
                   stats.wallClockSecs, stats.realtimeRatio))
        return stats
    }

    /// Render exactly ONE frame from the source video at PTS ≥ `atSeconds`,
    /// running the same compute graph as `render()` (grade + bypass + LUT),
    /// and write the result to `outURL` as a PNG.
    ///
    /// Used by the editor's "Render one frame" affordance to diff the
    /// engine's output against the live DOM preview at the same PTS. No
    /// encoder, no audio, no MP4 mux — just compute → MTLTexture → PNG.
    ///
    /// Seek: the decoder is initialised with `startAt: target - 0.5s` (or
    /// 0 for early frames) so we don't walk the file from t=0 on a late
    /// PTS. AVAssetReader rounds back to the preceding keyframe; this
    /// loop discards frames until pts ≥ target. Wall-time for a late
    /// frame on a typical 90s recap clip lands well under 1s.
    public func renderFrame(
        _ req: Request,
        atSeconds target: Double,
        outURL: URL,
        log: @escaping (String) -> Void = { _ in }
    ) throws {
        let started = Date()
        // Seek a fraction of a second before the target so the AVAssetReader
        // lands at a keyframe near our PTS and we don't have to walk too
        // many frames forward to find it. 0.5s is plenty even on long-GOP
        // H.264 — most short-form recap encodes have keyframes every 1-2s.
        let seekStart = max(0, target - 0.5)
        let startCM = CMTime(seconds: seekStart, preferredTimescale: 600)
        let decoder = try VideoDecoder(url: req.inputURL, startAt: startCM)

        log("[engine-frame] target=\(String(format: "%.3f", target))s  seek=\(String(format: "%.3f", seekStart))s")
        log("[engine-frame] output: \(req.width)x\(req.height)  decoder: \(Int(decoder.naturalSize.width))x\(Int(decoder.naturalSize.height))")

        let graph = try FilterGraph(ctx: ctx)

        // Standalone destination texture. .shared storage lets the CPU
        // read pixels back without a blit on UMA hardware. `renderTarget`
        // usage is required for compute shaders that write to it; `shaderRead`
        // is what overlay composites sample from for the alpha-over passes.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: req.width,
            height: req.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        guard let dstTex = ctx.device.makeTexture(descriptor: descriptor) else {
            throw MVEError.pipelineStateFailed("renderFrame: cannot allocate dst texture")
        }

        // Walk frames until we find pts ≥ target. Each frame we encode the
        // compute pass into a SINGLE command buffer per loop iteration —
        // when we hit the target we wait on that command buffer, read pixels
        // back, and break.
        var attempts = 0
        var foundPts: Double = -1
        while true {
            attempts += 1
            guard let frame = decoder.nextFrame() else {
                throw MVEError.pipelineStateFailed(
                    "renderFrame: ran out of frames before reaching target \(target)s (decoded \(attempts) frames)"
                )
            }
            let pts = CMTimeGetSeconds(frame.presentationTime)
            // Skip frames before the target. Don't run the compute pass —
            // we're going to throw the result away anyway.
            if pts < target { continue }
            foundPts = pts

            guard let yTex = ctx.texture(from: frame.pixelBuffer, plane: 0, pixelFormat: .r8Unorm),
                  let cbcrTex = ctx.texture(from: frame.pixelBuffer, plane: 1, pixelFormat: .rg8Unorm) else {
                throw MVEError.pipelineStateFailed("renderFrame: cannot wrap CVPixelBuffer planes")
            }
            guard let cb = ctx.queue.makeCommandBuffer() else {
                throw MVEError.pipelineStateFailed("renderFrame: cannot acquire command buffer")
            }
            cb.label = "render-frame target=\(target)"

            // Same pipeline as render(): grade + bypass + optional libass
            // subtitle composite. frameIndex=0 is fine — the noise/grain
            // pass's per-frame hash doesn't matter for a single-frame diff
            // against the preview.
            graph.encodeMain(
                in: cb,
                ySrc: yTex, cbcrSrc: cbcrTex, dst: dstTex,
                grade: req.grade, bypass: req.bypass,
                frameIndex: 0, lut: req.lut
            )
            if let libass = req.libass {
                let ptsMs = Int64(pts * 1000.0)
                if let subsTex = try? libass.renderTexture(timeMs: ptsMs, device: ctx.device) {
                    graph.composite(
                        in: cb, overlay: subsTex, dst: dstTex,
                        rectOrigin: SIMD2<Float>(0, 0),
                        rectSize: SIMD2<Float>(Float(req.width), Float(req.height)),
                        opacity: 1.0
                    )
                }
            }
            cb.commit()
            cb.waitUntilCompleted()
            if let e = cb.error {
                throw MVEError.pipelineStateFailed("renderFrame: GPU error \(e)")
            }
            break
        }

        log(String(format: "[engine-frame] composited frame at pts=%.3fs (sought %d frames forward)",
                   foundPts, attempts))

        // Read pixels back from .shared-storage texture. On UMA this is a
        // zero-copy view of the IOSurface bytes.
        let bytesPerRow = req.width * 4
        var pixels = [UInt8](repeating: 0, count: req.height * bytesPerRow)
        dstTex.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, req.width, req.height),
            mipmapLevel: 0
        )

        // BGRA premultiplied-first is what Metal hands us; CGImage matches
        // that with .premultipliedFirst + .byteOrder32Little.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bm = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw MVEError.pipelineStateFailed("renderFrame: cannot wrap pixels as CGDataProvider")
        }
        guard let cgImage = CGImage(
            width: req.width,
            height: req.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bm,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw MVEError.pipelineStateFailed("renderFrame: CGImage creation failed")
        }

        // PNG-encode to disk. CGImageDestination handles all the chunking,
        // CRC, and IDAT compression — we just hand it the CGImage.
        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw MVEError.pipelineStateFailed("renderFrame: CGImageDestination creation failed")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw MVEError.pipelineStateFailed("renderFrame: PNG finalize failed")
        }

        let wall = Date().timeIntervalSince(started)
        log(String(format: "[done-frame] pts=%.3fs  out=%@  wall=%.2fs",
                   foundPts, outURL.path, wall))
    }
}

/// Common interface that both the audio-less VideoEncoder and the
/// video+audio MuxWriter conform to. The render loop is identical
/// either way — it just hands appended frames to whichever sink the
/// caller's request asked for.
public protocol AnyVideoSink {
    func dequeueBuffer() -> CVPixelBuffer?
    func append(buffer: CVPixelBuffer, pts: CMTime) throws
    func finish() throws
}

/// Short codec name for the engine's `[engine] output:` log line. Keeps
/// the log parser in the Node bridge format-stable across codec additions.
func codecName(_ c: VideoEncoder.Codec) -> String {
    switch c {
    case .h264:        return "h264"
    case .hevc:        return "hevc"
    case .proRes422HQ: return "prores422hq"
    }
}
