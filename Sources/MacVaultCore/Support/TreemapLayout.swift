import Foundation

/// Platform-neutral rectangle (CoreGraphics is not available on every platform the core builds for).
public struct LayoutRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
/// Areas are proportional to weights; items with zero or negative weight are omitted.
public enum TreemapLayout {
    public static func squarify<ID: Hashable>(_ items: [(id: ID, weight: Double)], in bounds: LayoutRect) -> [(id: ID, rect: LayoutRect)] {
        let positive = items.filter { $0.weight > 0 && $0.weight.isFinite }.sorted { $0.weight > $1.weight }
        let total = positive.reduce(0) { $0 + $1.weight }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = bounds.area / total
        let scaled = positive.map { (id: $0.id, area: $0.weight * scale) }

        var output: [(id: ID, rect: LayoutRect)] = []
        output.reserveCapacity(scaled.count)
        var remaining = bounds
        var row: [(id: ID, area: Double)] = []
        var index = 0

        while index < scaled.count {
            let item = scaled[index]
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
                index += 1
            } else {
                remaining = place(row, in: remaining, into: &output)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &output) }
        return output
    }

    /// Worst aspect ratio in a row laid along a side of length `side`.
    private static func worst<ID>(_ row: [(id: ID, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0 else { return .infinity }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = row.map(\.area).min() ?? 0
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
    }

    /// Lays `row` along the shorter side of `rect` and returns the leftover rectangle.
    private static func place<ID>(_ row: [(id: ID, area: Double)], in rect: LayoutRect,
                                  into output: inout [(id: ID, rect: LayoutRect)]) -> LayoutRect {
        let sum = row.reduce(0) { $0 + $1.area }
        if rect.width >= rect.height {
            // Column on the left.
            let columnWidth = rect.height > 0 ? min(rect.width, sum / rect.height) : 0
            var y = rect.y
            for (offset, item) in row.enumerated() {
                let h = offset == row.count - 1 ? rect.y + rect.height - y : (columnWidth > 0 ? item.area / columnWidth : 0)
                output.append((item.id, LayoutRect(x: rect.x, y: y, width: columnWidth, height: h)))
                y += h
            }
            return LayoutRect(x: rect.x + columnWidth, y: rect.y, width: rect.width - columnWidth, height: rect.height)
        } else {
            // Row along the top.
            let rowHeight = rect.width > 0 ? min(rect.height, sum / rect.width) : 0
            var x = rect.x
            for (offset, item) in row.enumerated() {
                let w = offset == row.count - 1 ? rect.x + rect.width - x : (rowHeight > 0 ? item.area / rowHeight : 0)
                output.append((item.id, LayoutRect(x: x, y: rect.y, width: w, height: rowHeight)))
                x += w
            }
            return LayoutRect(x: rect.x, y: rect.y + rowHeight, width: rect.width, height: rect.height - rowHeight)
        }
    }
}
