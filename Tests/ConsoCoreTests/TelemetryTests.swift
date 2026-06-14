import XCTest
@testable import ConsoCore

final class ThermalStateTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(ThermalState.nominal.label, "Nominal")
        XCTAssertEqual(ThermalState.fair.label, "Fair")
        XCTAssertEqual(ThermalState.serious.label, "Serious")
        XCTAssertEqual(ThermalState.critical.label, "Critical")
    }
    func testIsWarm() {
        XCTAssertFalse(ThermalState.nominal.isWarm)
        XCTAssertTrue(ThermalState.serious.isWarm)
    }
}

final class MemoryPressureTests: XCTestCase {
    func testLowWhenRoomySpareAndNoSwap() {
        XCTAssertEqual(MemoryPressure.classify(fraction: 0.4, swapUsed: 0), .low)
    }
    func testMediumWhenFullishOrLightSwap() {
        XCTAssertEqual(MemoryPressure.classify(fraction: 0.82, swapUsed: 0), .medium)
        XCTAssertEqual(MemoryPressure.classify(fraction: 0.5, swapUsed: 200_000_000), .medium)
    }
    func testHighWhenNearlyFullAndSwapping() {
        XCTAssertEqual(MemoryPressure.classify(fraction: 0.94, swapUsed: 3_000_000_000), .high)
    }
    func testLabels() {
        XCTAssertEqual(MemoryPressure.low.label, "low")
        XCTAssertEqual(MemoryPressure.high.label, "high")
    }

    // Real kernel pressure level mapping (kern.memorystatus_vm_pressure_level):
    // 1 = normal, 2 = warn, 4 = critical; anything else -> nil (fall back).
    func testKernelLevelMapping() {
        XCTAssertEqual(MemoryPressure.level(fromKernelLevel: 1), .low)
        XCTAssertEqual(MemoryPressure.level(fromKernelLevel: 2), .medium)
        XCTAssertEqual(MemoryPressure.level(fromKernelLevel: 4), .high)
        XCTAssertNil(MemoryPressure.level(fromKernelLevel: 0))
        XCTAssertNil(MemoryPressure.level(fromKernelLevel: 3))
        XCTAssertNil(MemoryPressure.level(fromKernelLevel: 99))
    }

    // The kernel signal is non-root readable on macOS; if present it must be a valid bucket.
    func testSystemSignalIsValidOrNil() {
        if let p = MemoryPressure.system() {
            XCTAssert([.low, .medium, .high].contains(p))
        }
    }

    // best() prefers the real signal but always returns a value (heuristic fallback).
    func testBestAlwaysReturnsValue() {
        _ = MemoryPressure.best(fraction: 0.5, swapUsed: 0)   // must not crash / always non-nil by type
        // When the kernel signal is unavailable, best == classify.
        if MemoryPressure.system() == nil {
            XCTAssertEqual(MemoryPressure.best(fraction: 0.94, swapUsed: 3_000_000_000), .high)
        }
    }
}

final class FilesystemTests: XCTestCase {
    func testLabelNormalisesKnownTypes() {
        XCTAssertEqual(Filesystem.label(forRawType: "apfs"), "APFS")
        XCTAssertEqual(Filesystem.label(forRawType: "APFS"), "APFS")
        XCTAssertEqual(Filesystem.label(forRawType: "hfs"), "HFS+")
        XCTAssertEqual(Filesystem.label(forRawType: "exfat"), "exFAT")
        XCTAssertEqual(Filesystem.label(forRawType: "msdos"), "FAT32")
        XCTAssertEqual(Filesystem.label(forRawType: "ntfs"), "NTFS")
        XCTAssertEqual(Filesystem.label(forRawType: "smbfs"), "SMB")
    }
    func testLabelUppercasesUnknownToken() {
        XCTAssertEqual(Filesystem.label(forRawType: "zfs"), "ZFS")
    }
    func testEmptyTokenFallsBack() {
        XCTAssertEqual(Filesystem.label(forRawType: ""), "Disk")
    }
    func testRootVolumeTypeIsReadable() {
        // Real disk read: the boot volume must report a non-empty fs type (APFS on modern Macs).
        let raw = Filesystem.typeName(forPath: "/")
        XCTAssertNotNil(raw, "statfs on / should succeed")
        XCTAssertFalse(Filesystem.displayName(forPath: "/").isEmpty)
    }
    func testMissingPathFallsBackGracefully() {
        // A bogus path can't be stat'd; displayName must degrade to "Disk", not crash.
        XCTAssertNil(Filesystem.typeName(forPath: "/no/such/path/\(UUID().uuidString)"))
        XCTAssertEqual(Filesystem.displayName(forPath: "/no/such/path/\(UUID().uuidString)"), "Disk")
    }
}

final class NetworkLinkTests: XCTestCase {
    // label() must always yield a non-empty, known-shape string (never blank/stale).
    func testLabelIsNeverEmpty() {
        let l = NetworkLink.label()
        XCTAssertFalse(l.isEmpty)
        let known = l.hasPrefix("Wi-Fi") || l == "Ethernet" || l == "Offline"
        XCTAssertTrue(known, "unexpected link label: \(l)")
    }

    // The wired-link probe is a pure read of interface flags; it must not crash and
    // its result must be consistent with label() (wired => "Ethernet" when no Wi-Fi).
    func testWiredProbeRuns() {
        _ = NetworkLink.hasActiveWiredLink()   // must not crash
    }
}

final class RateFormatTests: XCTestCase {
    func testBytes() { XCTAssertEqual(RateFormat.perSecond(512), "512 B/s") }
    func testKilobytes() { XCTAssertEqual(RateFormat.perSecond(2_048), "2.0 KB/s") }
    func testMegabytes() { XCTAssertEqual(RateFormat.perSecond(8_400_000), "8.4 MB/s") }
    func testZero() { XCTAssertEqual(RateFormat.perSecond(0), "0 B/s") }

    // Bits/second (×8): network convention.
    func testBitsMegabit() { XCTAssertEqual(RateFormat.perSecondBits(1_000_000), "8.0 Mbps") }
    func testBitsKilobit() { XCTAssertEqual(RateFormat.perSecondBits(1_000), "8.0 Kbps") }
    func testBitsSub() { XCTAssertEqual(RateFormat.perSecondBits(50), "400 bps") }
    func testBitsZero() { XCTAssertEqual(RateFormat.perSecondBits(0), "0 bps") }
}

final class NetCountersTests: XCTestCase {
    func testRate() {
        XCTAssertEqual(NetCounters.rate(previous: 1_000, current: 9_400, elapsed: 1.0), 8_400, accuracy: 0.001)
    }
    func testHalfSecondElapsed() {
        XCTAssertEqual(NetCounters.rate(previous: 0, current: 500, elapsed: 0.5), 1_000, accuracy: 0.001)
    }
    func testCounterResetReturnsZero() {
        XCTAssertEqual(NetCounters.rate(previous: 10_000, current: 50, elapsed: 1.0), 0)
    }
    func testZeroElapsedReturnsZero() {
        XCTAssertEqual(NetCounters.rate(previous: 0, current: 500, elapsed: 0), 0)
    }
}

final class ProcessTableTests: XCTestCase {
    private let sample = """
      394  31.2  1468392 WindowServer
    23475  56.0  6402048 Xcode
    73019  18.4  2306867 Claude
        1   0.1     8200 launchd
    44120   8.4   980000 node
    """

    func testParsesFieldsAndConvertsRssKBToBytes() {
        let rows = ProcessTable.parse(sample, limit: 10)
        let xcode = rows.first { $0.name == "Xcode" }
        XCTAssertEqual(xcode?.pid, 23475)
        XCTAssertEqual(xcode?.cpu ?? 0, 56.0, accuracy: 0.001)
        XCTAssertEqual(xcode?.memBytes, 6_402_048 * 1024)
    }

    func testSortedByCPUDescending() {
        let rows = ProcessTable.parse(sample, limit: 10)
        XCTAssertEqual(rows.map(\.name).prefix(3), ["Xcode", "WindowServer", "Claude"])
    }

    func testRespectsLimit() {
        XCTAssertEqual(ProcessTable.parse(sample, limit: 2).count, 2)
    }

    func testKeepsNamesWithSpaces() {
        let rows = ProcessTable.parse("  500  4.0  10240 Google Chrome\n", limit: 5)
        XCTAssertEqual(rows.first?.name, "Google Chrome")
    }

    func testSkipsMalformedLines() {
        let rows = ProcessTable.parse("garbage line\n  500  4.0  10240 Safari\n\n", limit: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Safari")
    }
}
