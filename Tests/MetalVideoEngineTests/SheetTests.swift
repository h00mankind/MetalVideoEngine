import XCTest
@testable import MetalVideoEngine

final class SheetTests: XCTestCase {
    func testTimesAreEvenlySpacedWithBothEnds() {
        XCTAssertEqual(Sheet.times(from: 0, to: 2, count: 5), [0, 0.5, 1, 1.5, 2])
        XCTAssertEqual(Sheet.times(from: 1, to: 3, count: 1), [1])
        XCTAssertEqual(Sheet.times(from: 0, to: 2, count: 0), [])
    }

    func testTwelveCellsInSixColumnsGiveTwoRows() {
        let l = Sheet.layout(count: 12, columns: 6, cellWidth: 270, frameWidth: 1080, frameHeight: 1920)
        XCTAssertEqual(l.width, 1620)
        XCTAssertEqual(l.rows, 2)
        XCTAssertEqual(l.cellHeight, 480)
        XCTAssertEqual(l.height, 2 * (480 + l.labelHeight))
    }

    func testFewerCellsThanColumnsGiveANarrowSheet() {
        let l = Sheet.layout(count: 1, columns: 6, cellWidth: 270, frameWidth: 1080, frameHeight: 1920)
        XCTAssertEqual(l.width, 270)
        XCTAssertEqual(l.rows, 1)
    }

    func testLabelMarksATransitionWindow() {
        let windows = [19.0..<20.0]
        XCTAssertEqual(Sheet.label(at: 18.5, transitionWindows: windows), "18.50s")
        XCTAssertEqual(Sheet.label(at: 19.0, transitionWindows: windows), "19.00s T")
        XCTAssertEqual(Sheet.label(at: 19.99, transitionWindows: windows), "19.99s T")
        XCTAssertEqual(Sheet.label(at: 20.0, transitionWindows: windows), "20.00s")
        XCTAssertEqual(Sheet.label(at: 20.5, transitionWindows: windows), "20.50s")
    }

    func testCrossfadeGivesOneTransitionWindow() {
        let url = URL(fileURLWithPath: "/dev/null")
        var a = RenderEngine.Segment(url: url)
        a.transition = RenderEngine.Transition(kind: .crossfade, duration: 1)
        let t = RenderEngine.Timeline.layout(segments: [a, RenderEngine.Segment(url: url)], segSecs: [20, 6])
        XCTAssertEqual(t.transitionWindows, [19.0..<20.0])
        a.transition = RenderEngine.Transition(kind: .dipToBlack, duration: 1)
        let dip = RenderEngine.Timeline.layout(segments: [a, RenderEngine.Segment(url: url)], segSecs: [20, 6])
        XCTAssertEqual(dip.transitionWindows, [])
    }
}
