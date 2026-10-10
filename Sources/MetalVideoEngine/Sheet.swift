import Foundation
import CoreGraphics
import CoreText

/// Contact sheet for `mve strip`: frame probes at evenly spaced output-
/// timeline times, drawn on a grid with the time under each cell.
public enum Sheet {
    public struct Cell {
        public var image: CGImage
        public var label: String

        public init(image: CGImage, label: String) {
            self.image = image; self.label = label
        }
    }

    /// `count` evenly spaced times, the first at `from` and the last at
    /// `to`. One cell sits at `from`.
    public static func times(from: Double, to: Double, count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [from] : [] }
        return (0..<count).map { from + (to - from) * Double($0) / Double(count - 1) }
    }

    /// Cell label: the time, with ` T` when it is inside a transition
    /// window. The frame probe shows the incoming segment unblended there.
    public static func label(at t: Double, transitionWindows: [Range<Double>]) -> String {
        let time = String(format: "%.2fs", t)
        return transitionWindows.contains { $0.contains(t) } ? time + " T" : time
    }

    public struct Layout: Equatable {
        public var width: Int
        public var height: Int
        public var rows: Int
        public var cellHeight: Int
        public var labelHeight: Int
        public var rowHeight: Int { cellHeight + labelHeight }
    }

    /// Sheet geometry for `count` cells that keep the aspect of a
    /// `frameWidth` × `frameHeight` frame. A last row that is not full
    /// keeps the full width.
    public static func layout(
        count: Int, columns: Int, cellWidth: Int, frameWidth: Int, frameHeight: Int
    ) -> Layout {
        let rows = (count + columns - 1) / columns
        let cellHeight = Int((Double(cellWidth) * Double(frameHeight) / Double(frameWidth)).rounded())
        let labelHeight = max(16, cellWidth / 9)
        return Layout(
            width: min(count, columns) * cellWidth,
            height: rows * (cellHeight + labelHeight),
            rows: rows, cellHeight: cellHeight, labelHeight: labelHeight
        )
    }

    /// `image` drawn `width` px wide. A strip keeps the thumbnail of each
    /// probe, not the full frame.
    public static func thumbnail(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let cg = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return cg.makeImage()
    }

    public static func compose(cells: [Cell], columns: Int, cellWidth: Int) -> CGImage? {
        guard let first = cells.first, columns > 0, cellWidth > 0 else { return nil }
        let l = layout(count: cells.count, columns: columns, cellWidth: cellWidth,
                       frameWidth: first.image.width, frameHeight: first.image.height)
        guard let cg = CGContext(
            data: nil, width: l.width, height: l.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cg.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: l.width, height: l.height))
        cg.interpolationQuality = .high

        let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(l.labelHeight) * 0.6, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        for (i, cell) in cells.enumerated() {
            // CoreGraphics has its origin at the bottom left; rows run
            // from the top.
            let x = CGFloat((i % columns) * cellWidth)
            let rowBottom = CGFloat(l.height - (i / columns + 1) * l.rowHeight)
            cg.draw(cell.image, in: CGRect(x: x, y: rowBottom + CGFloat(l.labelHeight),
                                           width: CGFloat(cellWidth), height: CGFloat(l.cellHeight)))
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: cell.label, attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            cg.textPosition = CGPoint(
                x: x + (CGFloat(cellWidth) - bounds.width) / 2 - bounds.minX,
                y: rowBottom + (CGFloat(l.labelHeight) - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, cg)
        }
        return cg.makeImage()
    }
}
