import XCTest
@testable import ConsoCore

final class SafetyCatalogTests: XCTestCase {

    // MARK: Completeness — every category resolves to non-empty, truthful facts.

    func testEveryCleanCategoryHasFacts() {
        for c in CleanCategory.allCases {
            let f = SafetyCatalog.facts(for: .cleanCategory(c))
            XCTAssertFalse(f.title.isEmpty, "\(c) title")
            XCTAssertFalse(f.kind.isEmpty, "\(c) kind")
            XCTAssertFalse(f.whatItIs.isEmpty, "\(c) whatItIs")
            XCTAssertEqual(f.title, c.displayName, "title should match displayName for \(c)")
            // If something regenerates it must say what; if not it must not claim a note.
            if f.regenerates { XCTAssertNotNil(f.regeneratesNote, "\(c) regenerates without note") }
            else { XCTAssertNil(f.regeneratesNote, "\(c) has a note but doesn't regenerate") }
        }
    }

    func testEveryUpdateCategoryHasFacts() {
        for c in UpdateCategory.allCases {
            let f = SafetyCatalog.facts(for: .updateCategory(c))
            XCTAssertFalse(f.whatItIs.isEmpty, "\(c) whatItIs")
            XCTAssertFalse(f.title.isEmpty, "\(c) title")
        }
    }

    // MARK: Recovery-data flagging — the three hidden items, and ONLY those.

    func testHiddenItemsAreFlaggedRecoveryData() {
        for c in [CleanCategory.apfsSnapshots, .iosBackups, .mailAttachments] {
            XCTAssertTrue(SafetyCatalog.facts(for: .cleanCategory(c)).isRecoveryData,
                          "\(c) should be recovery data")
        }
    }

    func testSweepCategoriesAreNotRecoveryData() {
        for c in [CleanCategory.systemCaches, .developerJunk, .browserData, .appLeftovers, .logs, .trash] {
            XCTAssertFalse(SafetyCatalog.facts(for: .cleanCategory(c)).isRecoveryData,
                           "\(c) should NOT be recovery data")
        }
    }

    // MARK: Truthful safety specifics.

    func testCachesAreReversibleAndRegenerate() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.systemCaches))
        XCTAssertTrue(f.isReversible)
        XCTAssertTrue(f.regenerates)
        XCTAssertEqual(f.risk, .low)
    }

    func testTrashIsNotReversible() {
        // Emptying the Trash is permanent — must not be advertised as recoverable.
        XCTAssertFalse(SafetyCatalog.facts(for: .cleanCategory(.trash)).isReversible)
    }

    func testApfsSnapshotsRegenerateAndAreFreedAutomatically() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.apfsSnapshots))
        XCTAssertTrue(f.isRecoveryData)
        XCTAssertTrue(f.regenerates)
        XCTAssertNotNil(f.regeneratesNote)
    }

    func testHomebrewFormulaIsDescribedAsCliLibrary() {
        let f = SafetyCatalog.facts(for: .updateCategory(.library))
        XCTAssertTrue(f.kind.lowercased().contains("library") || f.kind.lowercased().contains("cli"))
        XCTAssertTrue(f.whatItIs.lowercased().contains("command-line") || f.whatItIs.lowercased().contains("library"))
        XCTAssertEqual(f.risk, .low, "updating a library is safe")
    }

    func testSystemUpdateIsCautionLevel() {
        let f = SafetyCatalog.facts(for: .updateCategory(.system))
        XCTAssertEqual(f.risk, .medium)
        XCTAssertFalse(f.isReversible)
    }

    func testFileTargetsCarrySize() {
        let dup = SafetyCatalog.facts(for: .duplicateFile, sizeBytes: 1024)
        XCTAssertEqual(dup.sizeBytes, 1024)
        XCTAssertTrue(dup.isReversible)
        let old = SafetyCatalog.facts(for: .oldFile, sizeBytes: 2048)
        XCTAssertEqual(old.sizeBytes, 2048)
    }

    // MARK: Action kind — the copy must match the page's action, not a generic "remove".

    func testCleanCategoriesAreCleanAction() {
        for c in CleanCategory.allCases {
            XCTAssertEqual(SafetyCatalog.facts(for: .cleanCategory(c)).actionKind, .clean, "\(c)")
        }
    }

    func testUpdateCategoriesAreUpdateActionNotRemove() {
        // The Software page UPDATES — facts must be framed as updates, never removals.
        for c in UpdateCategory.allCases {
            XCTAssertEqual(SafetyCatalog.facts(for: .updateCategory(c)).actionKind, .update, "\(c)")
        }
    }

    func testFileTargetsAreTrashAction() {
        XCTAssertEqual(SafetyCatalog.facts(for: .duplicateFile).actionKind, .trash)
        XCTAssertEqual(SafetyCatalog.facts(for: .oldFile).actionKind, .trash)
    }

    // MARK: Optimize fixes — every catalog fix resolves to truthful, fix-framed facts.

    func testEveryOptimizeFixHasFixFramedFacts() {
        for task in OptimizeCatalog.tasks() {
            let f = SafetyCatalog.facts(for: .fixTask(id: task.id))
            XCTAssertEqual(f.actionKind, .fix, "\(task.id) must be framed as a fix")
            XCTAssertFalse(f.title.isEmpty, "\(task.id) title")
            XCTAssertFalse(f.whatItIs.isEmpty, "\(task.id) whatItIs")
            XCTAssertFalse(f.isRecoveryData, "a fix is never recovery data")
            XCTAssertNil(f.sizeBytes, "fixes have no size")
        }
    }

    func testFixNeedsAdminMatchesHelperRequirement() {
        // A fix that routes a root step to the helper must say it needs admin; a fully
        // user-level fix must not.
        for task in OptimizeCatalog.tasks() where !task.requiresAppPicker {
            let f = SafetyCatalog.facts(for: .fixTask(id: task.id))
            XCTAssertEqual(f.needsAdmin, task.needsHelper,
                           "\(task.id): needsAdmin (\(f.needsAdmin)) should match needsHelper (\(task.needsHelper))")
        }
    }

    func testUserLevelFixesAreSafeToRun() {
        // The two new symptom fixes are user-level, reversible, low-risk → safe verdict.
        for id in ["restart-dock-finder", "icon-cache"] {
            let f = SafetyCatalog.facts(for: .fixTask(id: id))
            XCTAssertFalse(f.needsAdmin, "\(id) is user-level")
            XCTAssertTrue(f.isReversible, "\(id) is reversible")
            XCTAssertEqual(ExplainVerdict.from(f), .safe, "\(id) should be safe to run")
        }
    }

    func testAppPrefsFixIsNotReversibleAndCaution() {
        // Wiping an app's prefs has no undo → caution, never "safe".
        let f = SafetyCatalog.facts(for: .fixTask(id: "app-prefs"))
        XCTAssertFalse(f.isReversible)
        XCTAssertEqual(ExplainVerdict.from(f), .caution)
    }

    func testUnknownFixIdFallsBackHonestly() {
        let f = SafetyCatalog.facts(for: .fixTask(id: "does-not-exist"))
        XCTAssertEqual(f.actionKind, .fix)
        XCTAssertFalse(f.whatItIs.isEmpty)
    }
}
