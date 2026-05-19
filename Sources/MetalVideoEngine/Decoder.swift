import Foundation
import AVFoundation
import CoreVideo

/// Pull NV12 / 420v CVPixelBuffers out of a video file using
/// AVAssetReader. AVF hands off to VideoToolbox for hardware H.264/HEVC
/// decode and the resulting CVPixelBuffers are IOSurface-backed, which
/// is what makes the zero-copy Metal wrap in `MetalContext.texture(from:)`
/// actually free on Apple Silicon.
public final class VideoDecoder {
    public struct Frame {
        public let pixelBuffer: CVPixelBuffer
        public let presentationTime: CMTime
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    public let nominalFrameRate: Float
    public let naturalSize: CGSize
    public let duration: CMTime
    public let transform: CGAffineTransform

    public convenience init(url: URL) throws {
        try self.init(url: url, startAt: nil)
    }

    /// Construct a decoder that begins reading from `startAt` instead of
    /// the file's natural start. Use this for the single-frame "render
    /// one frame at PTS X" path so we don't walk the file from t=0 just
    /// to drop everything before the target. `nil` matches the default
    /// constructor (whole-file read).
    ///
    /// AVAssetReader's `timeRange` must be set BEFORE `startReading()`,
    /// so this is a separate initialiser rather than a mutable property.
    /// The reader still hands back I-frame-aligned data, so the first
    /// frame returned by `nextFrame()` may sit slightly BEFORE `startAt`
    /// (the closest preceding keyframe); callers that want exactly
    /// "the frame at or after PTS X" should keep pulling until pts ≥ X.
    public init(url: URL, startAt: CMTime?) throws {
        let asset = AVAsset(url: url)
        // AVAsset's tracks(withMediaType:) is async on macOS 13+, but
        // synchronous loading via `tracks` is still supported and is
        // what we want for a CLI tool that's already on a worker thread.
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw MVEError.noVideoTrack
        }
        // 420v == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (NV12,
        // limited range). VideoToolbox-decoded H.264 lands here natively,
        // so requesting it means no extra format conversion before our
        // shader sees the frame.
        let settings: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            // Asking for Metal compatibility ensures the IOSurface backing
            // the buffer is GPU-readable without a copy.
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        if let start = startAt, CMTIME_IS_VALID(start), start.seconds > 0 {
            // CMTimeRange with `kCMTimePositiveInfinity` duration reads
            // from `start` to EOF. AVAssetReader rounds back to the
            // preceding keyframe, so callers may see a frame slightly
            // before `start` — fine for our use case (the engine's
            // `renderFrame` discards frames until pts ≥ target).
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        guard reader.canAdd(output) else {
            throw MVEError.decoderInitFailed("cannot add track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MVEError.decoderInitFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        self.reader = reader
        self.output = output
        self.nominalFrameRate = track.nominalFrameRate
        self.naturalSize = track.naturalSize
        self.duration = asset.duration
        self.transform = track.preferredTransform
    }

    /// Pull the next decoded frame, or nil at EOF / on failure.
    public func nextFrame() -> Frame? {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return Frame(pixelBuffer: pb, presentationTime: pts)
    }
}
