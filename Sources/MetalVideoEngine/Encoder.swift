import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

/// Feed RGBA CVPixelBuffers (written by Metal) into VideoToolbox H.264
/// hardware encode, then mux to MP4 via AVAssetWriter.
///
/// We use AVAssetWriter rather than driving VTCompressionSession directly
/// because it owns the container muxing (movflags +faststart etc.) for
/// us. The writer's videoInput is configured with a pixel-buffer adaptor
/// so we can hand it Metal-written CVPixelBuffers without copying.
public final class VideoEncoder: AnyVideoSink {
    public enum Codec { case h264, hevc, proRes422HQ }

    /// Encode profile preset. `delivery` is the steady-state for final
    /// renders that ship to social platforms (TikTok / Reels / Shorts):
    /// B-frames + look-ahead on, average-bitrate with a peak cap,
    /// CABAC. `draft` matches the old throughput-tuned defaults
    /// (B-frames off, no look-ahead) — useful for preview encodes
    /// where ~5-10% extra bitrate is fine in exchange for shorter
    /// wall time.
    public enum QualityProfile { case delivery, draft }

    public struct Settings {
        public var width: Int
        public var height: Int
        /// Average bitrate target, bits/sec. For `delivery` profile this
        /// is the rate the file averages over its full duration; the
        /// instantaneous peak can run higher within `peakBitrate`.
        public var bitrate: Int
        /// Optional peak bitrate cap (bits/sec). nil → 1.5× average,
        /// which matches what most TikTok delivery presets recommend.
        /// Ignored on ProRes (intra-only, no rate control).
        public var peakBitrate: Int?
        public var frameRate: Int
        public var codec: Codec
        public var quality: QualityProfile
        public init(
            width: Int, height: Int,
            bitrate: Int, peakBitrate: Int? = nil,
            frameRate: Int, codec: Codec = .h264,
            quality: QualityProfile = .delivery
        ) {
            self.width = width; self.height = height
            self.bitrate = bitrate
            self.peakBitrate = peakBitrate
            self.frameRate = frameRate
            self.codec = codec
            self.quality = quality
        }
    }

    public let pixelBufferPool: CVPixelBufferPool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let semaphore = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "mve.encoder")

    /// Build the AVAssetWriter `outputSettings` dict for a video input.
    /// Shared by `VideoEncoder` (audio-less path) and `MuxWriter`
    /// (audio + video path) so both routes encode bit-identically.
    ///
    /// VideoToolbox compression tuning. Two profiles:
    ///
    /// **delivery** (default) — final renders headed to TikTok / Reels /
    ///   Shorts. B-frames ON for ~8% better quality at the same
    ///   bitrate (the social-platform re-encoders downstream love a
    ///   cleaner source). Average-bitrate rate control with a peak
    ///   cap (1.5× avg by default) keeps visual quality consistent
    ///   across complex / simple scenes without bloating size on a
    ///   static intro shot. CABAC is essentially free on Apple
    ///   Silicon's hardware encode block.
    ///
    /// **draft** — preview encodes where wall time matters more than
    ///   the last 8% of quality. B-frames OFF (IPPP only), no
    ///   look-ahead. Encoder finishes each frame the moment it lands.
    ///
    /// **GOP** — key-frame every 2s of source. TikTok scrubs at GOP
    ///   boundaries, so a tight GOP gives the platform finer-grained
    ///   seek targets. Expressed in frames AND in seconds so a VFR
    ///   source still gets sane GOPs.
    ///
    /// **ProfileLevel** — H264HighAutoLevel covers up to Level 5.2;
    ///   for 1080×1920@30 the encoder picks Level 4.0 automatically.
    ///   "High" enables CABAC and 8×8 transform; both essentially
    ///   free on the ASIC and required for the best per-bit quality.
    ///
    /// **HEVC** Main profile (8-bit 4:2:0) is the format that decodes
    ///   on every modern phone. Main10 would unlock HDR but the
    ///   social-platform re-encoders throw the extra bit-depth away,
    ///   so it's not worth the encoder cost.
    public static func buildVideoSettings(_ settings: Settings) -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
        ]
        let allowReordering = settings.quality == .delivery
        let peakBitrate = settings.peakBitrate ?? Int(Double(settings.bitrate) * 1.5)
        let codecType: AVVideoCodecType
        switch settings.codec {
        case .h264:
            codecType = .h264
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: allowReordering,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            ]
            if settings.quality == .delivery {
                // Peak cap expressed as [maxBytes, windowSeconds]. The
                // encoder won't exceed `maxBytes` across any sliding
                // `windowSeconds` window. 1-second window pins the
                // instantaneous peak ~1.5× the average.
                let maxBytesPerSec = peakBitrate / 8
                compression["DataRateLimits"] = [maxBytesPerSec, 1] as [Any]
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        case .hevc:
            codecType = .hevc
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: allowReordering,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ]
            if settings.quality == .delivery {
                let maxBytesPerSec = peakBitrate / 8
                compression["DataRateLimits"] = [maxBytesPerSec, 1] as [Any]
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        case .proRes422HQ:
            // ProRes is intra-only, constant-quality. No bitrate / GOP /
            // profile keys; AVAssetWriter sizes each frame to whatever
            // ProRes 422 HQ wants (~880 Mbps for 1080p).
            codecType = .proRes422HQ
        }
        videoSettings[AVVideoCodecKey] = codecType
        return videoSettings
    }

    public init(url: URL, settings: Settings) throws {
        try? FileManager.default.removeItem(at: url)

        // BGRA8 is the pixel format VideoToolbox happily ingests without
        // an extra colour conversion step on Apple Silicon. The hardware
        // encoder re-derives YCbCr internally.
        let pbAttrs: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferWidthKey): settings.width,
            String(kCVPixelBufferHeightKey): settings.height,
            String(kCVPixelBufferMetalCompatibilityKey): true,
            String(kCVPixelBufferIOSurfacePropertiesKey): [:],
        ]
        var pool: CVPixelBufferPool?
        let s = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &pool)
        guard s == kCVReturnSuccess, let pool else {
            throw MVEError.pixelBufferPoolFailed(s)
        }
        self.pixelBufferPool = pool

        // ProRes is a .mov-only codec — AVAssetWriter refuses to put it in
        // .mp4. h264/hevc go either way; .mp4 is the canonical container the
        // rest of the pipeline expects, so we only switch when the codec
        // demands it.
        let fileType: AVFileType = (settings.codec == .proRes422HQ) ? .mov : .mp4
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw MVEError.writerFailed("AVAssetWriter init: \(error)")
        }
        writer.shouldOptimizeForNetworkUse = true

        // Shared compression-dict helper so MuxWriter (the audio+video
        // path that real renders take) stays bit-identical to this
        // audio-less path.
        let videoSettings = VideoEncoder.buildVideoSettings(settings)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Real-time hint = false lets the encoder buffer more aggressively
        // when we're feeding faster than wall-clock (we are — we're
        // transcoding offline). Setting it to true here would cap the
        // encoder at ~30fps which is the exact opposite of what we want.
        videoInput.expectsMediaDataInRealTime = false
        videoInput.performsMultiPassEncodingIfSupported = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pbAttrs
        )
        guard writer.canAdd(videoInput) else {
            throw MVEError.writerFailed("cannot add video input")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw MVEError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
    }

    /// Borrow a writable pixel buffer from the pool. Caller fills it
    /// (via Metal) and hands it back to `append(buffer:pts:)`.
    public func dequeueBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pb)
        guard s == kCVReturnSuccess, let pb else { return nil }
        // Tag the buffer with sRGB colour primaries + ITU-R 709 transfer
        // + matrix. Without these attachments AVAssetWriter / VideoToolbox
        // assume the BGRA bytes are already in YCbCr-ish space (the
        // device colour space) and the encode comes out shifted —
        // everything looks magenta/pink. Tagging as sRGB tells the
        // encoder "this is RGB, apply the BT.709 matrix to YCbCr-ify
        // it" — what we actually want.
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

    /// Hand a filled buffer to the writer. Blocks if the writer's input
    /// isn't currently ready (backpressure) — this is the natural pacing
    /// mechanism that keeps the decode→render loop from running ahead of
    /// the encoder.
    public func append(buffer: CVPixelBuffer, pts: CMTime) throws {
        while !videoInput.isReadyForMoreMediaData {
            // 1ms wait — encoder is hardware so this almost never sleeps.
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !adaptor.append(buffer, withPresentationTime: pts) {
            let st = writer.status
            throw MVEError.writerFailed("append failed, status=\(st.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
        }
    }

    public func finish() throws {
        videoInput.markAsFinished()
        writer.finishWriting { [weak self] in
            self?.semaphore.signal()
        }
        semaphore.wait()
        if writer.status == .failed {
            throw MVEError.writerFailed(writer.error?.localizedDescription ?? "writer failed")
        }
    }
}
