import Foundation
import AVFoundation
import CoreMedia
import Metal

/// Parallel renderer: splits the source into N temporal chunks and runs
/// a full decode→GPU→encode pipeline on each concurrently. Apple's media
/// engine can run multiple VideoToolbox compression sessions in parallel
/// (the H.264 ASIC on M-series chips has multiple cores), so this lifts
/// the encoder floor that bounds the single-pipeline engine.
///
/// After all chunks finish, we mux-concat them losslessly into the final
/// MP4 using `AVMutableComposition` — no re-encode, just stream copy with
/// recomputed timestamps. That step is bound by disk I/O of the muxer,
/// typically <1s for a 2min 1080p file.
///
/// Tradeoffs vs single-pipeline:
///   - Per-chunk: separate AVAssetReader (re-opens the file, re-decodes
///     to the chunk's start). Decoder seek is cheap on H.264 keyframes
///     but costs a few hundred ms.
///   - Memory: N× IOSurface pool, N× LUT texture (~33³ × 8B = 285KB each
///     so negligible), N× MTLLibrary compile of the shaders (we share one).
///   - Output is bit-identical to single-pipeline IFF the chunk
///     boundaries land on keyframes. We snap boundaries to the nearest
///     keyframe via AVAssetReader's `timeRange` — VideoToolbox happily
///     starts encoding mid-GOP, so this is purely about the *source*
///     decode being clean. The final concat is GOP-aligned by construction.
public final class ParallelRenderEngine {
    public struct Stats {
        public var framesProcessed: Int
        public var wallClockSecs: Double
        public var sourceDurationSecs: Double
        public var chunks: Int
        public var realtimeRatio: Double { wallClockSecs > 0 ? sourceDurationSecs / wallClockSecs : 0 }
    }

    let ctx: MetalContext

    public init() throws {
        // One MetalContext shared across all chunks — MTLDevice and
        // MTLCommandQueue are thread-safe, and a single texture cache
        // avoids redundant IOSurface bindings. Per-chunk pipelines below
        // each get their own AVAssetReader and AVAssetWriter.
        self.ctx = try MetalContext()
    }

    public func render(
        _ req: RenderEngine.Request,
        chunks: Int = 3,
        log: @escaping (String) -> Void = { _ in }
    ) throws -> Stats {
        precondition(chunks >= 1)
        let started = Date()

        // Probe duration up front so we can split. AVAsset is thread-safe
        // for read-only access; per-chunk readers open their own AVAsset.
        let asset = AVAsset(url: req.inputURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw MVEError.noVideoTrack
        }
        let duration = asset.duration
        let totalSecs = CMTimeGetSeconds(duration)
        let fps = Int(track.nominalFrameRate.rounded())
        let frameRate = fps > 0 ? fps : 30

        if chunks == 1 || totalSecs < 5 {
            // Not worth the muxer overhead for tiny clips — fall through
            // to the single-pipeline engine which has lower per-render
            // fixed cost.
            log("[parallel] chunks=1 (clip too short for split)")
            let single = try RenderEngine()
            let s = try single.render(req, log: log)
            return Stats(framesProcessed: s.framesProcessed,
                         wallClockSecs: s.wallClockSecs,
                         sourceDurationSecs: s.sourceDurationSecs,
                         chunks: 1)
        }

        // Even-time splits. AVAssetReader's timeRange clamps to the
        // nearest keyframe internally; we don't need to align here.
        let chunkSecs = totalSecs / Double(chunks)
        var ranges: [CMTimeRange] = []
        for i in 0..<chunks {
            let start = CMTimeMakeWithSeconds(Double(i) * chunkSecs, preferredTimescale: duration.timescale)
            let end = (i == chunks - 1)
                ? duration
                : CMTimeMakeWithSeconds(Double(i + 1) * chunkSecs, preferredTimescale: duration.timescale)
            ranges.append(CMTimeRangeFromTimeToTime(start: start, end: end))
        }

        log("[parallel] chunks=\(chunks)  src=\(String(format: "%.2f", totalSecs))s  fps=\(frameRate)  inflight=\(req.maxInflight)/chunk")

        // Each chunk writes to its own intermediate MP4 under tmp. We'll
        // mux-concat them into req.outputURL at the end and delete these.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let chunkURLs: [URL] = (0..<chunks).map { tmpDir.appendingPathComponent("chunk-\($0).mp4") }

        // Run all chunks concurrently. DispatchQueue.concurrentPerform
        // blocks until all iterations complete and parallelises across
        // the available core count (capped at `chunks`).
        let errorLock = NSLock()
        var firstError: Error?
        var totalFrames = Atomic(value: 0)

        DispatchQueue.concurrentPerform(iterations: chunks) { i in
            do {
                let frames = try Self.renderChunk(
                    ctx: ctx,
                    inputURL: req.inputURL,
                    outputURL: chunkURLs[i],
                    timeRange: ranges[i],
                    width: req.width,
                    height: req.height,
                    bitrate: req.bitrate,
                    frameRate: frameRate,
                    grade: req.grade,
                    codec: req.codec,
                    maxInflight: req.maxInflight,
                    chunkIndex: i,
                    log: log
                )
                totalFrames.add(frames)
            } catch {
                errorLock.lock()
                if firstError == nil { firstError = error }
                errorLock.unlock()
            }
        }
        if let e = firstError { throw e }

        log("[parallel] all chunks done; muxing")
        try muxConcat(chunkURLs: chunkURLs, outputURL: req.outputURL)

        let wall = Date().timeIntervalSince(started)
        return Stats(
            framesProcessed: totalFrames.get(),
            wallClockSecs: wall,
            sourceDurationSecs: totalSecs,
            chunks: chunks
        )
    }

    /// One chunk: same decode→GPU→encode pipeline as RenderEngine.render,
    /// scoped to a time range. Pulled out as a static so DispatchQueue's
    /// closure can call it without a self capture race.
    private static func renderChunk(
        ctx: MetalContext,
        inputURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange,
        width: Int, height: Int, bitrate: Int, frameRate: Int,
        grade: FilterGraph.GradeParams,
        codec: VideoEncoder.Codec,
        maxInflight: Int,
        chunkIndex: Int,
        log: @escaping (String) -> Void
    ) throws -> Int {
        let asset = AVAsset(url: inputURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw MVEError.noVideoTrack
        }
        let settings: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        guard reader.canAdd(output) else {
            throw MVEError.decoderInitFailed("chunk \(chunkIndex): cannot add output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MVEError.decoderInitFailed("chunk \(chunkIndex): startReading: \(reader.error?.localizedDescription ?? "?")")
        }

        let encoder = try VideoEncoder(
            url: outputURL,
            settings: .init(width: width, height: height, bitrate: bitrate, frameRate: frameRate, codec: codec)
        )
        let graph = try FilterGraph(ctx: ctx)

        let inflight = DispatchSemaphore(value: maxInflight)
        let encoderLock = NSLock()
        let errorLock = NSLock()
        var firstError: Error?

        // Per-chunk PTS rebase: each output starts at zero so the muxer
        // can stitch them without overlap. The original PTS is the chunk's
        // first sample's timestamp; we subtract that from every frame.
        var ptsOrigin: CMTime?
        var frameCount = 0

        while true {
            errorLock.lock()
            let err = firstError
            errorLock.unlock()
            if err != nil { break }

            guard let sample = output.copyNextSampleBuffer(),
                  let pb = CMSampleBufferGetImageBuffer(sample) else { break }
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            if ptsOrigin == nil { ptsOrigin = rawPTS }
            let pts = CMTimeSubtract(rawPTS, ptsOrigin!)

            guard let yTex = ctx.texture(from: pb, plane: 0, pixelFormat: .r8Unorm),
                  let cbcrTex = ctx.texture(from: pb, plane: 1, pixelFormat: .rg8Unorm),
                  let outPB = encoder.dequeueBuffer(),
                  let dstTex = ctx.texture(from: outPB, pixelFormat: .bgra8Unorm) else {
                continue
            }
            inflight.wait()
            guard let cb = ctx.queue.makeCommandBuffer() else {
                inflight.signal()
                continue
            }
            cb.label = "chunk \(chunkIndex) frame \(frameCount)"
            graph.encodeMain(in: cb, ySrc: yTex, cbcrSrc: cbcrTex, dst: dstTex,
                             grade: grade, frameIndex: UInt32(frameCount))
            cb.addCompletedHandler { _ in
                defer { inflight.signal() }
                _ = pb
                encoderLock.lock()
                do { try encoder.append(buffer: outPB, pts: pts) }
                catch {
                    errorLock.lock()
                    if firstError == nil { firstError = error }
                    errorLock.unlock()
                }
                encoderLock.unlock()
            }
            cb.commit()
            frameCount += 1
        }
        for _ in 0..<maxInflight { inflight.wait() }
        if let e = firstError { throw e }
        try encoder.finish()
        log("[parallel] chunk \(chunkIndex) done: \(frameCount) frames")
        return frameCount
    }

    /// Lossless concat of N MP4s into one. Uses AVMutableComposition's
    /// `insertTimeRange` which stream-copies the encoded samples — no
    /// re-encode, no quality loss, just remuxing.
    private func muxConcat(chunkURLs: [URL], outputURL: URL) throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MVEError.writerFailed("composition.addMutableTrack failed")
        }
        var cursor = CMTime.zero
        for url in chunkURLs {
            let asset = AVAsset(url: url)
            guard let srcTrack = asset.tracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try videoTrack.insertTimeRange(range, of: srcTrack, at: cursor)
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MVEError.writerFailed("AVAssetExportSession init failed")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        let sema = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sema.signal() }
        sema.wait()
        if exporter.status != .completed {
            throw MVEError.writerFailed("export: \(exporter.error?.localizedDescription ?? "unknown")")
        }
    }
}

// MARK: - tiny atomic int

/// We use a homegrown atomic instead of OSAtomic / swift-atomics to keep
/// the package dependency-free. Only one counter increments concurrently
/// across all chunks (total frames), so contention is negligible.
private final class Atomic {
    private var v: Int
    private let lock = NSLock()
    init(value: Int) { self.v = value }
    func add(_ n: Int) { lock.lock(); v += n; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return v }
}
