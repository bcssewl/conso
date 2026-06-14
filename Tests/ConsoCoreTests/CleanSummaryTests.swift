import XCTest
@testable import ConsoCore

final class CleanSummaryTests: XCTestCase {

    // MARK: Helpers

    private func target(_ path: String, _ bytes: UInt64, _ cat: CleanCategory) -> CleanTarget {
        CleanTarget(path: path, bytes: bytes, category: cat)
    }

    // MARK: - Aggregation (CleanSummaryFacts.from)

    func testTotalsSumAcrossAllTargets() {
        let targets = [
            target("/a/x", 100, .systemCaches),
            target("/a/y", 200, .systemCaches),
            target("/b/z", 300, .logs),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
        XCTAssertEqual(f.totalBytes, 600)
        XCTAssertEqual(f.totalCount, 3)
    }

    func testPerCategoryBreakdownAggregatesBytesAndCount() {
        let targets = [
            target("/a/x", 100, .systemCaches),
            target("/a/y", 250, .systemCaches),
            target("/b/z", 50, .logs),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
        let caches = f.categories.first { $0.category == .systemCaches }
        let logs = f.categories.first { $0.category == .logs }
        XCTAssertEqual(caches?.bytes, 350)
        XCTAssertEqual(caches?.count, 2)
        XCTAssertEqual(logs?.bytes, 50)
        XCTAssertEqual(logs?.count, 1)
    }

    func testCategoriesSortedLargestFirst() {
        let targets = [
            target("/small/a", 10, .logs),
            target("/big/a", 900, .systemCaches),
            target("/mid/a", 100, .browserData),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
        XCTAssertEqual(f.categories.map(\.category), [.systemCaches, .browserData, .logs])
        XCTAssertEqual(f.largestCategory?.category, .systemCaches)
    }

    func testTopItemsAreLargestFirstAndCapped() {
        let targets = (1...10).map { i in
            target("/a/item-\(i)", UInt64(i) * 100, .systemCaches)
        }
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false, topItemCount: 3)
        XCTAssertEqual(f.topItems.count, 3)
        XCTAssertEqual(f.topItems.map(\.bytes), [1000, 900, 800])
    }

    func testTopItemNameIsLeafNotFullPath() {
        let targets = [target("/Users/me/Library/Caches/com.example/blob.dat", 500, .systemCaches)]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
        XCTAssertEqual(f.topItems.first?.name, "blob.dat")
        // The full path must never appear in the surfaced name (privacy + guardrails).
        XCTAssertFalse(f.topItems.first?.name.contains("/Users/me") ?? true)
    }

    func testIsQuickCleanCarriedThrough() {
        let t = [target("/a/x", 1, .systemCaches)]
        XCTAssertTrue(CleanSummaryFacts.from(targets: t, isQuickClean: true).isQuickClean)
        XCTAssertFalse(CleanSummaryFacts.from(targets: t, isQuickClean: false).isQuickClean)
    }

    // MARK: - Safety derivation (from SafetyCatalog, never the model)

    func testCachesAndLogsAreFullyReversibleNoRecoveryData() {
        let targets = [
            target("/a/x", 100, .systemCaches),
            target("/b/y", 100, .logs),
            target("/c/z", 100, .developerJunk),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        XCTAssertTrue(f.isFullyReversible)
        XCTAssertFalse(f.includesRecoveryData)
    }

    func testTrashCategoryIsNotFullyReversible() {
        // Trash is permanent (SafetyCatalog: isReversible == false).
        let targets = [
            target("/a/x", 100, .systemCaches),
            target("/Trash/y", 100, .trash),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        XCTAssertFalse(f.isFullyReversible)
        XCTAssertFalse(f.includesRecoveryData)
    }

    func testRecoveryDataDetectedForHiddenItems() {
        for cat in [CleanCategory.apfsSnapshots, .iosBackups, .mailAttachments] {
            let targets = [
                target("/a/x", 100, .systemCaches),
                target("/recovery/y", 100, cat),
            ]
            let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
            XCTAssertTrue(f.includesRecoveryData, "\(cat) should be flagged as recovery data")
        }
    }

    func testEmptyTargetsIsNotFullyReversible() {
        // An empty selection has nothing reversible to claim.
        let f = CleanSummaryFacts.from(targets: [], isQuickClean: false)
        XCTAssertFalse(f.isFullyReversible)
        XCTAssertEqual(f.totalCount, 0)
        XCTAssertNil(f.largestCategory)
    }

    // MARK: - Fallback summary (the canonical facts→words mapping)

    func testFallbackReportIsNotAIGenerated() {
        let f = CleanSummaryFacts.from(targets: [target("/a/x", 1_000_000, .systemCaches)],
                                       isQuickClean: false)
        let r = CleanSummaryFallback.report(from: f)
        XCTAssertFalse(r.isAIGenerated)
        XCTAssertFalse(r.summary.isEmpty)
    }

    func testFallbackSummaryStatesTotalSizeAndCount() {
        let targets = [
            target("/a/x", 5_000_000_000, .systemCaches),
            target("/a/y", 4_000_000_000, .developerJunk),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        let s = CleanSummaryFallback.summary(from: f)
        XCTAssertTrue(s.contains(ByteFormat.string(f.totalBytes)), "should state the freed size: \(s)")
        XCTAssertTrue(s.contains("2 items"), "should state the item count: \(s)")
    }

    func testFallbackSummaryNamesLargestCategory() {
        let targets = [
            target("/a/x", 9_000_000_000, .developerJunk),
            target("/b/y", 1_000_000, .logs),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        let s = CleanSummaryFallback.summary(from: f)
        XCTAssertTrue(s.contains(CleanCategory.developerJunk.displayName),
                      "should name the largest category: \(s)")
    }

    func testFallbackSummaryMentionsTrashWhenFullyReversible() {
        let targets = [target("/a/x", 100, .systemCaches), target("/b/y", 100, .logs)]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        let s = CleanSummaryFallback.summary(from: f).lowercased()
        XCTAssertTrue(s.contains("trash"), "reversible clean should mention the Trash: \(s)")
        XCTAssertTrue(s.contains("reversible"), "should say it's reversible: \(s)")
    }

    func testFallbackSummaryFlagsRecoveryData() {
        let targets = [
            target("/a/x", 100, .systemCaches),
            target("/backup/y", 9_000_000_000, .iosBackups),
        ]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false)
        let s = CleanSummaryFallback.summary(from: f).lowercased()
        XCTAssertTrue(s.contains("recovery data"), "should warn about recovery data: \(s)")
    }

    func testFallbackSingleCategoryWording() {
        let targets = [target("/a/x", 100, .systemCaches), target("/a/y", 200, .systemCaches)]
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: true)
        let s = CleanSummaryFallback.summary(from: f)
        XCTAssertTrue(s.contains(CleanCategory.systemCaches.displayName))
        // No "; the rest is" clause when there's only one category.
        XCTAssertFalse(s.contains("the rest is"), "single category shouldn't list a remainder: \(s)")
    }

    func testFallbackEmptySelection() {
        let f = CleanSummaryFacts.from(targets: [], isQuickClean: false)
        let s = CleanSummaryFallback.summary(from: f)
        XCTAssertTrue(s.lowercased().contains("nothing to clean"), "\(s)")
    }

    // MARK: - Protocol double matches the fallback.

    func testFallbackSummarizerMatchesDeterministicReport() async {
        let f = CleanSummaryFacts.from(targets: [target("/a/x", 1_000, .browserData)],
                                       isQuickClean: false)
        let r = await FallbackCleanSummarizer().summarize(f)
        XCTAssertEqual(r, CleanSummaryFallback.report(from: f))
        XCTAssertFalse(r.isAIGenerated)
    }

    // MARK: - Top-N selection equivalence (efficiency fix must not change output)

    func testTopItemsEquivalentForLargeTargetList() {
        // 500 targets with deliberate byte-ties so the path tiebreak is exercised; the bounded
        // top-N must equal the full-sort prefix exactly.
        var targets: [CleanTarget] = []
        for i in 0..<500 {
            // Many share the same byte size so ties are common.
            targets.append(target("/path/\(String(format: "%04d", i))", UInt64((i % 50) * 1000), .systemCaches))
        }
        // Shuffle to make sure ordering doesn't rely on input order.
        targets.shuffle()
        let f = CleanSummaryFacts.from(targets: targets, isQuickClean: false, topItemCount: 5)
        let expected = targets.sortedBySizeThenPath().prefix(5)
            .map { (PathName.leaf($0.path), $0.bytes) }
        XCTAssertEqual(f.topItems.map { ($0.name, $0.bytes) }.map { "\($0.0):\($0.1)" },
                       expected.map { "\($0.0):\($0.1)" })
    }
}

// MARK: - Shared comparator + path helper (pure, reused everywhere)

final class CleanTargetOrderingTests: XCTestCase {
    private func t(_ path: String, _ bytes: UInt64) -> CleanTarget {
        CleanTarget(path: path, bytes: bytes, category: .systemCaches)
    }

    func testSortedBySizeThenPathDescendingByBytes() {
        let sorted = [t("/a", 100), t("/b", 900), t("/c", 300)].sortedBySizeThenPath()
        XCTAssertEqual(sorted.map(\.bytes), [900, 300, 100])
    }

    func testSortedBySizeThenPathTieBrokenByPathAscending() {
        let sorted = [t("/z", 500), t("/a", 500), t("/m", 500)].sortedBySizeThenPath()
        XCTAssertEqual(sorted.map(\.path), ["/a", "/m", "/z"])
    }

    func testPathNameLeafReturnsLastComponent() {
        XCTAssertEqual(PathName.leaf("/Users/me/Library/Caches/com.x/blob.dat"), "blob.dat")
        XCTAssertEqual(PathName.leaf("solo"), "solo")
    }

    func testPathNameLeafFallsBackToWholeStringWhenEmptyLeaf() {
        // "/" has a non-empty last component ("/"), so it is returned as-is.
        XCTAssertEqual(PathName.leaf("/"), "/")
        // A trailing-slash path keeps the real leaf (NSString strips the trailing slash).
        XCTAssertEqual(PathName.leaf("/a/b/"), "b")
    }
}
