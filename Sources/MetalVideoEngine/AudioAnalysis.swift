import Foundation

/// Level measurement of a mixed PCM buffer. Read-only: the samples go to
/// the encoder unchanged.
public enum AudioAnalysis {

    public struct Levels: Equatable {
        /// Integrated loudness per ITU-R BS.1770-4. `-infinity` when no
        /// 400 ms block passes the absolute gate (silence, or a buffer
        /// shorter than one block).
        public var lufs: Double
        /// Sample peak in dBFS. `-infinity` for digital silence.
        public var peakDBFS: Double
    }

    /// Direct-form-I biquad with a0 normalised to 1.
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    /// The two K-weighting stages of BS.1770, derived for `sampleRate`
    /// (the spec tabulates 48 kHz only; the mix runs at 44.1 kHz).
    private static func kWeighting(sampleRate: Double) -> (shelf: Biquad, highPass: Biquad) {
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10.0, 3.999843853973347 / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1.0 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2.0 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2.0 * (k * k - 1.0) / a0,
                           a2: (1.0 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1.0 + k / q + k * k
        let highPass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                              a1: 2.0 * (k * k - 1.0) / a0,
                              a2: (1.0 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    /// Measure interleaved stereo float `samples`.
    public static func measure(samples: [Float], sampleRate: Double) -> Levels {
        let frames = samples.count / 2
        var peak: Float = 0
        // Gating blocks are 400 ms with 75 % overlap, so each block is
        // four consecutive 100 ms steps. Sum the K-weighted energy of
        // both channels per step (channel weights are 1.0 for L and R).
        let step = max(1, Int((sampleRate * 0.1).rounded()))
        var stepEnergy = [Double](repeating: 0, count: frames / step)
        var (shelfL, highPassL) = kWeighting(sampleRate: sampleRate)
        var (shelfR, highPassR) = (shelfL, highPassL)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                let l = p[f * 2], r = p[f * 2 + 1]
                peak = max(peak, abs(l), abs(r))
                let s = f / step
                if s < stepEnergy.count {
                    let kl = highPassL.process(shelfL.process(Double(l)))
                    let kr = highPassR.process(shelfR.process(Double(r)))
                    stepEnergy[s] += kl * kl + kr * kr
                }
            }
        }
        let peakDBFS = peak > 0 ? 20.0 * log10(Double(peak)) : -Double.infinity

        guard stepEnergy.count >= 4 else {
            return Levels(lufs: -.infinity, peakDBFS: peakDBFS)
        }
        let blockFrames = Double(step * 4)
        var blocks: [Double] = []
        blocks.reserveCapacity(stepEnergy.count - 3)
        for i in 0...(stepEnergy.count - 4) {
            blocks.append((stepEnergy[i] + stepEnergy[i + 1] + stepEnergy[i + 2] + stepEnergy[i + 3]) / blockFrames)
        }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10.0 * log10(meanSquare) }
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

        let aboveAbsolute = blocks.filter { $0 > 0 && loudness($0) > -70.0 }
        guard !aboveAbsolute.isEmpty else {
            return Levels(lufs: -.infinity, peakDBFS: peakDBFS)
        }
        let relativeGate = loudness(mean(aboveAbsolute)) - 10.0
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else {
            return Levels(lufs: -.infinity, peakDBFS: peakDBFS)
        }
        return Levels(lufs: loudness(mean(gated)), peakDBFS: peakDBFS)
    }
}
