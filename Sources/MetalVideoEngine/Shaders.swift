import Foundation

/// All Metal Shading Language source for the engine, embedded as a string
/// and compiled at runtime via `MTLDevice.makeLibrary(source:)`. We do it
/// this way because the Metal Toolchain (which would let us pre-compile
/// `.metal` → `.metallib`) is not installed on the build host — it's a
/// separate Xcode component download. Runtime compile costs ~50–200ms
/// once per process; the resulting library is cached on `MetalContext`.
///
/// Conventions:
///   - All compute kernels take a destination texture and source texture(s),
///     plus a small struct of params via setBytes.
///   - Threadgroup shape is picked at dispatch time from
///     `threadExecutionWidth × maxTotalThreadsPerThreadgroup`.
///   - Color space is Rec.709 limited range coming out of the H.264
///     decoder, normalised to [0,1] RGB inside the graph. We don't claim
///     true scene-linear — that's a separate project (proper transfer-
///     function handling, OCIO, …).
public enum Shaders {
    public static let source: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    // ============================================================
    //  YCbCr (Rec.709 limited) NV12 → linear-ish [0,1] RGB
    // ============================================================
    // BT.709 limited-range YCbCr → linear-ish [0,1] RGB.
    //
    // Why hand-computed instead of `matrix * vec`: the column-major
    // float3x3 layout combined with column constructors is easy to
    // shuffle wrong, and (rare) Metal driver shenanigans can mis-multiply
    // a Y-Cb-Cr column vector. Spelling each channel out keeps the math
    // auditable and matches the textbook Rec.709 conversion exactly.
    //
    //   Y' = (Y_in - 16/255) * 255/219    — undo limited-range luma offset/scale
    //   Cb = (Cb_in - 128/255) * 255/224
    //   Cr = (Cr_in - 128/255) * 255/224
    //
    // The pre-scaled constants below fold those scale factors in so we
    // can just subtract the offset and multiply by 1 (≈ 1.164 etc.).
    inline float3 ycbcrToRGB(float y, float2 cbcr) {
        float Y  = (y       - 16.0/255.0) * (255.0/219.0);
        float Cb = (cbcr.x  - 128.0/255.0) * (255.0/224.0);
        float Cr = (cbcr.y  - 128.0/255.0) * (255.0/224.0);
        float r = Y                   + 1.5748 * Cr;
        float g = Y - 0.1873 * Cb     - 0.4681 * Cr;
        float b = Y + 1.8556 * Cb;
        return saturate(float3(r, g, b));
    }

    // ============================================================
    //  Hash-based pseudo-random for per-pixel noise
    // ============================================================
    //
    //  Cheap GPU random — Wang hash variant. Stable across rays per
    //  pixel coord but reseeds every frame via `seed`. No bandwidth
    //  hit (no noise texture upload) and deterministic for a given
    //  (pos, frame) so the same render twice produces the same noise.
    inline uint wangHash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u;
        x = x ^ (x >> 4);
        x *= 0x27d4eb2du;
        x = x ^ (x >> 15);
        return x;
    }
    inline float hashNoise(uint2 pos, uint seed) {
        uint h = wangHash(pos.x * 1973u + pos.y * 9277u + seed * 26699u);
        return float(h & 0xFFFFFFu) / float(0xFFFFFF);
    }

    // ============================================================
    //  Grade — brightness / contrast / saturation / tint
    // ============================================================
    struct GradeParams {
        float brightness;   // additive,  -1..1
        float contrast;     // multiplicative around 0.5,  ~0.5..1.5
        float saturation;   // 0..2
        float tint;         // hue rotation in radians, -π..π
        float lutMix;       // 0..1, 0 disables LUT lookup entirely
    };

    inline float3 applyGrade(float3 rgb, GradeParams g) {
        rgb = (rgb - 0.5) * g.contrast + 0.5 + g.brightness;
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, g.saturation);
        float c = cos(g.tint), s = sin(g.tint);
        float3x3 hueRot = float3x3(
            float3(0.299 + 0.701*c + 0.168*s, 0.587 - 0.587*c + 0.330*s, 0.114 - 0.114*c - 0.497*s),
            float3(0.299 - 0.299*c - 0.328*s, 0.587 + 0.413*c + 0.035*s, 0.114 - 0.114*c + 0.292*s),
            float3(0.299 - 0.300*c + 1.250*s, 0.587 - 0.588*c - 1.050*s, 0.114 + 0.886*c - 0.203*s)
        );
        rgb = hueRot * rgb;
        return saturate(rgb);
    }

    // 3D LUT sampled via hardware trilinear.
    inline float3 applyLUT(float3 rgb, texture3d<float, access::sample> lut, sampler s, float mix_amt) {
        if (mix_amt <= 0.001) return rgb;
        float3 graded = lut.sample(s, rgb).rgb;
        return mix(rgb, graded, mix_amt);
    }

    // ============================================================
    //  Bypass — geometry + noise + grain + edge-blur
    // ============================================================
    //
    //  Geometry (mirror / zoom / crop) is fused into the source-UV
    //  computation so we never write an intermediate texture. The
    //  inverse mapping looks like:
    //
    //    final UV → fitRect-relative UV (letterbox)
    //              → bypass-cropped UV (crop)
    //              → bypass-zoomed UV (zoom)
    //              → bypass-mirrored UV (mirror)
    //              → source sampler
    //
    //  Each step is just a multiply or add on the 2D coord.
    struct GeomParams {
        float2 dstSize;
        float2 fitOrigin;
        float2 fitSize;
        float2 srcSize;
        // Bypass geometry knobs:
        float  mirror;       // 0 = off, 1 = on (hflip)
        float  zoom;         // 1.0 = none, 1.05 = 5% zoom-in centre
        float  cropPct;      // 0..6 → crop fraction per side
        // Bypass noise / grain (post-grade):
        float  noiseStrength; // 0..50, scaled inside shader
        float  grainStrength; // 0..50 luma-only flicker, scaled
        uint   noiseSeed;     // per-frame seed, drives hash random
        // Bypass edge-blur:
        float  edgeBlurSigma; // 0 = off, >0 = Gaussian sigma in dst px
        float  edgeBlurBand;  // 0.04..0.50 fraction of dst.y per strip
    };

    /// Apply zoom + crop + mirror to a [0,1] UV in source space.
    /// Implementation note: zoom and crop both shrink the *sampled*
    /// region; combining them = (1 - cropPct) * (1 / zoom). Center-
    /// preserving so the focal point stays fixed.
    inline float2 applyBypassUV(float2 uv, float mirror, float zoom, float cropPct) {
        // hflip first — mirroring is just inverting the U coord.
        if (mirror > 0.5) uv.x = 1.0 - uv.x;
        // Centred scale: shrink the sampling rect about (0.5, 0.5).
        float k = (1.0 - cropPct) / zoom;
        uv = (uv - 0.5) * k + 0.5;
        return uv;
    }

    /// Edge-blur Gaussian: applied AFTER all other ops so the bands
    /// fade out the final pixel content. Top + bottom strips of height
    /// `band * dstHeight` ramp from blurred-at-edge → sharp-at-band-
    /// boundary via an alpha mix. The Gaussian itself samples the
    /// *destination* pixel a few times in a small kernel — we can't
    /// re-read the in-flight texture so we sample the source through
    /// the same bypass UV pipeline. This is a wider neighbourhood than
    /// the CPU path uses (which downscales-then-blurs); the alpha
    /// gradient hides the difference.
    inline float3 edgeBlurSample(
        float2 dstUV, float2 dstSize,
        texture2d<float, access::sample> ySrc,
        texture2d<float, access::sample> cbcrSrc,
        GeomParams geom,
        GradeParams grade,
        texture3d<float, access::sample> lut,
        thread float& outAlpha
    );

    // ============================================================
    //  Main fused kernel — runs the whole pipeline per dst pixel.
    // ============================================================
    kernel void scale_grade_lut(
        texture2d<float, access::sample>  ySrc        [[texture(0)]],
        texture2d<float, access::sample>  cbcrSrc     [[texture(1)]],
        texture2d<float, access::write>   dst         [[texture(2)]],
        texture3d<float, access::sample>  lut         [[texture(3)]],
        constant GeomParams&  geom    [[buffer(0)]],
        constant GradeParams& grade   [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uint(geom.dstSize.x) || gid.y >= uint(geom.dstSize.y)) return;

        float2 dstPx = float2(gid);
        // Outside the letterbox rect → black bars (preserved through bypass).
        if (dstPx.x < geom.fitOrigin.x ||
            dstPx.y < geom.fitOrigin.y ||
            dstPx.x >= geom.fitOrigin.x + geom.fitSize.x ||
            dstPx.y >= geom.fitOrigin.y + geom.fitSize.y) {
            dst.write(float4(0, 0, 0, 1), gid);
            return;
        }

        // Map dst → letterbox-rect UV → bypass UV → source.
        float2 fitUV = (dstPx - geom.fitOrigin) / geom.fitSize;
        float2 srcUV = applyBypassUV(fitUV, geom.mirror, geom.zoom, geom.cropPct);

        constexpr sampler bilinear(coord::normalized, filter::linear,
                                   address::clamp_to_edge);
        float y = ySrc.sample(bilinear, srcUV).r;
        float2 cbcr = cbcrSrc.sample(bilinear, srcUV).rg;

        float3 rgb = ycbcrToRGB(y, cbcr);
        rgb = applyGrade(rgb, grade);
        constexpr sampler lutSamp(coord::normalized, filter::linear,
                                  address::clamp_to_edge);
        rgb = applyLUT(rgb, lut, lutSamp, grade.lutMix);

        // Edge-blur: when the dst pixel falls inside one of the two
        // feathered bands, take a few extra samples in a small Gaussian
        // and mix them into the result via the band's alpha ramp.
        if (geom.edgeBlurSigma > 0.001 && geom.edgeBlurBand > 0.001) {
            float dstYNorm = dstPx.y / geom.dstSize.y;
            float band = geom.edgeBlurBand;
            float alpha = 0.0;
            if (dstYNorm <= band) {
                alpha = 1.0 - dstYNorm / band;
            } else if (dstYNorm >= 1.0 - band) {
                alpha = (dstYNorm - (1.0 - band)) / band;
            }
            if (alpha > 0.001) {
                // Small fixed 5-tap kernel; sigma controls radius. We
                // pre-compute the weights inline rather than looping
                // a full 2D NxN — that keeps the inner ALU low and
                // matches the alpha-masked output quality the CPU path
                // achieves with its downscale-then-blur trick.
                float r = clamp(geom.edgeBlurSigma * 1.5, 1.0, 12.0);
                float2 pixSize = 1.0 / geom.fitSize;
                float3 acc = float3(0.0);
                float wsum = 0.0;
                float2 offsets[5] = {
                    float2( 0.0,  0.0),
                    float2( r,   0.0),
                    float2(-r,   0.0),
                    float2( 0.0,  r),
                    float2( 0.0, -r),
                };
                float weights[5] = { 1.0, 0.5, 0.5, 0.5, 0.5 };
                for (int i = 0; i < 5; i++) {
                    float2 sUV = applyBypassUV(fitUV + offsets[i] * pixSize,
                                               geom.mirror, geom.zoom, geom.cropPct);
                    float ys = ySrc.sample(bilinear, sUV).r;
                    float2 cb = cbcrSrc.sample(bilinear, sUV).rg;
                    float3 s = ycbcrToRGB(ys, cb);
                    s = applyGrade(s, grade);
                    s = applyLUT(s, lut, lutSamp, grade.lutMix);
                    acc += s * weights[i];
                    wsum += weights[i];
                }
                float3 blurred = acc / wsum;
                rgb = mix(rgb, blurred, alpha);
            }
        }

        // Noise (per-pixel, per-frame hash). Scale matches ffmpeg's
        // `noise=alls=N:allf=t+u` perceptual range — 50 reads ~similar.
        if (geom.noiseStrength > 0.001) {
            float n = hashNoise(gid, geom.noiseSeed) - 0.5;
            float k = geom.noiseStrength / 100.0;
            rgb = saturate(rgb + float3(n * k));
        }
        // Grain (per-row luma flicker). Lower frequency, only Y axis,
        // applied as multiplicative — reads as filmic dust rather than
        // sensor noise.
        if (geom.grainStrength > 0.001) {
            float g = hashNoise(uint2(gid.y, 0u), geom.noiseSeed) - 0.5;
            float k = geom.grainStrength / 200.0;
            rgb = saturate(rgb * (1.0 + g * k));
        }

        dst.write(float4(rgb, 1.0), gid);
    }

    // ============================================================
    //  Identity LUT seed
    // ============================================================
    kernel void fill_identity_lut(
        texture3d<float, access::write> lut [[texture(0)]],
        uint3 gid [[thread_position_in_grid]]
    ) {
        uint w = lut.get_width();
        if (gid.x >= w || gid.y >= w || gid.z >= w) return;
        float3 rgb = float3(gid) / float3(w - 1);
        lut.write(float4(rgb, 1.0), gid);
    }

    // ============================================================
    //  Image overlay compositor (Phase C / D / E)
    // ============================================================
    //
    //  Premultiplied alpha-over blend of an overlay BGRA texture into
    //  the destination at a positionable rect. One kernel handles
    //  logos, channel-name text rasters, and per-cue subtitle rasters
    //  — they're all RGBA images with alpha at the end of the day.
    //
    //  The rect is given in *destination pixels* so callers can use
    //  the same 1080x1920 PlayRes coordinates the project model uses.
    struct OverlayParams {
        float2 dstSize;
        float2 rectOrigin;   // top-left of overlay rect in dst pixels
        float2 rectSize;     // size of overlay rect in dst pixels
        float  opacity;      // 0..1 final-alpha multiplier
        // Horizontal clip fraction (0..1) — the overlay only draws for
        // U <= clipRight inside its own rect. clipRight == 1.0 is the
        // standard "draw the whole thing" path; lower values wipe the
        // overlay in from left → right at the caller's chosen ratio.
        // Used by karaoke sweep mode to fill a word's highlight colour
        // across its duration. Backward-compatible: existing call sites
        // pass 1.0 and get identical pixel output.
        float  clipRight;
    };

    kernel void overlay_composite(
        texture2d<float, access::sample>      overlay [[texture(0)]],
        texture2d<float, access::read_write>  dst     [[texture(1)]],
        constant OverlayParams& params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uint(params.dstSize.x) || gid.y >= uint(params.dstSize.y)) return;
        float2 dstPx = float2(gid);
        // Outside rect → no work.
        if (dstPx.x < params.rectOrigin.x ||
            dstPx.y < params.rectOrigin.y ||
            dstPx.x >= params.rectOrigin.x + params.rectSize.x ||
            dstPx.y >= params.rectOrigin.y + params.rectSize.y) {
            return;
        }
        // Sample at TEXEL CENTRES: gid is an integer pixel index, so the
        // pixel centre is gid + 0.5. With an integer-snapped rectOrigin
        // and rectSize == the overlay's texel count (the 1:1 composite
        // every static overlay uses), (gid - origin + 0.5)/rectSize lands
        // exactly on each source texel centre, so the linear sampler
        // returns the texel verbatim with no interpolation. Without the
        // +0.5 the sample fell on texel *edges* and bilinear-blended two
        // neighbours, softening every glyph/logo edge — that was the
        // "not crisp vs ffmpeg" blur.
        float2 uv = (dstPx - params.rectOrigin + 0.5) / params.rectSize;
        // Sweep clip: drop fragments past clipRight in U space. The
        // anti-aliased edge falls naturally on word/glyph boundaries
        // when callers align word x-positions to the same grid as the
        // base layer rasterizer — see KaraokeTrack.swift.
        if (uv.x > params.clipRight) return;
        constexpr sampler bilinear(coord::normalized, filter::linear,
                                   address::clamp_to_edge);
        float4 src = overlay.sample(bilinear, uv);
        // Premultiplied alpha-over. Both `src` and `dst` are
        // bgra8Unorm textures; Metal sampler / read+write present them
        // in shader-canonical RGBA order, so no swizzle is needed here.
        // The CVPixelBuffer attached to dst carries Rec.709 colour
        // primaries (set in dequeueBuffer()) so VideoToolbox interprets
        // the bytes as RGB on encode.
        float a = src.a * params.opacity;
        float4 bg = dst.read(gid);
        float4 outc = float4(src.rgb * params.opacity + (1.0 - a) * bg.rgb, 1.0);
        dst.write(outc, gid);
    }
    """#
}
