import XCTest
@testable import ConsoCore

final class DoctorFactsTests: XCTestCase {
    func testDerivesPercentsAndCapsProcesses() {
        var s = SystemSnapshot()
        s.cpuUsage = 0.5
        s.memoryUsed = 8_000_000_000; s.memoryTotal = 16_000_000_000
        s.diskUsed = 90; s.diskTotal = 100
        s.cpuCoreCount = 10
        let facts = DoctorFacts.from(snapshot: s, topProcesses: ["A", "B", "C", "D"])
        XCTAssertEqual(facts.cpuPercent, 50)
        XCTAssertEqual(facts.memoryPercent, 50)
        XCTAssertEqual(facts.diskPercent, 90)
        XCTAssertEqual(facts.topProcesses, ["A", "B", "C"])   // capped to 3 for the token budget
    }

    func testCarriesHealthScoreFromExistingHealthEvaluator() {
        var s = SystemSnapshot()
        s.diskUsed = 40; s.diskTotal = 100                    // healthy machine
        let facts = DoctorFacts.from(snapshot: s, topProcesses: [])
        XCTAssertEqual(facts.score, 100)
        XCTAssertEqual(facts.grade, "Excellent")
        XCTAssertEqual(facts.checksTotal, 5)
    }
}
