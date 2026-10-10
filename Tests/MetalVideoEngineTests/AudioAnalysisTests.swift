import XCTest
@testable import MetalVideoEngine

final class AudioAnalysisTests: XCTestCase {

    private func sine(hz: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map {
            amplitude * Float(sin(2.0 * Double.pi * hz * Double($0) / sampleRate))
        }
    }

    private func stereo(left: [Float], right: [Float]) -> [Float] {
        zip(left, right).flatMap { [$0, $1] }
    }

    /// The BS.1770 reference point: a 997 Hz full-scale sine in one
    /// channel reads -3.01 LUFS.
    func testFullScaleSineInOneChannelIsMinusThreeLUFS() {
        for rate in [48_000.0, 44_100.0] {
            let left = sine(hz: 997, amplitude: 1, seconds: 5, sampleRate: rate)
            let levels = AudioAnalysis.measure(
                samples: stereo(left: left, right: [Float](repeating: 0, count: left.count)),
                sampleRate: rate)
            XCTAssertEqual(levels.lufs, -3.01, accuracy: 0.1, "rate \(rate)")
            XCTAssertEqual(levels.peakDBFS, 0, accuracy: 0.01, "rate \(rate)")
        }
    }

    func testSilenceHasNoFiniteLevel() {
        let levels = AudioAnalysis.measure(samples: [Float](repeating: 0, count: 96_000),
                                           sampleRate: 48_000)
        XCTAssertFalse(levels.lufs.isFinite)
        XCTAssertFalse(levels.peakDBFS.isFinite)
    }

    func testBufferShorterThanOneBlockHasNoFiniteLoudness() {
        let levels = AudioAnalysis.measure(samples: [Float](repeating: 0.5, count: 2_000),
                                           sampleRate: 48_000)
        XCTAssertFalse(levels.lufs.isFinite)
        XCTAssertEqual(levels.peakDBFS, -6.02, accuracy: 0.01)
    }

    /// The relative gate drops quiet blocks, so a long quiet tail does
    /// not pull the loudness of the loud part down.
    func testRelativeGateIgnoresQuietTail() {
        let loud = sine(hz: 997, amplitude: 0.5, seconds: 4, sampleRate: 48_000)
        let quiet = sine(hz: 997, amplitude: 0.005, seconds: 12, sampleRate: 48_000)
        let loudOnly = AudioAnalysis.measure(samples: stereo(left: loud, right: loud),
                                             sampleRate: 48_000)
        let both = AudioAnalysis.measure(samples: stereo(left: loud + quiet, right: loud + quiet),
                                         sampleRate: 48_000)
        XCTAssertEqual(both.lufs, loudOnly.lufs, accuracy: 0.3)
    }

    func testSumCountsSamplesOutsideUnitRange() {
        let a = sine(hz: 440, amplitude: 0.8, seconds: 0.5, sampleRate: 48_000)
        let b = sine(hz: 660, amplitude: 0.8, seconds: 0.5, sampleRate: 48_000)
        let expected = zip(a, b).filter { abs($0 + $1) > 1 }.count
        XCTAssertGreaterThan(expected, 0)

        var out = a
        let clamped = AudioMix.sum(into: &out, music: b, gain: 1, countIn: 0..<a.count)
        XCTAssertEqual(clamped, expected)
        XCTAssertEqual(out.map(abs).max()!, 1)

        // The count covers only the window; the samples are the same.
        var windowed = a
        let half = AudioMix.sum(into: &windowed, music: b, gain: 1, countIn: 0..<(a.count / 2))
        XCTAssertEqual(half, zip(a, b).prefix(a.count / 2).filter { abs($0 + $1) > 1 }.count)
        XCTAssertEqual(windowed, out)

        var quiet = a
        XCTAssertEqual(AudioMix.sum(into: &quiet, music: b, gain: 0.1, countIn: 0..<a.count), 0)
    }
}
