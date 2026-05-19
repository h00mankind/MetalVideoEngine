import Foundation
import Metal

/// Load an Adobe `.cube` 3D LUT into an MTLTexture3D suitable for the
/// trilinear sampler in `scale_grade_lut`.
///
/// .cube grammar we accept (the Adobe spec subset our bake script emits):
///
///   # comment
///   TITLE "..."
///   LUT_3D_SIZE N           (cube side length; 17/33/36/64 common)
///   DOMAIN_MIN r g b        (optional — we assume 0)
///   DOMAIN_MAX r g b        (optional — we assume 1; rescale otherwise)
///   <N*N*N lines of "r g b" floats>
///
/// Storage order in the file is x-major (R varies fastest, then G, then B).
/// MTLTexture3D `replace` takes a row-major buffer where index = z*H*W +
/// y*W + x, which matches if we map x↔R, y↔G, z↔B.
public enum LUT {

    /// Read a .cube file from disk and upload it to a 3D RGBA16Float
    /// texture. Returns nil for empty/missing paths so callers can fall
    /// back to the identity LUT silently.
    public static func loadCube(
        path: String,
        device: MTLDevice
    ) throws -> MTLTexture? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            throw MVEError.pipelineStateFailed("LUT.loadCube: cannot read \(path)")
        }
        return try parseAndUpload(text: data, device: device)
    }

    /// Parse + upload from raw .cube text. Split out so callers can feed
    /// in-memory cubes (tests, dynamic recipes) without round-tripping
    /// through the filesystem.
    public static func parseAndUpload(
        text: String,
        device: MTLDevice
    ) throws -> MTLTexture {
        var size = 0
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(64 * 64 * 64) // upper bound; trimmed later

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.isEmpty { continue }
            switch parts[0].uppercased() {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                if parts.count >= 2, let n = Int(parts[1]) { size = n }
            case "DOMAIN_MIN":
                if parts.count >= 4 {
                    domainMin = SIMD3(Float(parts[1]) ?? 0,
                                      Float(parts[2]) ?? 0,
                                      Float(parts[3]) ?? 0)
                }
            case "DOMAIN_MAX":
                if parts.count >= 4 {
                    domainMax = SIMD3(Float(parts[1]) ?? 1,
                                      Float(parts[2]) ?? 1,
                                      Float(parts[3]) ?? 1)
                }
            default:
                // RGB triplet line
                if parts.count >= 3,
                   let r = Float(parts[0]),
                   let g = Float(parts[1]),
                   let b = Float(parts[2]) {
                    samples.append(SIMD3(r, g, b))
                }
            }
        }
        guard size > 0 else {
            throw MVEError.pipelineStateFailed("LUT: missing LUT_3D_SIZE")
        }
        let expected = size * size * size
        guard samples.count == expected else {
            throw MVEError.pipelineStateFailed(
                "LUT: expected \(expected) samples for size \(size), got \(samples.count)"
            )
        }

        // Domain rescale: if the file declared something other than
        // [0,1] for the input domain, the values it stores are absolute
        // — they don't need rescaling, the *sampling coordinate* would,
        // but our shader always samples in [0,1]. Anything outside the
        // declared domain just clips at the texture edge thanks to
        // address::clamp_to_edge. We keep the values as-is.
        _ = (domainMin, domainMax)

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw MVEError.pipelineStateFailed("LUT: makeTexture failed")
        }

        // Pack as RGBA16Float row-major. Half-precision is plenty for a
        // colour LUT (8 mantissa bits ≈ 256 levels per channel post-
        // interpolation, our cubes are 33-36 nodes so we're already
        // averaging multiple .cube samples per output bin).
        // Half encoding via Float16 — natively supported on Apple Silicon.
        var buf = [UInt16](repeating: 0, count: size * size * size * 4)
        for i in 0..<samples.count {
            let s = samples[i]
            let base = i * 4
            buf[base + 0] = floatToHalf(s.x)
            buf[base + 1] = floatToHalf(s.y)
            buf[base + 2] = floatToHalf(s.z)
            buf[base + 3] = floatToHalf(1.0)
        }
        let bytesPerRow = size * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = bytesPerRow * size
        let region = MTLRegionMake3D(0, 0, 0, size, size, size)
        buf.withUnsafeBytes { ptr in
            tex.replace(region: region,
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: ptr.baseAddress!,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerImage)
        }
        return tex
    }

    /// IEEE-754 float32 → float16 bit pattern. We use Swift's Float16
    /// when available; on macOS 11+ it's a first-class type and the
    /// bitPattern accessor returns a UInt16 we can hand straight to MTL.
    @inline(__always) private static func floatToHalf(_ x: Float) -> UInt16 {
        return Float16(x).bitPattern
    }
}
