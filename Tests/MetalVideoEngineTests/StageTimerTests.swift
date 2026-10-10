import XCTest
@testable import MetalVideoEngine

final class StageTimerTests: XCTestCase {

    func testAddsIntervalsFromFourThreads() {
        let timer = StageTimer()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<250 { timer.add(nanoseconds: 1_000_000) }
        }
        XCTAssertEqual(timer.seconds, 1.0, accuracy: 0.001)
    }

    func testMeasureAddsTheDurationOfTheBody() {
        let timer = StageTimer()
        let value = timer.measure { () -> Int in
            Thread.sleep(forTimeInterval: 0.05)
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertGreaterThanOrEqual(timer.seconds, 0.05)
        XCTAssertLessThan(timer.seconds, 0.5)
    }

    func testMeasureCountsABodyThatThrows() {
        struct Fault: Error {}
        let timer = StageTimer()
        XCTAssertThrowsError(try timer.measure {
            Thread.sleep(forTimeInterval: 0.02)
            throw Fault()
        })
        XCTAssertGreaterThanOrEqual(timer.seconds, 0.02)
    }
}
