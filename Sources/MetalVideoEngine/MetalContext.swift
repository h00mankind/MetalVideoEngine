import Foundation
import Metal
import CoreVideo

/// Shared GPU state. One per process is enough — MTLDevice is thread-safe
/// and MTLCommandQueue serialises GPU submission internally.
public final class MetalContext {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let textureCache: CVMetalTextureCache

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MVEError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MVEError.commandQueueFailed
        }
        // Runtime shader compile — sidesteps the missing Metal Toolchain on
        // this machine. Cost is paid once per process (~50-200ms); the
        // resulting MTLLibrary is reused for every render.
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        var cacheOut: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cacheOut
        )
        guard status == kCVReturnSuccess, let cache = cacheOut else {
            throw MVEError.textureCacheFailed(status)
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.textureCache = cache
    }

    /// Wrap a CVPixelBuffer plane as an MTLTexture without copying.
    /// On Apple Silicon UMA both the CPU-visible IOSurface and the
    /// GPU-visible texture point at the same physical bytes — the
    /// "texture" is a view, not a transfer.
    public func texture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Single-plane wrap (BGRA / RGBA outputs from the filter pool).
    public func texture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
}

public enum MVEError: Error, CustomStringConvertible {
    case noMetalDevice
    case commandQueueFailed
    case textureCacheFailed(CVReturn)
    case decoderInitFailed(String)
    case encoderInitFailed(OSStatus)
    case pixelBufferPoolFailed(CVReturn)
    case pipelineStateFailed(String)
    case missingFunction(String)
    case noVideoTrack
    case encodeFailed(OSStatus)
    case writerFailed(String)

    public var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device on this system"
        case .commandQueueFailed: return "MTLCommandQueue creation failed"
        case .textureCacheFailed(let s): return "CVMetalTextureCache create failed: \(s)"
        case .decoderInitFailed(let m): return "decoder init failed: \(m)"
        case .encoderInitFailed(let s): return "encoder init failed: \(s)"
        case .pixelBufferPoolFailed(let s): return "pixel buffer pool failed: \(s)"
        case .pipelineStateFailed(let m): return "pipeline state failed: \(m)"
        case .missingFunction(let n): return "missing Metal function: \(n)"
        case .noVideoTrack: return "asset has no video track"
        case .encodeFailed(let s): return "encode failed: \(s)"
        case .writerFailed(let m): return "writer failed: \(m)"
        }
    }
}
