import Foundation
import AVFoundation
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
    /// A texture overlay composited after the libass subtitle pass —
    /// logo PNGs and CoreText-rasterised channel-name strings both hand
    /// in as this shape. The host pre-rasterises once at job start;
    /// per-frame cost is one graph.composite call per overlay.
    ///
    /// Optional time-driven state: a visibility window plus keyframe
    /// tracks over opacity / position offset / scale / Ken Burns source
    /// window. All nil (the default) → the overlay is static and takes
    /// the exact pre-animation code path.
    public struct OverlayDef {
        public var texture: MTLTexture
        public var rectOrigin: SIMD2<Float>
        public var rectSize: SIMD2<Float>
        public var opacity: Float
        /// Visibility window, output-timeline seconds. nil bound = open.
        public var startSeconds: Double?
        public var endSeconds: Double?
        /// Keyframe tracks. Offsets are PlayRes pixels (scaled to the
        /// canvas like anchor offsets); opacity multiplies the base;
        /// scale is about the rect center.
        public var opacityTrack: Track?
        public var offsetXTrack: Track?
        public var offsetYTrack: Track?
        public var scaleTrack: Track?
        /// Ken Burns source window (image overlays): normalized center
        /// + zoom ≥ 1. The evaluator derives a cover-semantics window.
        public var srcCenterXTrack: Track?
        public var srcCenterYTrack: Track?
        public var srcZoomTrack: Track?

        public init(texture: MTLTexture, rectOrigin: SIMD2<Float>,
                    rectSize: SIMD2<Float>, opacity: Float = 1.0,
                    startSeconds: Double? = nil, endSeconds: Double? = nil,
                    opacityTrack: Track? = nil,
                    offsetXTrack: Track? = nil, offsetYTrack: Track? = nil,
                    scaleTrack: Track? = nil,
                    srcCenterXTrack: Track? = nil, srcCenterYTrack: Track? = nil,
                    srcZoomTrack: Track? = nil) {
            self.texture = texture; self.rectOrigin = rectOrigin
            self.rectSize = rectSize; self.opacity = opacity
            self.startSeconds = startSeconds; self.endSeconds = endSeconds
            self.opacityTrack = opacityTrack
            self.offsetXTrack = offsetXTrack; self.offsetYTrack = offsetYTrack
            self.scaleTrack = scaleTrack
            self.srcCenterXTrack = srcCenterXTrack
            self.srcCenterYTrack = srcCenterYTrack
            self.srcZoomTrack = srcZoomTrack
        }

        func isVisible(at t: Double) -> Bool {
            if let s = startSeconds, t < s { return false }
            if let e = endSeconds, t >= e { return false }
            return true
        }

        /// Per-frame composite parameters, evaluated at output-timeline
        /// second `t`. `canvas` is the render frame size in pixels —
        /// offset tracks are PlayRes values and scale by canvas/PlayRes
        /// exactly like static anchor offsets.
        struct Evaluated {
            var rectOrigin: SIMD2<Float>
            var rectSize: SIMD2<Float>
            var opacity: Float
            var srcOrigin: SIMD2<Float>
            var srcSize: SIMD2<Float>
        }

        func evaluate(at t: Double, canvas: SIMD2<Float>) -> Evaluated {
            var origin = rectOrigin
            var size = rectSize
            var alpha = opacity
            if let tr = opacityTrack { alpha *= max(0, min(1, tr.value(at: t))) }
            if offsetXTrack != nil || offsetYTrack != nil {
                // PlayRes → canvas scale, same convention as anchorRect.
                let kx = canvas.x / 1080
                let ky = canvas.y / 1920
                origin.x += (offsetXTrack?.value(at: t) ?? 0) * kx
                origin.y += (offsetYTrack?.value(at: t) ?? 0) * ky
            }
            if let tr = scaleTrack {
                // About the rect center. No pixel snapping mid-motion —
                // smoothness beats crispness while animating; a track
                // that settles at scale 1 lands back on the snapped rect.
                let s = max(0, tr.value(at: t))
                origin += size * (1 - s) / 2
                size *= s
            }
            // Ken Burns source window: largest sub-rect of the image
            // matching the dest rect's aspect (cover), shrunk by zoom,
            // centered at the tracked point, clamped inside the image.
            var srcOrigin = SIMD2<Float>(0, 0)
            var srcSize = SIMD2<Float>(1, 1)
            if srcCenterXTrack != nil || srcCenterYTrack != nil || srcZoomTrack != nil {
                let imgAspect = Float(texture.width) / Float(texture.height)
                let dstAspect = size.x / max(1, size.y)
                var w: Float = 1, h: Float = 1
                if imgAspect > dstAspect {
                    w = dstAspect / imgAspect
                } else {
                    h = imgAspect / dstAspect
                }
                let zoom = max(1, srcZoomTrack?.value(at: t) ?? 1)
                w /= zoom; h /= zoom
                let cx = min(1 - w / 2, max(w / 2, srcCenterXTrack?.value(at: t) ?? 0.5))
                let cy = min(1 - h / 2, max(h / 2, srcCenterYTrack?.value(at: t) ?? 0.5))
                srcOrigin = SIMD2(cx - w / 2, cy - h / 2)
                srcSize = SIMD2(w, h)
            }
            return Evaluated(rectOrigin: origin, rectSize: size, opacity: alpha,
                             srcOrigin: srcOrigin, srcSize: srcSize)
        }
    }

    /// One boundary's transition in a playlist job — the blend between
    /// a segment and the one after it.
    public struct Transition {
        public enum Kind {
            case cut
            case crossfade
            case dipToBlack
            /// `direction` = unit vector B enters FROM (see the
            /// transition_blend kernel comment).
            case wipe(direction: SIMD2<Float>)
            case slide(direction: SIMD2<Float>)
        }
        public var kind: Kind
        public var duration: Double
        public var ease: Easing

        public init(kind: Kind, duration: Double, ease: Easing = .linear) {
            self.kind = kind; self.duration = duration; self.ease = ease
        }

        /// Overlapping kinds run both decoders during the transition
        /// window; cut and dipToBlack don't overlap (dip composes from
        /// whole-frame fades around a hard cut).
        var overlaps: Bool {
            switch kind {
            case .crossfade, .wipe, .slide: return true
            case .cut, .dipToBlack: return false
            }
        }

        /// (kind index, direction) for the blend kernel's gallery.
        var kernelKind: (UInt32, SIMD2<Float>) {
            switch kind {
            case .crossfade:        return (0, SIMD2(0, 0))
            case .wipe(let d):      return (1, d)
            case .slide(let d):     return (2, d)
            case .cut, .dipToBlack: return (0, SIMD2(0, 0))  // never dispatched
            }
        }

        /// Parse a JobSpec type string. Directions name the edge B
        /// enters from: "wipeLeft" reveals B from the left edge, etc.
        public static func kind(from raw: String) -> Kind? {
            switch raw {
            case "cut":        return .cut
            case "crossfade":  return .crossfade
            case "dipToBlack": return .dipToBlack
            case "wipeLeft":   return .wipe(direction: SIMD2(1, 0))
            case "wipeRight":  return .wipe(direction: SIMD2(-1, 0))
            case "wipeUp":     return .wipe(direction: SIMD2(0, -1))
            case "wipeDown":   return .wipe(direction: SIMD2(0, 1))
            case "slideLeft":  return .slide(direction: SIMD2(1, 0))
            case "slideRight": return .slide(direction: SIMD2(-1, 0))
            case "slideUp":    return .slide(direction: SIMD2(0, -1))
            case "slideDown":  return .slide(direction: SIMD2(0, 1))
            default:           return nil
            }
        }
    }

    /// One clip in a playlist job. `transition` describes the boundary
    /// INTO the next segment; the last segment's transition is ignored.
    public struct Segment {
        public var url: URL
        public var transition: Transition?
        public init(url: URL, transition: Transition? = nil) {
            self.url = url; self.transition = transition
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
        /// Overlays composited on every visible frame in z-order, AFTER
        /// the libass subtitle pass — so text + logo branding sits on
        /// top of captions just like the ffmpeg fallback pipeline.
        /// Each may carry a visibility window + keyframe tracks; plain
        /// defs behave exactly like the old static overlays.
        public var staticOverlays: [OverlayDef]
        /// Optional keyframe tracks over grade/bypass fields. A keyed
        /// field overrides its static value for the whole render.
        public var gradeTracks: GradeTracks?
        public var bypassTracks: BypassTracks?
        /// Whole-frame fade from/to black, composited above subtitles
        /// and overlays. Durations in output-timeline seconds.
        public var fadeInSeconds: Double?
        public var fadeOutSeconds: Double?
        /// Playlist: multiple input segments rendered back-to-back on
        /// one output timeline with per-boundary transitions. When set,
        /// `inputURL` is ignored (kept for the single-input fast path).
        public var segments: [Segment]?
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
            gradeTracks: GradeTracks? = nil,
            bypassTracks: BypassTracks? = nil,
            fadeInSeconds: Double? = nil,
            fadeOutSeconds: Double? = nil,
            segments: [Segment]? = nil,
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
            self.gradeTracks = gradeTracks
            self.bypassTracks = bypassTracks
            self.fadeInSeconds = fadeInSeconds
            self.fadeOutSeconds = fadeOutSeconds
            self.segments = segments
            self.maxInflight = maxInflight
            self.audio = audio
        }

        /// The playlist this request renders: explicit segments, or the
        /// single input as a one-segment playlist.
        var resolvedSegments: [Segment] {
            if let s = segments, !s.isEmpty { return s }
            return [Segment(url: inputURL)]
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

    /// Resolved playlist timeline: per-segment durations, effective
    /// (duration-clamped) boundary transitions, output-timeline offsets,
    /// and the total output duration. Shared by `render` and
    /// `renderFrame` so the full render and the probe agree on where
    /// every output second lands.
    struct Timeline {
        var segments: [Segment]
        var segSecs: [Double]
        var transitions: [Transition?]   // out of segment i; nil for the last
        var offsets: [Double]            // output-timeline start of segment i
        var totalOutSecs: Double

        static func resolve(_ req: Request) throws -> Timeline {
            // Probe every segment's duration up front: the output-
            // timeline offsets (and the progress denominator) need them
            // before the first frame renders. Single-input jobs are a
            // one-segment playlist and take the same path.
            let segments = req.resolvedSegments
            let segSecs: [Double] = try segments.map { seg in
                let asset = AVAsset(url: seg.url)
                guard asset.tracks(withMediaType: .video).first != nil else {
                    throw MVEError.noVideoTrack
                }
                return CMTimeGetSeconds(asset.duration)
            }
            // Clamp transition durations so a window can never outlast
            // either neighbouring segment. An overlapping transition
            // shortens the output: both segments play simultaneously
            // for its duration.
            var transitions: [Transition?] = Array(repeating: nil, count: segments.count)
            var offsets: [Double] = Array(repeating: 0, count: segments.count)
            for i in 0..<(segments.count - 1) {
                var overlap = 0.0
                if var tr = segments[i].transition {
                    tr.duration = max(0, min(tr.duration, min(segSecs[i], segSecs[i + 1])))
                    transitions[i] = tr
                    if tr.overlaps { overlap = tr.duration }
                }
                offsets[i + 1] = offsets[i] + segSecs[i] - overlap
            }
            return Timeline(
                segments: segments,
                segSecs: segSecs,
                transitions: transitions,
                offsets: offsets,
                totalOutSecs: offsets[segments.count - 1] + segSecs[segments.count - 1]
            )
        }

        /// Segment containing output-timeline second `t` (the LATEST
        /// segment whose span covers it — during an overlap the probe
        /// resolves to the incoming segment).
        func segmentIndex(at t: Double) -> Int {
            var idx = 0
            for i in segments.indices where offsets[i] <= t { idx = i }
            return idx
        }
    }

    public func render(_ req: Request, log: @escaping (String) -> Void = { _ in }) throws -> Stats {
        let started = Date()

        let timeline = try Timeline.resolve(req)
        let segments = timeline.segments
        let segSecs = timeline.segSecs
        let transitions = timeline.transitions
        let offsets = timeline.offsets
        let totalOutSecs = timeline.totalOutSecs

        // Tell consumers (Node bridge, scripts) the total output duration
        // before any frame line fires. They need this to compute a real
        // progress ratio — without it the only signal is the per-frame
        // PTS, which has no denominator. Format is intentionally narrow
        // so the bridge regex is unambiguous.
        log(String(format: "[meta] sourceSecs=%.3f", totalOutSecs))

        var decoder = try VideoDecoder(url: segments[0].url)
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
        if segments.count > 1 {
            log(String(format: "[engine] playlist: %d segments  out=%.2fs", segments.count, totalOutSecs))
        }
        if req.audio != nil { log("[engine] audio: enabled") }

        // Created at value 0 and primed with signal()s instead of
        // `value: maxInflight`: libdispatch TRAPS in
        // _dispatch_semaphore_dispose when a semaphore deallocates at a
        // value below its creation value, and the final drain loop
        // (`wait × maxInflight`) intentionally parks the value at 0.
        // With a creation value of 0 the drained state is legal to
        // dispose. The old form crashed every render with SIGTRAP /
        // exit 133 right after `[done]` — and killed sibling chunks
        // mid-run in ParallelRenderEngine.
        // Clamped: maxInflight comes from user job JSON unvalidated; 0
        // would deadlock the first wait() and a negative value traps
        // the Range below.
        let inflightDepth = max(1, req.maxInflight)
        let inflight = DispatchSemaphore(value: 0)
        for _ in 0..<inflightDepth { inflight.signal() }
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

        // Animation support state. The black quad for whole-frame fades
        // is a 1×1 texture stretched across the canvas (bilinear of one
        // texel = constant colour) — no dedicated kernel. Created only
        // when the request fades or a boundary dips to black.
        let canvas = SIMD2<Float>(Float(req.width), Float(req.height))
        let hasDip = transitions.contains {
            if case .dipToBlack = $0?.kind { return true } else { return false }
        }
        let fadeTex: MTLTexture? = (req.fadeInSeconds ?? 0) > 0 || (req.fadeOutSeconds ?? 0) > 0 || hasDip
            ? try Overlay.solidTexture(rgba: SIMD4(0, 0, 0, 1), device: ctx.device)
            : nil

        // Transition overlap state. During an overlapping transition the
        // NEXT segment's decoder runs alongside the current one: its
        // latest frame ≤ the blend time goes through the same main pass
        // into `transTemp`, then the blend kernel mixes it over dst.
        // The temp texture is shared across in-flight frames — Metal's
        // default hazard tracking serializes the passes that touch it,
        // trading a little pipelining for correctness ONLY inside
        // transition windows.
        var pendingDecoder: VideoDecoder?      // next segment, opened at window entry
        var bCurrent: VideoDecoder.Frame?      // latest B frame at/before blend time
        var bNext: VideoDecoder.Frame?         // one-frame lookahead past blend time
        var pushback: VideoDecoder.Frame?      // lookahead handed to the next segment's loop
        var transTemp: MTLTexture?

        for segIdx in segments.indices {
            if let e = currentError() { throw e }
            if segIdx > 0 {
                // The overlap already opened (and partially consumed)
                // this segment's decoder; continue from it so the frames
                // shown blended aren't shown again. A hard cut opens
                // fresh here. The lookahead frame B pulled but never
                // displayed becomes this segment's first frame.
                if let p = pendingDecoder {
                    decoder = p
                    pendingDecoder = nil
                    pushback = bNext
                } else {
                    decoder = try VideoDecoder(url: segments[segIdx].url)
                    pushback = nil
                }
                bCurrent = nil
                bNext = nil
                log("[engine] segment \(segIdx): \(segments[segIdx].url.lastPathComponent)")
            }
            let segOffset = offsets[segIdx]
            let segDur = segSecs[segIdx]
            let transOut = transitions[segIdx]
            let transIn = segIdx > 0 ? transitions[segIdx - 1] : nil

            frameLoop: while true {
                if let e = currentError() { throw e }
                let frame: VideoDecoder.Frame
                if let pb = pushback {
                    frame = pb
                    pushback = nil
                } else if let f = decoder.nextFrame() {
                    frame = f
                } else {
                    break
                }

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

                // Segment-local and output-timeline seconds. Every
                // keyframe track / subtitle cue / fade evaluates against
                // the OUTPUT time; transitions run on segment-local time.
                let localSec = CMTimeGetSeconds(frame.presentationTime)
                let tSec = segOffset + localSec

                // Pass 1 — scale+grade+bypass into the encoder's
                // destination texture. Keyed grade/bypass fields override
                // their static values; unkeyed jobs pass the request
                // structs through byte-identically.
                var grade = req.grade
                var bypass = req.bypass
                req.gradeTracks?.apply(to: &grade, at: tSec)
                req.bypassTracks?.apply(to: &bypass, at: tSec)
                graph.encodeMain(
                    in: cb,
                    ySrc: yTex, cbcrSrc: cbcrTex, dst: dstTex,
                    grade: grade, bypass: bypass,
                    frameIndex: UInt32(frameCount), lut: req.lut
                )

                // Pass 1b — overlapping transition into the next segment.
                // A's cadence drives the window; B's decoder advances to
                // the latest frame at/before the blend time and holds it
                // (nearest-frame-hold handles mixed frame rates).
                var bRetain: CVPixelBuffer?
                if let tr = transOut, tr.overlaps, tr.duration > 0,
                   localSec >= segDur - tr.duration {
                    if pendingDecoder == nil {
                        pendingDecoder = try VideoDecoder(url: segments[segIdx + 1].url)
                        log(String(format: "[engine] transition %.2fs → segment %d opened",
                                   tr.duration, segIdx + 1))
                    }
                    let bTime = localSec - (segDur - tr.duration)
                    while true {
                        if bNext == nil { bNext = pendingDecoder?.nextFrame() }
                        guard let n = bNext else { break }
                        if CMTimeGetSeconds(n.presentationTime) <= bTime {
                            bCurrent = n
                            bNext = nil
                        } else {
                            break
                        }
                    }
                    // First blend frame may land before B's first PTS —
                    // fall back to the lookahead so the window never
                    // shows an unblended pop.
                    if let bf = bCurrent ?? bNext,
                       let byTex = ctx.texture(from: bf.pixelBuffer, plane: 0, pixelFormat: .r8Unorm),
                       let bcbcrTex = ctx.texture(from: bf.pixelBuffer, plane: 1, pixelFormat: .rg8Unorm) {
                        if transTemp == nil {
                            let d = MTLTextureDescriptor.texture2DDescriptor(
                                pixelFormat: .bgra8Unorm,
                                width: req.width, height: req.height, mipmapped: false
                            )
                            d.usage = [.shaderRead, .shaderWrite]
                            d.storageMode = .private
                            transTemp = ctx.device.makeTexture(descriptor: d)
                        }
                        if let temp = transTemp {
                            // B through the same main pass (same grade/
                            // bypass evaluated at the same output time,
                            // same noise seed) so both sides of the blend
                            // carry identical processing.
                            graph.encodeMain(
                                in: cb,
                                ySrc: byTex, cbcrSrc: bcbcrTex, dst: temp,
                                grade: grade, bypass: bypass,
                                frameIndex: UInt32(frameCount), lut: req.lut
                            )
                            let raw = Float(bTime / tr.duration)
                            let progress = tr.ease.apply(max(0, min(1, raw)))
                            let (kindIdx, dir) = tr.kernelKind
                            graph.transitionBlend(
                                in: cb, b: temp, dst: dstTex,
                                progress: progress, kind: kindIdx, direction: dir
                            )
                            bRetain = bf.pixelBuffer
                        }
                    }
                }

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
                    let ptsMs = Int64(tSec * 1000.0)
                    if let subsTex = try? libass.renderTexture(timeMs: ptsMs, device: ctx.device) {
                        graph.composite(
                            in: cb, overlay: subsTex, dst: dstTex,
                            rectOrigin: SIMD2<Float>(0, 0),
                            rectSize: SIMD2<Float>(Float(req.width), Float(req.height)),
                            opacity: 1.0
                        )
                    }
                }

                // Pass 3 — overlays in z-order (logo + branding text).
                // Pre-rasterised once at job start by the host; per-frame
                // cost is one alpha-over composite per *visible* overlay —
                // an overlay outside its window skips the dispatch entirely.
                // Keyframe tracks evaluate to this frame's opacity / rect /
                // source window. Painted AFTER the libass pass so branding
                // always sits on top of captions, matching the ffmpeg
                // fallback pipeline's ordering.
                for ov in req.staticOverlays where ov.isVisible(at: tSec) {
                    let ev = ov.evaluate(at: tSec, canvas: canvas)
                    graph.composite(
                        in: cb, overlay: ov.texture, dst: dstTex,
                        rectOrigin: ev.rectOrigin, rectSize: ev.rectSize,
                        opacity: ev.opacity,
                        srcOrigin: ev.srcOrigin, srcSize: ev.srcSize
                    )
                }

                // Pass 4 — whole-frame fade from/to black, above everything
                // (captions and branding fade with the picture). Job-level
                // fades run on the output timeline; dip-to-black boundaries
                // add segment-local fades (out over the tail's half, in
                // over the head's half — a dip is fades around a hard cut,
                // no overlap decode). Only frames inside a fade window pay
                // the full-canvas composite.
                if let fadeTex {
                    var a = Self.fadeOpacity(
                        at: tSec, duration: totalOutSecs,
                        fadeIn: req.fadeInSeconds, fadeOut: req.fadeOutSeconds
                    )
                    if let tr = transOut, case .dipToBlack = tr.kind, tr.duration > 0 {
                        let half = tr.duration / 2
                        if localSec > segDur - half {
                            a = max(a, Float((localSec - (segDur - half)) / half))
                        }
                    }
                    if let tr = transIn, case .dipToBlack = tr.kind, tr.duration > 0 {
                        let half = tr.duration / 2
                        if localSec < half {
                            a = max(a, Float(1 - localSec / half))
                        }
                    }
                    if a > 0 {
                        graph.composite(
                            in: cb, overlay: fadeTex, dst: dstTex,
                            rectOrigin: SIMD2<Float>(0, 0), rectSize: canvas,
                            opacity: min(1, a)
                        )
                    }
                }

                // Output PTS = segment offset + local PTS. CMTimeAdd
                // reconciles the mixed timescales.
                let pts = CMTimeAdd(
                    CMTimeMakeWithSeconds(segOffset, preferredTimescale: 90000),
                    frame.presentationTime
                )
                let srcPB = frame.pixelBuffer
                let bHold = bRetain  // immutable copy for the sendable closure
                cb.addCompletedHandler { _ in
                    defer { inflight.signal() }
                    _ = srcPB
                    _ = bHold
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
        }

        for _ in 0..<inflightDepth { inflight.wait() }
        if let e = firstError { throw e }

        try writer.finish()
        let wall = Date().timeIntervalSince(started)
        let stats = Stats(framesProcessed: frameCount, wallClockSecs: wall, sourceDurationSecs: totalOutSecs)
        log(String(format: "[done] frames=%d  src=%.2fs  wall=%.2fs  speed=%.2fx",
                   stats.framesProcessed, stats.sourceDurationSecs,
                   stats.wallClockSecs, stats.realtimeRatio))
        return stats
    }

    /// Whole-frame fade coverage at output-timeline second `t`: 1 = fully
    /// black, 0 = no fade. Linear ramps — the standard fade shape; a host
    /// that wants a shaped fade can keyframe overlay opacity instead.
    static func fadeOpacity(
        at t: Double, duration: Double,
        fadeIn: Double?, fadeOut: Double?
    ) -> Float {
        var a: Float = 0
        if let fi = fadeIn, fi > 0, t < fi {
            a = max(a, Float(1 - t / fi))
        }
        if let fo = fadeOut, fo > 0, duration > 0, t > duration - fo {
            a = max(a, Float((t - (duration - fo)) / fo))
        }
        return min(1, max(0, a))
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
        // The probe target is an OUTPUT-timeline second. Resolve which
        // segment covers it (playlists) and probe that segment at the
        // corresponding local time; every keyframe track still evaluates
        // at the output time so mid-animation probes match the full
        // render. Inside an overlap window the probe shows the incoming
        // segment unblended — transitions need two decoded frames and
        // the probe deliberately stays single-frame.
        let timeline = try Timeline.resolve(req)
        let segIdx = timeline.segmentIndex(at: target)
        let segURL = timeline.segments[segIdx].url
        let segOffset = timeline.offsets[segIdx]
        let localTarget = min(max(0, target - segOffset),
                              max(0, timeline.segSecs[segIdx] - 0.001))
        // Seek a fraction of a second before the target so the AVAssetReader
        // lands at a keyframe near our PTS and we don't have to walk too
        // many frames forward to find it. 0.5s is plenty even on long-GOP
        // H.264 — most short-form recap encodes have keyframes every 1-2s.
        let seekStart = max(0, localTarget - 0.5)
        let startCM = CMTime(seconds: seekStart, preferredTimescale: 600)
        let decoder = try VideoDecoder(url: segURL, startAt: startCM)

        if timeline.segments.count > 1 {
            log(String(format: "[engine-frame] playlist: segment %d local=%.3fs", segIdx, localTarget))
        }
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
            let localPts = CMTimeGetSeconds(frame.presentationTime)
            // Skip frames before the target. Don't run the compute pass —
            // we're going to throw the result away anyway.
            if localPts < localTarget { continue }
            // Track evaluation time = output-timeline second of this frame.
            let pts = segOffset + localPts
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
            // subtitle composite + overlays + fade, all evaluated at this
            // frame's PTS so a probe mid-animation shows the exact state
            // the full render would produce. frameIndex=0 is fine — the
            // noise/grain pass's per-frame hash doesn't matter for a
            // single-frame diff against the preview.
            var grade = req.grade
            var bypass = req.bypass
            req.gradeTracks?.apply(to: &grade, at: pts)
            req.bypassTracks?.apply(to: &bypass, at: pts)
            graph.encodeMain(
                in: cb,
                ySrc: yTex, cbcrSrc: cbcrTex, dst: dstTex,
                grade: grade, bypass: bypass,
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
            let canvas = SIMD2<Float>(Float(req.width), Float(req.height))
            for ov in req.staticOverlays where ov.isVisible(at: pts) {
                let ev = ov.evaluate(at: pts, canvas: canvas)
                graph.composite(
                    in: cb, overlay: ov.texture, dst: dstTex,
                    rectOrigin: ev.rectOrigin, rectSize: ev.rectSize,
                    opacity: ev.opacity,
                    srcOrigin: ev.srcOrigin, srcSize: ev.srcSize
                )
            }
            // Whole-frame fades: job-level on the output timeline plus
            // dip-to-black boundary fades on segment-local time — same
            // math as the full render's pass 4.
            var fadeA = Self.fadeOpacity(
                at: pts, duration: timeline.totalOutSecs,
                fadeIn: req.fadeInSeconds, fadeOut: req.fadeOutSeconds
            )
            if let tr = timeline.transitions[segIdx], case .dipToBlack = tr.kind, tr.duration > 0 {
                let half = tr.duration / 2
                if localPts > timeline.segSecs[segIdx] - half {
                    fadeA = max(fadeA, Float((localPts - (timeline.segSecs[segIdx] - half)) / half))
                }
            }
            if segIdx > 0, let tr = timeline.transitions[segIdx - 1],
               case .dipToBlack = tr.kind, tr.duration > 0 {
                let half = tr.duration / 2
                if localPts < half {
                    fadeA = max(fadeA, Float(1 - localPts / half))
                }
            }
            if fadeA > 0 {
                let fadeTex = try Overlay.solidTexture(rgba: SIMD4(0, 0, 0, 1), device: ctx.device)
                graph.composite(
                    in: cb, overlay: fadeTex, dst: dstTex,
                    rectOrigin: SIMD2<Float>(0, 0), rectSize: canvas,
                    opacity: min(1, fadeA)
                )
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
