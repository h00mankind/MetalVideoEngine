import Foundation
import Metal
import CoreVideo
import simd

/// One render's worth of GPU pipeline state. Built once at engine init,
/// reused for every frame. Each frame's only per-frame work is encoding
/// a single compute pass into a fresh MTLCommandBuffer.
public final class FilterGraph {
    /// Matches `GeomParams` in Shaders.swift, byte-for-byte. Swift's
    /// SIMD2<Float> has natural alignment 8, Float natural alignment 4,
    /// uint32 alignment 4 — Metal's MSL `float2` / `float` / `uint` use
    /// the same rules so the layout is identical without explicit padding.
    public struct GeomParams {
        var dstSize: SIMD2<Float>
        var fitOrigin: SIMD2<Float>
        var fitSize: SIMD2<Float>
        var srcSize: SIMD2<Float>
        var mirror: Float
        var zoom: Float
        var cropPct: Float
        var noiseStrength: Float
        var grainStrength: Float
        var noiseSeed: UInt32
        var edgeBlurSigma: Float
        var edgeBlurBand: Float
    }

    public struct GradeParams {
        public var brightness: Float = 0
        public var contrast: Float = 1
        public var saturation: Float = 1
        public var tint: Float = 0
        public var lutMix: Float = 0
        public init() {}
    }

    /// Bypass knobs — the subset of `BypassSettings` that hits the GPU
    /// kernel. Speed and audio-side atempo live elsewhere (speed warps
    /// PTS on encode; atempo lives in the audio path).
    public struct BypassParams {
        public var mirror: Bool = false
        public var zoom: Float = 1.0
        public var cropPct: Float = 0          // 0..6, fraction (0.06 = 6%)
        public var colorTintRad: Float = 0     // hue rotation in radians
        public var noise: Float = 0            // 0..50
        public var grain: Float = 0            // 0..50
        public var edgeBlurSigma: Float = 0    // 0..40
        public var edgeBlurBand: Float = 0.12  // 0.04..0.50
        public init() {}
    }

    /// Overlay rect spec used by image/text/subtitle composites.
    /// `clipRight` ∈ [0,1] horizontally clips the overlay — used by
    /// karaoke sweep mode. Default 1.0 (full draw).
    public struct OverlayParams {
        var dstSize: SIMD2<Float>
        var rectOrigin: SIMD2<Float>
        var rectSize: SIMD2<Float>
        var opacity: Float
        var clipRight: Float
    }

    let ctx: MetalContext
    let mainPipeline: MTLComputePipelineState
    let overlayPipeline: MTLComputePipelineState
    public let identityLUT: MTLTexture

    public init(ctx: MetalContext, lutSize: Int = 33) throws {
        self.ctx = ctx
        guard let fn = ctx.library.makeFunction(name: "scale_grade_lut") else {
            throw MVEError.missingFunction("scale_grade_lut")
        }
        do {
            self.mainPipeline = try ctx.device.makeComputePipelineState(function: fn)
        } catch {
            throw MVEError.pipelineStateFailed("scale_grade_lut: \(error)")
        }
        guard let ofn = ctx.library.makeFunction(name: "overlay_composite") else {
            throw MVEError.missingFunction("overlay_composite")
        }
        do {
            self.overlayPipeline = try ctx.device.makeComputePipelineState(function: ofn)
        } catch {
            throw MVEError.pipelineStateFailed("overlay_composite: \(error)")
        }
        self.identityLUT = try Self.makeIdentityLUT(ctx: ctx, size: lutSize)
    }

    public static func letterbox(src: SIMD2<Float>, dst: SIMD2<Float>) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let srcAR = src.x / src.y
        let dstAR = dst.x / dst.y
        if srcAR > dstAR {
            let w = dst.x
            let h = w / srcAR
            return (SIMD2(0, (dst.y - h) / 2), SIMD2(w, h))
        } else {
            let h = dst.y
            let w = h * srcAR
            return (SIMD2((dst.x - w) / 2, 0), SIMD2(w, h))
        }
    }

    /// Encode one frame's main scale+grade+bypass pass into the given
    /// command buffer. After this, callers may chain `composite(...)`
    /// calls to overlay logos / text / subtitles.
    ///
    /// The frame index drives noise seeding so per-frame noise/grain
    /// vary over time without an extra uniform upload from the host.
    public func encodeMain(
        in commandBuffer: MTLCommandBuffer,
        ySrc: MTLTexture,
        cbcrSrc: MTLTexture,
        dst: MTLTexture,
        grade: GradeParams,
        bypass: BypassParams = BypassParams(),
        frameIndex: UInt32 = 0,
        lut: MTLTexture? = nil
    ) {
        guard let cmd = commandBuffer.makeComputeCommandEncoder() else { return }
        cmd.label = "scale_grade_lut"
        cmd.setComputePipelineState(mainPipeline)
        cmd.setTexture(ySrc, index: 0)
        cmd.setTexture(cbcrSrc, index: 1)
        cmd.setTexture(dst, index: 2)
        cmd.setTexture(lut ?? identityLUT, index: 3)

        let srcSize = SIMD2<Float>(Float(ySrc.width), Float(ySrc.height))
        let dstSize = SIMD2<Float>(Float(dst.width), Float(dst.height))
        let fit = Self.letterbox(src: srcSize, dst: dstSize)
        var geom = GeomParams(
            dstSize: dstSize,
            fitOrigin: fit.origin,
            fitSize: fit.size,
            srcSize: srcSize,
            mirror: bypass.mirror ? 1 : 0,
            zoom: max(1.0, bypass.zoom),
            cropPct: max(0, min(0.5, bypass.cropPct)),
            noiseStrength: max(0, bypass.noise),
            grainStrength: max(0, bypass.grain),
            noiseSeed: frameIndex &+ 1,
            edgeBlurSigma: max(0, bypass.edgeBlurSigma),
            edgeBlurBand: max(0, min(0.5, bypass.edgeBlurBand))
        )
        // Tint is folded into the grade matrix — keep grade
        // immutable to callers by overriding tint locally.
        var gradeP = grade
        gradeP.tint = grade.tint + bypass.colorTintRad
        cmd.setBytes(&geom, length: MemoryLayout<GeomParams>.stride, index: 0)
        cmd.setBytes(&gradeP, length: MemoryLayout<GradeParams>.stride, index: 1)

        let w = mainPipeline.threadExecutionWidth
        let h = mainPipeline.maxTotalThreadsPerThreadgroup / w
        let tg = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: dst.width, height: dst.height, depth: 1)
        cmd.dispatchThreads(grid, threadsPerThreadgroup: tg)
        cmd.endEncoding()
    }

    /// Composite an overlay (logo, text raster, subtitle cue) onto an
    /// already-written destination texture. Read-write access — the
    /// kernel reads the existing pixel, blends, and writes back. The
    /// dst texture must have `[.shaderRead, .shaderWrite]` usage.
    ///
    /// rectOrigin/rectSize are in dst pixels. Caller computes them from
    /// 9-cell numpad anchors via `Layout.anchorRect(...)` or directly.
    public func composite(
        in commandBuffer: MTLCommandBuffer,
        overlay: MTLTexture,
        dst: MTLTexture,
        rectOrigin: SIMD2<Float>,
        rectSize: SIMD2<Float>,
        opacity: Float = 1.0,
        clipRight: Float = 1.0
    ) {
        guard let cmd = commandBuffer.makeComputeCommandEncoder() else { return }
        cmd.label = "overlay_composite"
        cmd.setComputePipelineState(overlayPipeline)
        cmd.setTexture(overlay, index: 0)
        cmd.setTexture(dst, index: 1)
        var p = OverlayParams(
            dstSize: SIMD2<Float>(Float(dst.width), Float(dst.height)),
            rectOrigin: rectOrigin,
            rectSize: rectSize,
            opacity: opacity,
            clipRight: max(0, min(1, clipRight))
        )
        cmd.setBytes(&p, length: MemoryLayout<OverlayParams>.stride, index: 0)
        let w = overlayPipeline.threadExecutionWidth
        let h = overlayPipeline.maxTotalThreadsPerThreadgroup / w
        let tg = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: dst.width, height: dst.height, depth: 1)
        cmd.dispatchThreads(grid, threadsPerThreadgroup: tg)
        cmd.endEncoding()
    }

    private static func makeIdentityLUT(ctx: MetalContext, size: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = ctx.device.makeTexture(descriptor: desc) else {
            throw MVEError.pipelineStateFailed("identity LUT texture")
        }
        guard let fn = ctx.library.makeFunction(name: "fill_identity_lut") else {
            throw MVEError.missingFunction("fill_identity_lut")
        }
        let pso = try ctx.device.makeComputePipelineState(function: fn)
        guard let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw MVEError.pipelineStateFailed("identity LUT encode")
        }
        enc.setComputePipelineState(pso)
        enc.setTexture(tex, index: 0)
        let tg = MTLSize(width: 4, height: 4, depth: 4)
        let groups = MTLSize(
            width: (size + 3) / 4,
            height: (size + 3) / 4,
            depth: (size + 3) / 4
        )
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}
