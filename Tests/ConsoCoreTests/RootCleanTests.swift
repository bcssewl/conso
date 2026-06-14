import XCTest
@testable import ConsoCore

// MARK: - APFS snapshot name parsing (pure)

/// `SnapshotName` is the trust boundary's first gate: it must extract a timestamp from a
/// real snapshot name and reject EVERYTHING else (malformed names, injection attempts,
/// empty, wrong segment counts) so nothing but a literal `YYYY-MM-DD-HHMMSS` can ever be
/// handed to `tmutil deletelocalsnapshots`.
final class SnapshotNameTests: XCTestCase {

    // MARK: isValidDate

    func testValidDatePasses() {
        XCTAssertTrue(SnapshotName.isValidDate("2026-06-14-101500"))
        XCTAssertTrue(SnapshotName.isValidDate("1999-12-31-235959"))
    }

    func testInvalidDatesRejected() {
        XCTAssertFalse(SnapshotName.isValidDate(""))
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14"))            // missing time
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-10150"))      // 5-digit time
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-1015000"))    // 7-digit time
        XCTAssertFalse(SnapshotName.isValidDate("26-06-14-101500"))       // 2-digit year
        XCTAssertFalse(SnapshotName.isValidDate("2026/06/14/101500"))     // wrong separators
        XCTAssertFalse(SnapshotName.isValidDate(" 2026-06-14-101500"))    // leading space
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-101500 "))    // trailing space
    }

    func testInjectionAttemptsRejected() {
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-101500; rm -rf /"))
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-101500 /"))
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-101500\nrm -rf /"))
        XCTAssertFalse(SnapshotName.isValidDate("$(rm -rf /)"))
        XCTAssertFalse(SnapshotName.isValidDate("2026-06-14-101500`id`"))
    }

    // MARK: date(from:)

    func testExtractsDateFromRealName() {
        XCTAssertEqual(
            SnapshotName.date(from: "com.apple.TimeMachine.2026-06-14-101500.local"),
            "2026-06-14-101500")
    }

    func testRejectsNamesWithoutThePrefixOrSuffix() {
        XCTAssertNil(SnapshotName.date(from: "2026-06-14-101500"))                         // bare timestamp, no prefix
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine.2026-06-14-101500"))   // missing .local
        XCTAssertNil(SnapshotName.date(from: "TimeMachine.2026-06-14-101500.local"))       // wrong prefix
        XCTAssertNil(SnapshotName.date(from: ""))
    }

    func testRejectsMalformedTimestampInsideValidWrapper() {
        // Right prefix/suffix but the middle isn't a clean timestamp → nil.
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine.not-a-date.local"))
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine.2026-06-14.local"))
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine..local"))
    }

    func testRejectsInjectionInsideWrapper() {
        // An attacker controlling the listed name cannot smuggle args past the regex.
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine.2026-06-14-101500; rm -rf /.local"))
        XCTAssertNil(SnapshotName.date(from: "com.apple.TimeMachine.2026-06-14-101500 --all.local"))
    }
}
