import XCTest
@testable import ConsoCore

final class BatteryTests: XCTestCase {
    func testTimeLabelDischarging() {
        let b = BatteryInfo(percent: 86, isCharging: false, onACPower: false,
                            minutesRemaining: 964, cycleCount: 142, healthPercent: 98)
        XCTAssertEqual(b.timeLabel, "16:04 left")
    }
    func testTimeLabelCharging() {
        let b = BatteryInfo(percent: 50, isCharging: true, onACPower: true,
                            minutesRemaining: 150, cycleCount: nil, healthPercent: nil)
        XCTAssertEqual(b.timeLabel, "2:30 to full")
    }
    func testTimeLabelCalculating() {
        let b = BatteryInfo(percent: 50, isCharging: false, onACPower: false,
                            minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
        XCTAssertEqual(b.timeLabel, "Calculating…")
    }
    func testTimeLabelPluggedInFull() {
        // On AC at ~100% with no estimate: macOS gives no time, so don't say "Calculating…".
        let b = BatteryInfo(percent: 100, isCharging: false, onACPower: true,
                            minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
        XCTAssertEqual(b.timeLabel, "Fully charged")
    }
    func testTimeLabelPluggedInNotFull() {
        // On AC but not yet full and no estimate: say "Plugged in", not "Calculating…".
        let b = BatteryInfo(percent: 80, isCharging: false, onACPower: true,
                            minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
        XCTAssertEqual(b.timeLabel, "Plugged in")
    }

    func testCurrentIsPlausibleOrNil() {
        // nil on a desktop Mac; otherwise a sane percentage.
        if let b = BatteryProvider.current() {
            XCTAssert((0...100).contains(b.percent), "battery percent out of range: \(b.percent)")
            if let h = b.healthPercent { XCTAssert((0...100).contains(h)) }
        }
    }
}

final class ProcessProviderTests: XCTestCase {
    func testTopReturnsRealProcesses() {
        let rows = ProcessProvider().top(8)
        XCTAssertFalse(rows.isEmpty, "ps returned no processes")
        XCTAssertLessThanOrEqual(rows.count, 8)
        XCTAssert(rows.allSatisfy { $0.pid > 0 })
        XCTAssert(rows.allSatisfy { !$0.name.isEmpty })
    }
}

final class ExtendedMetricsTests: XCTestCase {
    func testSnapshotHasCoresAndNonNegativeRates() {
        let provider = LiveMetricsProvider()
        _ = provider.snapshot()              // prime CPU + network baselines
        let s = provider.snapshot()
        XCTAssert(s.cpuCoreCount > 0, "no core count")
        XCTAssert(s.loadAverage >= 0)
        XCTAssert(s.netDown >= 0 && s.netUp >= 0)
    }
}
