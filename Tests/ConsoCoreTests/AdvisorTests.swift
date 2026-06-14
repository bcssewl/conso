import XCTest
@testable import ConsoCore

final class AdvisorTests: XCTestCase {
    func testAvailableHasNoMessageAndIsAvailable() {
        XCTAssertNil(AdvisorAvailability.available.userMessage)
        XCTAssertTrue(AdvisorAvailability.available.isAvailable)
    }

    func testUnavailableReasonsCarryAUserMessage() {
        XCTAssertFalse(AdvisorAvailability.modelNotReady.isAvailable)
        XCTAssertNotNil(AdvisorAvailability.appleIntelligenceNotEnabled.userMessage)
        XCTAssertNotNil(AdvisorAvailability.deviceNotEligible.userMessage)
        XCTAssertNotNil(AdvisorAvailability.unsupported("x").userMessage)
    }

    func testFallbackAdvisorReturnsDeterministicReport() async {
        var s = SystemSnapshot(); s.diskUsed = 95; s.diskTotal = 100
        let facts = DoctorFacts.from(snapshot: s, topProcesses: [])
        let r = await FallbackDoctorAdvisor().generateReport(from: facts)
        XCTAssertEqual(r, DoctorFallback.report(from: facts))
        XCTAssertFalse(r.isAIGenerated)
    }
}
