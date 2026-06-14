import XCTest
@testable import ConsoCore

final class DoctorReportTests: XCTestCase {
    func testFindingIDIsItsTitleForStableLists() {
        let f = Finding(title: "Disk almost full", detail: "x", severity: .critical)
        XCTAssertEqual(f.id, "Disk almost full")   // stable id → no SwiftUI ForEach flicker
    }

    func testReportIsEquatableValue() {
        let a = DoctorReport(headline: "ok", status: .healthy, score: 100,
                             findings: [], suggestion: nil, isAIGenerated: false)
        let b = DoctorReport(headline: "ok", status: .healthy, score: 100,
                             findings: [], suggestion: nil, isAIGenerated: false)
        XCTAssertEqual(a, b)
    }
}
