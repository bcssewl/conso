import XCTest
@testable import ConsoCore

final class RingBufferTests: XCTestCase {
    func testAppendWithinCapacity() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.values, [1, 2])
        XCTAssertEqual(buffer.count, 2)
        XCTAssertFalse(buffer.isFull)
    }

    func testDropsOldestWhenOverCapacity() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for n in [1, 2, 3, 4, 5] { buffer.append(n) }
        XCTAssertEqual(buffer.values, [3, 4, 5])
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.last, 5)
    }

    func testEmptyState() {
        let buffer = RingBuffer<Double>(capacity: 4)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.values, [])
        XCTAssertNil(buffer.last)
    }

    func testCapacityFloorIsOne() {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(7)
        buffer.append(8)
        XCTAssertEqual(buffer.values, [8])
    }
}

final class FormatTests: XCTestCase {
    func testUptimeFormatting() {
        XCTAssertEqual(UptimeFormat.string(8 * 60), "8m")
        XCTAssertEqual(UptimeFormat.string(5 * 3600 + 12 * 60), "5h 12m")
        XCTAssertEqual(UptimeFormat.string(3 * 86400 + 4 * 3600), "3d 4h")
    }

    func testSnapshotFractions() {
        let s = SystemSnapshot(memoryUsed: 32, memoryTotal: 64, diskUsed: 250, diskTotal: 1000)
        XCTAssertEqual(s.memoryFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.diskFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(SystemSnapshot().memoryFraction, 0)
    }

    func testByteFormatDoesNotTrapOnHugeValue() {
        // A garbage/huge UInt64 above Int64.max must clamp instead of trapping.
        let s = ByteFormat.string(UInt64.max)
        XCTAssertFalse(s.isEmpty)
    }

    func testRelativeAgeNilIsNever() {
        XCTAssertNil(RelativeAgeFormat.valueUnit(nil, now: Date()))
    }

    func testRelativeAgeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // < 1 min → "now".
        XCTAssertEqual(RelativeAgeFormat.valueUnit(now.addingTimeInterval(-30), now: now)?.value, "now")
        // Minutes.
        let m = RelativeAgeFormat.valueUnit(now.addingTimeInterval(-5 * 60), now: now)
        XCTAssertEqual(m?.value, "5"); XCTAssertEqual(m?.unit, "m")
        // Hours.
        let h = RelativeAgeFormat.valueUnit(now.addingTimeInterval(-3 * 3_600), now: now)
        XCTAssertEqual(h?.value, "3"); XCTAssertEqual(h?.unit, "h")
        // Days.
        let d = RelativeAgeFormat.valueUnit(now.addingTimeInterval(-2 * 86_400), now: now)
        XCTAssertEqual(d?.value, "2"); XCTAssertEqual(d?.unit, "d")
    }

    func testRelativeAgeFutureClampsToNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeAgeFormat.valueUnit(now.addingTimeInterval(120), now: now)?.value, "now")
    }
}

final class MetricsTests: XCTestCase {
    func testSnapshotValuesArePlausible() {
        let provider = LiveMetricsProvider()
        _ = provider.snapshot() // prime CPU baseline
        let s = provider.snapshot()
        XCTAssert(s.cpuUsage >= 0 && s.cpuUsage <= 1, "cpu out of range: \(s.cpuUsage)")
        XCTAssert(s.memoryTotal > 0, "no memory total")
        XCTAssert(s.memoryUsed <= s.memoryTotal, "used > total")
        XCTAssert(s.diskTotal > 0, "no disk total")
        XCTAssert(s.diskUsed <= s.diskTotal, "disk used > total")
        XCTAssert(s.uptime > 0, "no uptime")
    }

    func testHostInfo() {
        let host = HostInfo.current()
        XCTAssertFalse(host.chip.isEmpty, "empty chip string")
        XCTAssertFalse(host.model.isEmpty, "empty model string")
        XCTAssert(host.physicalMemory > 0)
    }
}
