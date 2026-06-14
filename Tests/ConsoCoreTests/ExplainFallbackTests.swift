import XCTest
@testable import ConsoCore

final class ExplainFallbackTests: XCTestCase {

    // MARK: Verdict derivation (the single source of truth).

    func testSafeVerdictForLowRiskReversibleNonRecovery() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.systemCaches))
        XCTAssertEqual(ExplainVerdict.from(f), .safe)
    }

    func testRecoveryDataAlwaysWinsVerdict() {
        for c in [CleanCategory.apfsSnapshots, .iosBackups, .mailAttachments] {
            XCTAssertEqual(ExplainVerdict.from(SafetyCatalog.facts(for: .cleanCategory(c))), .recoveryData)
        }
    }

    func testMediumRiskIsCaution() {
        XCTAssertEqual(ExplainVerdict.from(SafetyCatalog.facts(for: .cleanCategory(.appLeftovers))), .caution)
        XCTAssertEqual(ExplainVerdict.from(SafetyCatalog.facts(for: .updateCategory(.system))), .caution)
    }

    func testNonReversibleNonRecoveryIsCaution() {
        // Trash is low-risk-ish but permanent → still caution, never "safe".
        XCTAssertEqual(ExplainVerdict.from(SafetyCatalog.facts(for: .cleanCategory(.trash))), .caution)
    }

    // MARK: Fallback report shape.

    func testReportIsNotAIGeneratedAndCarriesTitle() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.systemCaches), sizeBytes: 1_000_000)
        let r = ExplainFallback.report(from: f)
        XCTAssertFalse(r.isAIGenerated)
        XCTAssertEqual(r.title, f.title)
        XCTAssertEqual(r.verdict, .safe)
        XCTAssertFalse(r.summary.isEmpty)
        XCTAssertTrue(r.summary.contains(f.title))
    }

    func testRecoveryDataSummaryMentionsDefaultOff() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.iosBackups))
        let r = ExplainFallback.report(from: f)
        XCTAssertEqual(r.verdict, .recoveryData)
        XCTAssertTrue(r.summary.lowercased().contains("recovery data"))
    }

    func testSizeAppearsInSummaryWhenKnown() {
        let f = SafetyCatalog.facts(for: .duplicateFile, sizeBytes: 5_000_000)
        let r = ExplainFallback.report(from: f)
        XCTAssertTrue(r.summary.contains(ByteFormat.string(5_000_000)))
    }

    func testZeroSizeNotShown() {
        let f = SafetyCatalog.facts(for: .cleanCategory(.logs), sizeBytes: 0)
        let r = ExplainFallback.report(from: f)
        XCTAssertFalse(r.summary.contains("0 bytes"))
    }

    // MARK: Context-aware copy — the summary must match each page's ACTION, not "remove".

    func testSoftwareUpdateSummaryTalksAboutUpdatingNotRemoving() {
        // Regression: the explainer used to wrongly say an update "can be removed".
        for c in [UpdateCategory.app, .library] {
            let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .updateCategory(c)))
            let s = r.summary.lowercased()
            XCTAssertTrue(s.contains("updat"), "\(c) summary should talk about updating: \(r.summary)")
            XCTAssertFalse(s.contains("remov"), "\(c) summary must NOT say remove: \(r.summary)")
            XCTAssertEqual(r.actionKind, .update)
        }
    }

    func testHomebrewLibraryUpdateExplainsCliDependency() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .updateCategory(.library)))
        let s = r.summary.lowercased()
        XCTAssertTrue(s.contains("command-line") || s.contains("library"),
                      "library update should explain it's a CLI dependency: \(r.summary)")
        XCTAssertTrue(s.contains("homebrew") || s.contains("reinstall") || s.contains("earlier version"),
                      "should mention update is reversible: \(r.summary)")
    }

    func testSystemUpdateSummaryMentionsRestartNotRemoval() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .updateCategory(.system)))
        XCTAssertEqual(r.verdict, .caution)
        XCTAssertFalse(r.summary.lowercased().contains("remov"))
        XCTAssertTrue(r.summary.lowercased().contains("restart"))
    }

    func testOptimizeFixSummaryTalksAboutRunningTheFix() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .fixTask(id: "quicklook")))
        XCTAssertTrue(r.summary.lowercased().contains("running this fix"),
                      "fix summary should describe running the fix: \(r.summary)")
        XCTAssertEqual(r.actionKind, .fix)
    }

    func testAdminFixSummaryMentionsAdminPassword() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .fixTask(id: "spotlight")))
        XCTAssertTrue(r.summary.lowercased().contains("admin"),
                      "an admin fix should mention the admin password: \(r.summary)")
    }

    func testAnalyzeFileSummaryTalksAboutTrash() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .duplicateFile, sizeBytes: 1_000))
        XCTAssertTrue(r.summary.lowercased().contains("trash"),
                      "analyze files should be framed as moving to Trash: \(r.summary)")
        XCTAssertEqual(r.actionKind, .trash)
    }

    func testCleanSummaryStillSaysRemove() {
        let r = ExplainFallback.report(from: SafetyCatalog.facts(for: .cleanCategory(.systemCaches)))
        XCTAssertTrue(r.summary.lowercased().contains("remov"),
                      "clean items keep the remove framing: \(r.summary)")
        XCTAssertEqual(r.actionKind, .clean)
    }

    // MARK: Verdict label is phrased for the action.

    func testVerdictLabelMatchesAction() {
        XCTAssertEqual(ExplainVerdict.safe.label(for: .clean), "Safe to remove")
        XCTAssertEqual(ExplainVerdict.safe.label(for: .update), "Safe to update")
        XCTAssertEqual(ExplainVerdict.safe.label(for: .fix), "Safe to run")
        XCTAssertEqual(ExplainVerdict.safe.label(for: .trash), "Safe to move to Trash")
        // Caution / recovery labels stay action-agnostic.
        XCTAssertEqual(ExplainVerdict.caution.label(for: .update), "Review first")
        XCTAssertEqual(ExplainVerdict.recoveryData.label(for: .clean), "Recovery data")
    }

    // MARK: Protocol double matches the fallback.

    func testFallbackExplainerMatchesDeterministicReport() async {
        let f = SafetyCatalog.facts(for: .cleanCategory(.browserData))
        let r = await FallbackExplainer().explain(f)
        XCTAssertEqual(r, ExplainFallback.report(from: f))
        XCTAssertFalse(r.isAIGenerated)
    }
}
