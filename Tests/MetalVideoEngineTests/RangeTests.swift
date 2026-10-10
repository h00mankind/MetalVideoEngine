import XCTest
@testable import MetalVideoEngine

final class RangeTests: XCTestCase {
    typealias RenderRange = RenderEngine.RenderRange

    func testRejectsABadRange() {
        XCTAssertNil(RenderRange(startSeconds: -1, endSeconds: 2))
        XCTAssertNil(RenderRange(startSeconds: 5, endSeconds: 3))
        XCTAssertNil(RenderRange(startSeconds: 5, endSeconds: 5))
        XCTAssertNil(RenderRange(startSeconds: 0, endSeconds: .infinity))
        XCTAssertNotNil(RenderRange(startSeconds: 8, endSeconds: 10))
    }

    func testClampsToTheTimeline() throws {
        let late = try XCTUnwrap(RenderRange(startSeconds: 25, endSeconds: 30))
        XCTAssertNil(late.clamped(toTimeline: 20))
        let atEnd = try XCTUnwrap(RenderRange(startSeconds: 20, endSeconds: 30))
        XCTAssertNil(atEnd.clamped(toTimeline: 20))
        let over = try XCTUnwrap(RenderRange(startSeconds: 18, endSeconds: 30))
        XCTAssertEqual(over.clamped(toTimeline: 20), RenderRange(startSeconds: 18, endSeconds: 20))
        let inside = try XCTUnwrap(RenderRange(startSeconds: 8, endSeconds: 10))
        XCTAssertEqual(inside.clamped(toTimeline: 20), inside)
    }

    func testFileTimeIsTimelineTimeMinusStart() throws {
        let range = try XCTUnwrap(RenderRange(startSeconds: 8, endSeconds: 10))
        XCTAssertEqual(range.fileSeconds(at: 8.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(range.fileSeconds(at: 8), 0)
        XCTAssertEqual(range.duration, 2)
    }

    func testContainsTheStartButNotTheEnd() throws {
        let range = try XCTUnwrap(RenderRange(startSeconds: 0, endSeconds: 1.00005))
        XCTAssertTrue(range.contains(0))
        XCTAssertTrue(range.contains(1.0))
        XCTAssertFalse(range.contains(1.00005))
        let next = try XCTUnwrap(RenderRange(startSeconds: 1.00005, endSeconds: 2))
        XCTAssertFalse(next.contains(1.0))
    }

    func testAudioTrimKeepsTheRange() {
        // 4 stereo frames per second, 3 s: frame i holds the value i.
        let samples = (0..<12).flatMap { [Float($0), Float($0)] }
        XCTAssertEqual(AudioMix.trimmed(samples, sampleRate: 4, to: 1..<2), [4, 4, 5, 5, 6, 6, 7, 7])
        XCTAssertEqual(AudioMix.trimmed(samples, sampleRate: 4, to: 2.5..<9), [10, 10, 11, 11])
        XCTAssertEqual(AudioMix.trimmed(samples, sampleRate: 4, to: 5..<9), [])
    }
}
