import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Audio mix spec: a narration track (always full volume) plus an
/// optional music bed at a configurable relative volume. Mirrors the
/// `amix=weights=1 ${vol}` shape used by render-final in the production
/// path (see src/lib/server/stages.ts).
///
/// We decode each input to 16-bit interleaved stereo at 44.1kHz / 48kHz
/// (whatever the narration sample rate is), sample-summing on the fly,
/// then encode AAC into the output mp4 via AVAssetWriter's audio input.
/// Pre-decoding both tracks to PCM keeps the mix loop straightforward;
/// AVAudioEngine's mixer would also work but adds runtime + sample-rate-
/// conversion ceremony we don't need for two stems.
public enum AudioMix {

    public struct Spec {
        /// Narration track URL. Required.
        public var narrationURL: URL
        /// Optional music bed.
        public var musicURL: URL?
        /// Music bed volume relative to narration, 0..1. 0 = muted.
        public var musicVolume: Float
        /// AAC bitrate for the encoded output (bits/sec).
        public var bitrate: Int

        public init(narrationURL: URL, musicURL: URL? = nil,
                    musicVolume: Float = 0.25, bitrate: Int = 192_000) {
            self.narrationURL = narrationURL
            self.musicURL = musicURL
            self.musicVolume = max(0, min(1, musicVolume))
            self.bitrate = bitrate
        }
    }

    /// PCM read helper: returns interleaved float32 stereo @ 44.1kHz
    /// (resampled if the source is anything else). Length matches the
    /// shorter of (source duration, requested cap). When cap is nil we
    /// read to EOF.
    public static func decodePCM(url: URL, sampleRate: Double = 44_100,
                                 cap: Double? = nil,
                                 log: (String) -> Void = { _ in }) throws -> (samples: [Float], sampleRate: Double) {
        log("[audio] decode start: \(url.lastPathComponent) → \(Int(sampleRate))Hz stereo float32")
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw MVEError.decoderInitFailed("AudioMix: no audio track in \(url.path)")
        }
        let reader = try AVAssetReader(asset: asset)
        // Tell the reader to resample to our common rate and hand us
        // float32 interleaved stereo — the easiest format to sample-sum
        // without further conversion.
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MVEError.decoderInitFailed("AudioMix: cannot add audio reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MVEError.decoderInitFailed("AudioMix: startReading failed")
        }
        var samples: [Float] = []
        // Pre-reserve based on a rough duration estimate to keep the
        // append loop allocation-light. AVAsset.duration is a CMTime
        // we can convert to seconds; cap if provided.
        let durSecs = CMTimeGetSeconds(asset.duration)
        let effSecs = cap.map { min($0, durSecs) } ?? durSecs
        if effSecs.isFinite, effSecs > 0 {
            samples.reserveCapacity(Int(effSecs * sampleRate) * 2)
        }
        var bufferIters = 0
        while let sample = output.copyNextSampleBuffer() {
            bufferIters += 1
            if bufferIters % 100 == 0 {
                log("[audio] decode \(url.lastPathComponent) iter=\(bufferIters) samples=\(samples.count / 2)")
            }
            guard let bb = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
               let p = dataPointer, length > 0 {
                let count = length / MemoryLayout<Float>.size
                let buf = UnsafeBufferPointer<Float>(
                    start: UnsafeRawPointer(p).assumingMemoryBound(to: Float.self),
                    count: count)
                samples.append(contentsOf: buf)
            }
            if let cap = cap, Double(samples.count) / sampleRate / 2 > cap { break }
        }
        log("[audio] decode \(url.lastPathComponent) done: \(samples.count / 2) frames (\(String(format: "%.2f", Double(samples.count) / sampleRate / 2))s)")
        return (samples, sampleRate)
    }

    /// Build the final mixed PCM buffer. Sums narration (gain 1.0) +
    /// optional music (gain = spec.musicVolume). Output length is
    /// narration length when `truncateToNarration` is true (matches
    /// render-final's `amix=duration=first` + `-shortest`).
    public static func mix(spec: Spec,
                           truncateToNarration: Bool = true,
                           log: (String) -> Void = { _ in }) throws
        -> (samples: [Float], sampleRate: Double) {
        let nar = try decodePCM(url: spec.narrationURL, log: log)
        guard let musicURL = spec.musicURL, spec.musicVolume > 0 else {
            return nar
        }
        let cap = truncateToNarration ? Double(nar.samples.count) / nar.sampleRate / 2.0 : nil
        let music = try decodePCM(url: musicURL, sampleRate: nar.sampleRate, cap: cap, log: log)
        var out = nar.samples
        let n = min(out.count, music.samples.count)
        let g = spec.musicVolume
        // Naive sample-sum + clamp. Both stems are already at the same
        // SR / channel layout so we just walk indices.
        for i in 0..<n {
            let v = out[i] + music.samples[i] * g
            out[i] = max(-1, min(1, v))
        }
        return (out, nar.sampleRate)
    }
}

/// Tiny atomic bool for the audio feeder's one-shot guard. We can't
/// pass an inout Bool through the closure, and a class wrapper with a
/// lock is overkill — this gives compare-and-set semantics with a
/// single OSAtomic-equivalent under the hood.
private final class AtomicBool {
    private let lock = NSLock()
    private var v: Bool
    init(value: Bool) { self.v = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    @discardableResult
    func compareAndSet(expected: Bool, new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if v == expected { v = new; return true }
        return false
    }
}

/// MuxWriter: AVAssetWriter wrapping one video AVAssetWriterInput AND
/// one audio AVAssetWriterInput. Used when the render request has an
/// `audio` spec — replaces the standalone VideoEncoder's writer.
///
/// Audio path: we pre-mix the entire PCM stream in `start()` (cheap;
/// 2min @ 44.1kHz × 2 ch × 4B ≈ 42 MB), then chunk it into AAC-friendly
/// CMSampleBuffers and feed them through `audioInput`. AVAssetWriter
/// handles AAC encode on its own thread, no extra plumbing needed.
public final class MuxWriter: AnyVideoSink {
    public let pixelBufferPool: CVPixelBufferPool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private let audioPCM: [Float]
    private let audioSampleRate: Double
    private let audioFormat: CMAudioFormatDescription
    private let semaphore = DispatchSemaphore(value: 0)
    /// Signalled when the audio feeder closure has marked the audio
    /// input finished (either drained naturally or aborted on error).
    /// `finish()` blocks on this before calling `writer.finishWriting`
    /// to avoid a race where the writer tears down audio state while
    /// the feeder closure is mid-append → SIGTRAP from AVF internals.
    private let audioDoneSem = DispatchSemaphore(value: 0)

    public init(url: URL, video: VideoEncoder.Settings, audio: AudioMix.Spec,
                log: @escaping (String) -> Void = { _ in }) throws {
        log("[mux] init out=\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: url)
        let pbAttrs: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferWidthKey): video.width,
            String(kCVPixelBufferHeightKey): video.height,
            String(kCVPixelBufferMetalCompatibilityKey): true,
            String(kCVPixelBufferIOSurfacePropertiesKey): [:],
        ]
        var pool: CVPixelBufferPool?
        let s = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &pool)
        guard s == kCVReturnSuccess, let pool else {
            throw MVEError.pixelBufferPoolFailed(s)
        }
        self.pixelBufferPool = pool

        // ProRes can't live in .mp4; AVAssetWriter rejects the combination.
        // Pick the container off the codec — .mov for ProRes, .mp4 for the
        // h264/hevc paths the rest of the pipeline still uses elsewhere.
        let fileType: AVFileType = (video.codec == .proRes422HQ) ? .mov : .mp4
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: fileType) }
        catch { throw MVEError.writerFailed("AVAssetWriter init: \(error)") }
        writer.shouldOptimizeForNetworkUse = true

        // -- video input. Compression dict comes from VideoEncoder's
        // shared helper so the muxed (audio + video) path encodes
        // bit-identically to the audio-less path.
        let videoSettings = VideoEncoder.buildVideoSettings(video)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: pbAttrs
        )
        guard writer.canAdd(videoInput) else {
            throw MVEError.writerFailed("MuxWriter: cannot add video input")
        }
        writer.add(videoInput)

        // -- audio: pre-mix once, then feed in chunks below.
        let mix = try AudioMix.mix(spec: audio, log: log)
        self.audioPCM = mix.samples
        self.audioSampleRate = mix.sampleRate

        var asbd = AudioStreamBasicDescription(
            mSampleRate: mix.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard st == noErr, let format = fmt else {
            throw MVEError.writerFailed("MuxWriter: CMAudioFormatDescriptionCreate \(st)")
        }
        self.audioFormat = format

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: mix.sampleRate,
            AVEncoderBitRateKey: audio.bitrate,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw MVEError.writerFailed("MuxWriter: cannot add audio input")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw MVEError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = videoAdaptor
        self.audioInput = audioInput

        // Push the entire audio stream up front via a request callback.
        // AVAssetWriter interleaves audio + video on the fly; if we wait
        // until finish() to feed audio, the writer's internal queue for
        // the video stream backs up (it's holding video samples waiting
        // for matching-PTS audio), and `videoInput.isReadyForMoreMediaData`
        // returns false forever — render loop hangs.
        //
        // requestMediaDataWhenReady fires the closure on a background
        // queue every time AVAssetWriter wants more audio; we feed one
        // chunk per call until exhausted, then markAsFinished() on the
        // audio input. Meanwhile the video append path is free to make
        // progress because the writer can now interleave properly.
        let audioQueue = DispatchQueue(label: "mve.audio-feeder")
        let totalAudioFrames = audioPCM.count / 2
        let chunkFrames = Int(audioSampleRate)   // ~1s per chunk
        var nextFrameOffset = 0
        // Track whether the feeder has signalled — `requestMediaDataWhenReady`
        // is called many times as the writer empties the queue. We
        // signal audioDoneSem once when drained, and guard subsequent
        // re-entries so we never call append on a finished input
        // (AVF traps with SIGTRAP if you do — exit 133).
        let audioFinishedBox = AtomicBool(value: false)
        audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
            guard let self = self else { return }
            // Re-entrant guard: AVF can fire this closure once more after
            // we've called markAsFinished — bail immediately.
            if audioFinishedBox.get() { return }
            while self.audioInput.isReadyForMoreMediaData {
                if nextFrameOffset >= totalAudioFrames {
                    if audioFinishedBox.compareAndSet(expected: false, new: true) {
                        self.audioInput.markAsFinished()
                        self.audioDoneSem.signal()
                    }
                    return
                }
                let frames = min(chunkFrames, totalAudioFrames - nextFrameOffset)
                do {
                    try self.appendAudioChunk(frameOffset: nextFrameOffset, frames: frames)
                } catch {
                    if audioFinishedBox.compareAndSet(expected: false, new: true) {
                        self.audioInput.markAsFinished()
                        self.audioDoneSem.signal()
                    }
                    return
                }
                nextFrameOffset += frames
            }
        }
        log("[mux] audio feeder scheduled (\(totalAudioFrames / Int(audioSampleRate))s)")
    }

    /// Push one PCM chunk into the audio input. Extracted so the
    /// requestMediaDataWhenReady callback can call it without inlining
    /// 40 lines of CMBlockBuffer ceremony.
    private func appendAudioChunk(frameOffset: Int, frames: Int) throws {
        let byteLen = frames * 2 * MemoryLayout<Float>.size
        var bb: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: byteLen,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteLen,
            flags: 0, blockBufferOut: &bb
        )
        guard allocStatus == noErr, let block = bb else {
            throw MVEError.writerFailed("MuxWriter: CMBlockBufferCreate \(allocStatus)")
        }
        audioPCM.withUnsafeBufferPointer { ptr in
            let src = UnsafeRawPointer(ptr.baseAddress!).advanced(
                by: frameOffset * 2 * MemoryLayout<Float>.size
            )
            _ = CMBlockBufferReplaceDataBytes(
                with: src, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteLen
            )
        }
        let timescale: CMTimeScale = CMTimeScale(audioSampleRate)
        var sample: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(frameOffset), timescale: timescale)
        let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: audioFormat,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard st == noErr, let sb = sample else {
            throw MVEError.writerFailed("MuxWriter: CMAudioSampleBufferCreate \(st)")
        }
        if !audioInput.append(sb) {
            throw MVEError.writerFailed("MuxWriter: audio append failed, err=\(writer.error?.localizedDescription ?? "nil")")
        }
    }

    public func dequeueBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pb)
        guard s == kCVReturnSuccess, let pb else { return nil }
        // See VideoEncoder.dequeueBuffer() — same colour-space tagging
        // required so AVAssetWriter interprets our BGRA pixels as RGB
        // rather than YCbCr-ish device-space garbage (magenta cast).
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
        return pb
    }

    public func append(buffer: CVPixelBuffer, pts: CMTime) throws {
        while !videoInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !videoAdaptor.append(buffer, withPresentationTime: pts) {
            throw MVEError.writerFailed("MuxWriter: video append failed, err=\(writer.error?.localizedDescription ?? "nil")")
        }
    }

    public func finish() throws {
        // Audio was scheduled via requestMediaDataWhenReady in init —
        // it feeds itself in the background. Close the video side
        // first, then wait for the audio feeder to drain, then close
        // the writer.
        //
        // We MUST wait for the audio feeder before calling
        // finishWriting: AVAssetWriter's finalisation tears down the
        // input state, and a feeder closure still mid-append against
        // that state will trap inside AVFoundation (SIGTRAP / exit 133).
        videoInput.markAsFinished()
        audioDoneSem.wait()
        writer.finishWriting { [weak self] in self?.semaphore.signal() }
        semaphore.wait()
        if writer.status == .failed {
            throw MVEError.writerFailed(writer.error?.localizedDescription ?? "writer failed")
        }
    }
}
