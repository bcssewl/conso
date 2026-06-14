import Foundation

/// A simple value rectangle, independent of CoreGraphics so the algorithm stays
/// testable and the core library has no UI dependency.
public struct Rect: Sendable, Equatable {
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
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// One weighted input for the treemap.
public struct TreemapInput: Sendable, Equatable {
    public let id: String
    public let value: Double
    public init(id: String, value: Double) {
        self.id = id
        self.value = value
    }
}

/// A laid-out tile: which input it belongs to and the rectangle it occupies.
public struct TreemapTile: Sendable, Equatable, Identifiable {
    public let id: String
    public let value: Double
    public let rect: Rect
    public init(id: String, value: Double, rect: Rect) {
        self.id = id
        self.value = value
        self.rect = rect
    }
}

public enum Treemap {
    /// Lays out weighted items as a squarified treemap (Bruls, Huizing & van Wijk),
    /// which favours near-square tiles over thin slivers. Items with non-positive
    /// values are ignored. Output preserves the input order.
    public static func squarify(_ items: [TreemapInput], in bounds: Rect) -> [TreemapTile] {
        let positive = items.filter { $0.value > 0 }
        guard !positive.isEmpty, bounds.area > 0 else { return [] }

        // Scale values so their sum equals the available area — keeps area exactly conserved.
        let valueSum = positive.reduce(0) { $0 + $1.value }
        let scale = bounds.area / valueSum
        var queue = positive.map { (id: $0.id, value: $0.value, area: $0.value * scale) }

        var tiles: [TreemapTile] = []
        var free = bounds
        var row: [(id: String, value: Double, area: Double)] = []

        while !queue.isEmpty {
            let side = min(free.width, free.height)
            let next = queue[0]
            // Add to the current row only while it keeps the worst aspect ratio from getting worse.
            if row.isEmpty || worstRatio(row + [next], side: side) <= worstRatio(row, side: side) {
                row.append(next)
                queue.removeFirst()
            } else {
                free = layoutRow(row, in: free, into: &tiles)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { free = layoutRow(row, in: free, into: &tiles) }

        // Restore original input order for stable, predictable rendering.
        let order = Dictionary(uniqueKeysWithValues: positive.enumerated().map { ($1.id, $0) })
        return tiles.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    /// The worst (largest) aspect ratio in a row laid along an edge of length `side`.
    private static func worstRatio(_ row: [(id: String, value: Double, area: Double)], side: Double) -> Double {
        let areas = row.map(\.area)
        let sum = areas.reduce(0, +)
        guard sum > 0, side > 0, let maxA = areas.max(), let minA = areas.min(), minA > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * maxA / sum2, sum2 / (side2 * minA))
    }

    /// Places one row of tiles along the shorter edge of `free` and returns the remaining rectangle.
    private static func layoutRow(_ row: [(id: String, value: Double, area: Double)],
                                  in free: Rect, into tiles: inout [TreemapTile]) -> Rect {
        let rowArea = row.reduce(0) { $0 + $1.area }
        guard rowArea > 0 else { return free }

        if free.width >= free.height {
            // Vertical strip on the left; tiles stack top-to-bottom; thickness extends in x.
            let thickness = rowArea / free.height
            var y = free.y
            for item in row {
                let h = item.area / thickness
                tiles.append(TreemapTile(id: item.id, value: item.value,
                                         rect: Rect(x: free.x, y: y, width: thickness, height: h)))
                y += h
            }
            return Rect(x: free.x + thickness, y: free.y, width: free.width - thickness, height: free.height)
        } else {
            // Horizontal strip on top; tiles run left-to-right; thickness extends in y.
            let thickness = rowArea / free.width
            var x = free.x
            for item in row {
                let w = item.area / thickness
                tiles.append(TreemapTile(id: item.id, value: item.value,
                                         rect: Rect(x: x, y: free.y, width: w, height: thickness)))
                x += w
            }
            return Rect(x: free.x, y: free.y + thickness, width: free.width, height: free.height - thickness)
        }
    }
}
