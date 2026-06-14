import XCTest
@testable import ConsoCore

final class HealthTests: XCTestCase {
    func testPerfectSystemScoresExcellent() {
        let r = Health.evaluate(diskFraction: 0.40, pressure: .low, thermal: .nominal)
        XCTAssertEqual(r.score, 100)
        XCTAssertEqual(r.grade, "Excellent")
        XCTAssertFalse(r.summary.isEmpty)
    }

    func testProblemsDeductPoints() {
        let r = Health.evaluate(diskFraction: 0.95, pressure: .high, thermal: .serious)
        XCTAssertEqual(r.score, 45)               // 100 - 20 (disk) - 20 (pressure) - 15 (thermal)
        XCTAssertEqual(r.grade, "Needs attention")
    }

    func testGradeThresholds() {
        XCTAssertEqual(Health.evaluate(diskFraction: 0.0, pressure: .low, thermal: .nominal).grade, "Excellent")
        XCTAssertEqual(Health.evaluate(diskFraction: 0.82, pressure: .low, thermal: .nominal).grade, "Good")   // -10 = 90? boundary
        XCTAssertEqual(Health.evaluate(diskFraction: 0.95, pressure: .medium, thermal: .fair).grade, "Fair")   // 100-20-8-5=67
    }

    func testScoreNeverNegative() {
        let r = Health.evaluate(diskFraction: 0.99, pressure: .high, thermal: .critical)
        XCTAssertGreaterThanOrEqual(r.score, 0)
    }

    func testSummaryMentionsWorstProblem() {
        let disky = Health.evaluate(diskFraction: 0.96, pressure: .low, thermal: .nominal)
        XCTAssert(disky.summary.lowercased().contains("disk"), "summary should call out disk: \(disky.summary)")
    }
}
