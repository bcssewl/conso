import XCTest
@testable import ConsoCore

final class DoctorFallbackTests: XCTestCase {
    private func facts(diskUsed: UInt64, diskTotal: UInt64 = 100) -> DoctorFacts {
        var s = SystemSnapshot(); s.diskUsed = diskUsed; s.diskTotal = diskTotal
        return DoctorFacts.from(snapshot: s, topProcesses: [])
    }

    func testHealthyMachineHasNoFindingsOrSuggestion() {
        let r = DoctorFallback.report(from: facts(diskUsed: 30))
        XCTAssertEqual(r.status, .healthy)
        XCTAssertTrue(r.findings.isEmpty)
        XCTAssertNil(r.suggestion)
        XCTAssertFalse(r.isAIGenerated)
        XCTAssertFalse(r.headline.isEmpty)
    }

    func testFullDiskIsCriticalAndSuggestsClean() {
        let r = DoctorFallback.report(from: facts(diskUsed: 95))
        XCTAssertEqual(r.status, .critical)
        XCTAssertEqual(r.suggestion?.target, .clean)
        XCTAssertTrue(r.findings.contains { $0.severity == .critical })
    }

    func testScoreIsCarriedThrough() {
        let f = facts(diskUsed: 95)
        XCTAssertEqual(DoctorFallback.report(from: f).score, f.score)
    }
}
