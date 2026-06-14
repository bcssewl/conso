import XCTest
@testable import ConsoCore

final class TreemapTests: XCTestCase {
    private let bounds = Rect(x: 0, y: 0, width: 400, height: 300)

    private func inputs(_ values: [Double]) -> [TreemapInput] {
        values.enumerated().map { TreemapInput(id: "i\($0.offset)", value: $0.element) }
    }

    func testEmptyInputProducesNoTiles() {
        XCTAssertEqual(Treemap.squarify([], in: bounds), [])
    }

    func testSingleItemFillsBounds() {
        let tiles = Treemap.squarify(inputs([10]), in: bounds)
        XCTAssertEqual(tiles.count, 1)
        let r = tiles[0].rect
        XCTAssertEqual(r.x, bounds.x, accuracy: 0.001)
        XCTAssertEqual(r.y, bounds.y, accuracy: 0.001)
        XCTAssertEqual(r.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(r.height, bounds.height, accuracy: 0.001)
    }

    func testTileCountMatchesInput() {
        let tiles = Treemap.squarify(inputs([50, 30, 20, 12, 8, 5, 3]), in: bounds)
        XCTAssertEqual(tiles.count, 7)
    }

    func testAreaIsConserved() {
        let tiles = Treemap.squarify(inputs([50, 30, 20, 12, 8, 5, 3]), in: bounds)
        let totalArea = tiles.reduce(0) { $0 + $1.rect.area }
        XCTAssertEqual(totalArea, bounds.area, accuracy: bounds.area * 0.0001)
    }

    func testAreasAreProportionalToValues() {
        let values = [50.0, 30, 20]
        let tiles = Treemap.squarify(inputs(values), in: bounds)
        let sum = values.reduce(0, +)
        for (tile, value) in zip(tiles, values) {
            let expected = bounds.area * value / sum
            XCTAssertEqual(tile.rect.area, expected, accuracy: bounds.area * 0.001)
        }
    }

    func testTilesStayWithinBounds() {
        let tiles = Treemap.squarify(inputs([50, 30, 20, 12, 8, 5, 3]), in: bounds)
        let eps = 0.001
        for tile in tiles {
            let r = tile.rect
            XCTAssertGreaterThanOrEqual(r.x, bounds.x - eps)
            XCTAssertGreaterThanOrEqual(r.y, bounds.y - eps)
            XCTAssertLessThanOrEqual(r.maxX, bounds.maxX + eps)
            XCTAssertLessThanOrEqual(r.maxY, bounds.maxY + eps)
        }
    }

    func testTilesDoNotOverlap() {
        let tiles = Treemap.squarify(inputs([50, 30, 20, 12, 8, 5, 3]), in: bounds)
        let eps = 0.01
        for i in tiles.indices {
            for j in (i + 1)..<tiles.count {
                let a = tiles[i].rect, b = tiles[j].rect
                let overlapW = min(a.maxX, b.maxX) - max(a.x, b.x)
                let overlapH = min(a.maxY, b.maxY) - max(a.y, b.y)
                XCTAssertFalse(overlapW > eps && overlapH > eps,
                               "tiles \(tiles[i].id) and \(tiles[j].id) overlap")
            }
        }
    }

    func testIdsPreserved() {
        let tiles = Treemap.squarify(inputs([50, 30, 20]), in: bounds)
        XCTAssertEqual(Set(tiles.map(\.id)), ["i0", "i1", "i2"])
    }

    func testNonPositiveValuesIgnored() {
        let tiles = Treemap.squarify(inputs([50, 0, 30, -5]), in: bounds)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(Set(tiles.map(\.id)), ["i0", "i2"])
    }
}
