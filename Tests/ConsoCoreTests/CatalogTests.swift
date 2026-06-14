import XCTest
@testable import ConsoCore

final class CleanCatalogTests: XCTestCase {
    func testSelectionAggregation() {
        let items = [
            CleanItem(id: "a", name: "A", detail: "", bytes: 100, isSelected: true),
            CleanItem(id: "b", name: "B", detail: "", bytes: 30, isSelected: false),
            CleanItem(id: "c", name: "C", detail: "", bytes: 20, isSelected: true),
        ]
        XCTAssertEqual(items.selectedCount, 2)
        XCTAssertEqual(items.selectedBytes, 120)
        XCTAssertEqual(items.totalBytes, 150)
    }

    func testCategoriesHaveSomeSelected() {
        let cats = CleanCatalog.categories()
        XCTAssertFalse(cats.isEmpty)
        XCTAssertGreaterThan(cats.selectedCount, 0)
        XCTAssertLessThan(cats.selectedCount, cats.count, "at least one category should default off")
    }

    func testHiddenItemsNeverSelectedByDefault() {
        let hidden = CleanCatalog.hiddenItems()
        XCTAssertFalse(hidden.isEmpty)
        XCTAssertEqual(hidden.selectedCount, 0, "recovery data must never be pre-selected")
    }
}

final class SoftwareCatalogTests: XCTestCase {
    func testActionLabelsRouteToRealInstaller() {
        XCTAssertEqual(UpdateSource.appStore.actionLabel, "Open App Store")
        XCTAssertEqual(UpdateSource.homebrew.actionLabel, "Update")
        XCTAssertEqual(UpdateSource.sparkle.actionLabel, "Open App")
        XCTAssertEqual(UpdateSource.electron.actionLabel, "Open App")
        XCTAssertEqual(UpdateSource.system.actionLabel, "Open Software Update")
    }

    func testTotalBytes() {
        let updates = [
            AppUpdate(id: "1", name: "A", glyph: "A", fromVersion: "1", toVersion: "2", bytes: 1_000, source: .sparkle),
            AppUpdate(id: "2", name: "B", glyph: "B", fromVersion: "1", toVersion: "2", bytes: 2_500, source: .electron),
        ]
        XCTAssertEqual(updates.totalBytes, 3_500)
    }

    func testCatalogHasUpdates() {
        XCTAssertFalse(SoftwareCatalog.appUpdates().isEmpty)
    }
}

final class OptimizeCatalogTests: XCTestCase {
    func testSelectedCount() {
        var tasks = OptimizeCatalog.tasks()
        XCTAssertFalse(tasks.isEmpty)
        XCTAssertEqual(tasks.selectedCount, 0, "nothing runs until the user picks it")
        if !tasks.isEmpty { tasks[0].isSelected = true }
        XCTAssertEqual(tasks.selectedCount, 1)
    }

    func testAllTasksDefaultOff() {
        XCTAssertTrue(OptimizeCatalog.tasks().allSatisfy { !$0.isSelected })
    }

    func testCatalogIncludesTheTwoNewSymptomFixes() {
        let ids = Set(OptimizeCatalog.tasks().map(\.id))
        XCTAssertEqual(OptimizeCatalog.tasks().count, 8, "the two new fixes bring the catalog to 8")
        XCTAssertTrue(ids.contains("restart-dock-finder"))
        XCTAssertTrue(ids.contains("icon-cache"))
        // Task ids must stay unique (they key the explainer + runner).
        XCTAssertEqual(ids.count, OptimizeCatalog.tasks().count, "fix ids must be unique")
    }
}

final class AnalyzeCatalogTests: XCTestCase {
    func testEntriesSortedLargestFirst() {
        let entries = AnalyzeCatalog.entries()
        XCTAssertFalse(entries.isEmpty)
        let sorted = entries.map(\.bytes).sorted(by: >)
        XCTAssertEqual(entries.map(\.bytes), sorted)
    }

    func testUsedIsSumOfEntriesAndFreeIsRemainder() {
        let sum = AnalyzeCatalog.entries().reduce(UInt64(0)) { $0 + $1.bytes }
        XCTAssertEqual(AnalyzeCatalog.usedBytes, sum)
        XCTAssertEqual(AnalyzeCatalog.freeBytes, AnalyzeCatalog.totalBytes - sum)
        XCTAssertLessThanOrEqual(AnalyzeCatalog.usedBytes, AnalyzeCatalog.totalBytes)
    }
}
