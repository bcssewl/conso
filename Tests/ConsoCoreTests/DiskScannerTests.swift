import XCTest
@testable import ConsoCore

final class DiskScannerTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let scanner = DiskScanner()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("conso-scan-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func makeDir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file of `bytes` length and returns its on-disk allocated size, so
    /// assertions compare against what the filesystem actually reserves (block-aligned)
    /// rather than the logical length — keeping the test deterministic on any volume.
    @discardableResult
    private func writeFile(_ url: URL, bytes: Int) throws -> UInt64 {
        try Data(count: bytes).write(to: url)
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func entry(_ result: ScanResult, named name: String) -> DiskEntry? {
        result.entries.first { $0.name == name }
    }

    // MARK: - Tests

    func testPerChildByteSumsAndCounts() throws {
        // alpha/: two files; beta/: one file; gamma.bin: a single top-level file.
        let alpha = try makeDir("alpha")
        let a1 = try writeFile(alpha.appendingPathComponent("a1.dat"), bytes: 8_000)
        let a2 = try writeFile(alpha.appendingPathComponent("a2.dat"), bytes: 4_000)
        let beta = try makeDir("beta")
        let b1 = try writeFile(beta.appendingPathComponent("b1.dat"), bytes: 1_000)
        let gamma = try writeFile(root.appendingPathComponent("gamma.bin"), bytes: 2_000)

        let result = scanner.scan(root)

        XCTAssertEqual(result.entries.count, 3)
        XCTAssertFalse(result.partial)

        let alphaEntry = try XCTUnwrap(entry(result, named: "alpha"))
        XCTAssertEqual(alphaEntry.bytes, a1 + a2)
        XCTAssertEqual(alphaEntry.fileCount, 2)
        // id is the child's filesystem path. Compare resolved paths since /var on
        // macOS is a symlink to /private/var, which the enumerator returns resolved.
        XCTAssertEqual(URL(fileURLWithPath: alphaEntry.id).resolvingSymlinksInPath().path,
                       alpha.resolvingSymlinksInPath().path)

        let betaEntry = try XCTUnwrap(entry(result, named: "beta"))
        XCTAssertEqual(betaEntry.bytes, b1)
        XCTAssertEqual(betaEntry.fileCount, 1)

        let gammaEntry = try XCTUnwrap(entry(result, named: "gamma.bin"))
        XCTAssertEqual(gammaEntry.bytes, gamma)
        XCTAssertEqual(gammaEntry.fileCount, 1, "a single file counts as one")

        XCTAssertEqual(result.totalFiles, 4)
        XCTAssertEqual(result.totalBytes, a1 + a2 + b1 + gamma)
    }

    func testNestedSubtreesAreSummedRecursively() throws {
        let top = try makeDir("top")
        let nestedDeep = top.appendingPathComponent("mid/deep", isDirectory: true)
        try fm.createDirectory(at: nestedDeep, withIntermediateDirectories: true)
        let f1 = try writeFile(top.appendingPathComponent("root.dat"), bytes: 3_000)
        let f2 = try writeFile(top.appendingPathComponent("mid/m.dat"), bytes: 5_000)
        let f3 = try writeFile(nestedDeep.appendingPathComponent("d.dat"), bytes: 7_000)

        let result = scanner.scan(root)
        let topEntry = try XCTUnwrap(entry(result, named: "top"))
        XCTAssertEqual(topEntry.bytes, f1 + f2 + f3)
        XCTAssertEqual(topEntry.fileCount, 3)
    }

    func testEntriesSortedLargestFirst() throws {
        let small = try makeDir("small")
        try writeFile(small.appendingPathComponent("s.dat"), bytes: 1_000)
        let big = try makeDir("big")
        try writeFile(big.appendingPathComponent("b.dat"), bytes: 100_000)
        let medium = try makeDir("medium")
        try writeFile(medium.appendingPathComponent("m.dat"), bytes: 20_000)

        let result = scanner.scan(root)
        XCTAssertEqual(result.entries.map(\.name), ["big", "medium", "small"])
        let bytes = result.entries.map(\.bytes)
        XCTAssertEqual(bytes, bytes.sorted(by: >))
    }

    func testEmptyDirectoryHasZeroBytesAndFiles() throws {
        try makeDir("empty")
        let result = scanner.scan(root)
        let empty = try XCTUnwrap(entry(result, named: "empty"))
        XCTAssertEqual(empty.bytes, 0)
        XCTAssertEqual(empty.fileCount, 0)
        XCTAssertFalse(result.partial, "an empty but readable directory is not partial")
    }

    func testEmptyRootProducesNoEntries() throws {
        let result = scanner.scan(root)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.partial)
    }

    func testUnreadableRootIsPartial() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let result = scanner.scan(missing)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.partial, "a root that cannot be listed is flagged partial")
    }

    func testUnreadableSubtreeIsSkippedNotFatal() throws {
        // A readable sibling plus a directory whose contents we make unreadable.
        let readable = try makeDir("readable")
        let r1 = try writeFile(readable.appendingPathComponent("r.dat"), bytes: 6_000)

        let locked = try makeDir("locked")
        try writeFile(locked.appendingPathComponent("hidden.dat"), bytes: 9_000)
        // Strip all permissions from the directory so enumeration of its contents fails;
        // the scanner's error handler should skip it and keep the readable sibling.
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = scanner.scan(root)
        // The readable sibling must still be reported correctly regardless of the lock.
        let readableEntry = try XCTUnwrap(entry(result, named: "readable"))
        XCTAssertEqual(readableEntry.bytes, r1)
        XCTAssertEqual(readableEntry.fileCount, 1)
        // The locked subtree should be present (listed at top level) but contribute
        // nothing readable, and the whole scan is flagged partial.
        let lockedEntry = try XCTUnwrap(entry(result, named: "locked"))
        XCTAssertEqual(lockedEntry.fileCount, 0)
        XCTAssertTrue(result.partial)
    }

    func testCancellationStopsEarly() throws {
        for i in 0..<5 {
            let d = try makeDir("dir\(i)")
            try writeFile(d.appendingPathComponent("f.dat"), bytes: 1_000)
        }
        // Cancel immediately: the children loop should bail before producing entries.
        let result = scanner.scan(root, isCancelled: { true })
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testScanChildrenConvenienceMatchesScan() throws {
        let d = try makeDir("only")
        try writeFile(d.appendingPathComponent("f.dat"), bytes: 2_500)
        let entries = scanner.scanChildren(of: root)
        XCTAssertEqual(entries, scanner.scan(root).entries)
        XCTAssertEqual(entries.count, 1)
    }

    func testVolumeStatsForTempDirectory() throws {
        let stats = try XCTUnwrap(scanner.volumeStats(for: root))
        XCTAssertGreaterThan(stats.total, 0)
        XCTAssertLessThanOrEqual(stats.free, stats.total)
        XCTAssertEqual(stats.used, stats.total - stats.free)
        XCTAssertFalse(stats.fsName.isEmpty)
    }
}
