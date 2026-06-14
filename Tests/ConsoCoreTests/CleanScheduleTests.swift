import XCTest
@testable import ConsoCore

final class CleanScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - isDue

    func testNilLastRunIsAlwaysDue() {
        for interval in CleanScheduleInterval.allCases {
            XCTAssertTrue(CleanSchedule.isDue(now: now, lastRun: nil, interval: interval),
                          "a never-run schedule should be due immediately (\(interval))")
        }
    }

    func testNotDueBeforeIntervalElapses() {
        // 23h after the last daily run → not yet due.
        let lastRun = now.addingTimeInterval(-23 * 60 * 60)
        XCTAssertFalse(CleanSchedule.isDue(now: now, lastRun: lastRun, interval: .daily))
    }

    func testDueExactlyAtInterval() {
        let lastRun = now.addingTimeInterval(-CleanScheduleInterval.daily.interval)
        XCTAssertTrue(CleanSchedule.isDue(now: now, lastRun: lastRun, interval: .daily))
    }

    func testDueAfterInterval() {
        let lastRun = now.addingTimeInterval(-(CleanScheduleInterval.weekly.interval + 60))
        XCTAssertTrue(CleanSchedule.isDue(now: now, lastRun: lastRun, interval: .weekly))
    }

    func testJustRunIsNotDue() {
        XCTAssertFalse(CleanSchedule.isDue(now: now, lastRun: now, interval: .monthly))
    }

    func testEachIntervalBoundary() {
        for interval in CleanScheduleInterval.allCases {
            let justBefore = now.addingTimeInterval(-(interval.interval - 1))
            let exactly = now.addingTimeInterval(-interval.interval)
            XCTAssertFalse(CleanSchedule.isDue(now: now, lastRun: justBefore, interval: interval),
                           "not due 1s before the window (\(interval))")
            XCTAssertTrue(CleanSchedule.isDue(now: now, lastRun: exactly, interval: interval),
                          "due exactly at the window (\(interval))")
        }
    }

    // MARK: - interval magnitudes

    func testIntervalsAreOrdered() {
        XCTAssertLessThan(CleanScheduleInterval.daily.interval, CleanScheduleInterval.weekly.interval)
        XCTAssertLessThan(CleanScheduleInterval.weekly.interval, CleanScheduleInterval.monthly.interval)
        XCTAssertEqual(CleanScheduleInterval.daily.interval, 86_400)
    }

    func testDisplayNames() {
        XCTAssertEqual(CleanScheduleInterval.daily.displayName, "Daily")
        XCTAssertEqual(CleanScheduleInterval.weekly.displayName, "Weekly")
        XCTAssertEqual(CleanScheduleInterval.monthly.displayName, "Monthly")
    }

    // MARK: - scope mirrors manual Quick Clean

    func testScheduleScopeMatchesManualQuickClean() {
        XCTAssertEqual(CleanSchedule.quickCleanCategories, CleanCatalog.quickCleanCategories)
        // Safety invariant: never app leftovers, never any hidden / recovery-data category.
        XCTAssertFalse(CleanSchedule.quickCleanCategories.contains(.appLeftovers))
        XCTAssertFalse(CleanSchedule.quickCleanCategories.contains(.apfsSnapshots))
        XCTAssertFalse(CleanSchedule.quickCleanCategories.contains(.iosBackups))
        XCTAssertFalse(CleanSchedule.quickCleanCategories.contains(.mailAttachments))
    }

    // MARK: - target selection mirrors CleanModel.targets(in:)

    func testQuickCleanTargetsDrawFromScannedCategoriesOnly() {
        let scans: [String: CategoryScan] = [
            CleanCategory.systemCaches.rawValue: CategoryScan(
                category: .systemCaches, bytes: 100,
                targets: [CleanTarget(path: "/tmp/caches", bytes: 100, category: .systemCaches)]),
            CleanCategory.logs.rawValue: CategoryScan(
                category: .logs, bytes: 50,
                targets: [CleanTarget(path: "/tmp/logs", bytes: 50, category: .logs)]),
            // A non-quick category must be ignored by the scheduled selection.
            CleanCategory.appLeftovers.rawValue: CategoryScan(
                category: .appLeftovers, bytes: 999,
                targets: [CleanTarget(path: "/tmp/leftover", bytes: 999, category: .appLeftovers)]),
        ]
        let ids = Set(CleanSchedule.quickCleanTargetIDs(scans: scans))
        XCTAssertEqual(ids, ["/tmp/caches", "/tmp/logs"])
        XCTAssertFalse(ids.contains("/tmp/leftover"))
    }

    func testQuickCleanTargetsEmptyWhenNoScans() {
        XCTAssertTrue(CleanSchedule.quickCleanTargets(scans: [:]).isEmpty)
        XCTAssertTrue(CleanSchedule.quickCleanTargetIDs(scans: [:]).isEmpty)
    }
}
