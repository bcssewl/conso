import XCTest
@testable import ConsoCore

// MARK: - Pure duplicate grouping (no I/O)

final class DuplicateGroupingTests: XCTestCase {
    private func rec(_ path: String, _ size: UInt64) -> FileRecord {
        FileRecord(path: path, size: size, modified: Date(), accessed: Date())
    }

    func testSizeBucketsKeepsOnlyCollisionsAndDropsZeroBytes() {
        let recs = [
            rec("/a", 100), rec("/b", 100),   // collide → kept
            rec("/c", 200),                    // unique → dropped
            rec("/d", 0), rec("/e", 0),        // zero-byte → dropped
        ]
        let buckets = DuplicateFinder.sizeBuckets(recs)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[100]?.count, 2)
        XCTAssertNil(buckets[200])
        XCTAssertNil(buckets[0])
    }

    func testGroupsFromHashesExcludesSingletons() {
        let hashed: [(record: FileRecord, hash: String)] = [
            (rec("/a", 10), "h1"),
            (rec("/b", 10), "h1"),   // dup of /a
            (rec("/c", 20), "h2"),   // singleton hash → excluded
            (rec("/d", 30), "h3"),
            (rec("/e", 30), "h3"),
            (rec("/f", 30), "h3"),   // 3-way dup
        ]
        let groups = DuplicateFinder.groups(from: hashed)
        XCTAssertEqual(groups.count, 2, "only h1 and h3 have ≥2 members")
        XCTAssertFalse(groups.contains { $0.hash == "h2" })
        let h3 = groups.first { $0.hash == "h3" }
        XCTAssertEqual(h3?.files.count, 3)
        XCTAssertEqual(h3?.redundantCount, 2)
    }

    func testReclaimableIsTotalMinusOneKeptCopy() {
        // h1: 2 files × 10 bytes → keep one, reclaim 10.
        // h3: 3 files × 30 bytes → keep one, reclaim 60.
        let hashed: [(record: FileRecord, hash: String)] = [
            (rec("/a", 10), "h1"), (rec("/b", 10), "h1"),
            (rec("/d", 30), "h3"), (rec("/e", 30), "h3"), (rec("/f", 30), "h3"),
        ]
        let groups = DuplicateFinder.groups(from: hashed)
        XCTAssertEqual(DuplicateFinder.reclaimableBytes(groups), 70)
        // Most-reclaimable-first ordering.
        XCTAssertEqual(groups.first?.hash, "h3")
    }

    func testSamePathNotCountedAsItsOwnDuplicate() {
        let hashed: [(record: FileRecord, hash: String)] = [
            (rec("/a", 10), "h1"),
            (rec("/a", 10), "h1"),  // same path enumerated twice
        ]
        let groups = DuplicateFinder.groups(from: hashed)
        XCTAssertTrue(groups.isEmpty, "one real file is not a duplicate of itself")
    }
}

// MARK: - Streamed content hashing (real temp files)

final class ContentHashTests: XCTestCase {
    private var dir: URL!
    private let finder = DuplicateFinder()

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conso-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testIdenticalContentSameHash() throws {
        let payload = Data((0..<5000).map { UInt8($0 % 256) })
        let a = try write("a.bin", payload)
        let b = try write("b.bin", payload)
        XCTAssertEqual(finder.hash(fileAt: a), finder.hash(fileAt: b))
        XCTAssertNotNil(finder.hash(fileAt: a))
    }

    func testOneByteDifferenceDifferentHash() throws {
        var p1 = Data((0..<5000).map { UInt8($0 % 256) })
        var p2 = p1
        p2[2500] = p2[2500] &+ 1   // flip a single byte deep in the file
        let a = try write("a.bin", p1); p1.removeAll()
        let b = try write("b.bin", p2)
        XCTAssertNotEqual(finder.hash(fileAt: a), finder.hash(fileAt: b))
    }

    func testStreamingHandlesFileLargerThanChunk() throws {
        // Two copies larger than the 1 MiB chunk size must still hash identically.
        let big = Data(repeating: 0xAB, count: DuplicateFinder.chunkSize * 2 + 123)
        let a = try write("big-a.bin", big)
        let b = try write("big-b.bin", big)
        XCTAssertEqual(finder.hash(fileAt: a), finder.hash(fileAt: b))
    }

    func testFindDuplicatesEndToEndGroupsByContentNotSize() throws {
        // /a and /b share content; /c is same SIZE but different content → not grouped.
        let payload = Data((0..<2048).map { UInt8($0 % 256) })
        var other = payload; other[0] = other[0] &+ 1
        _ = try write("a.bin", payload)
        _ = try write("b.bin", payload)
        _ = try write("c.bin", other)
        let scanner = FileScanner(safety: CleanSafety(home: dir))
        // Walk our temp dir directly (it's not under the real home, but the scanner walks
        // any root; protected/system pruning still applies and won't match here).
        let result = scanner.scan(dir)
        let groups = finder.findDuplicates(in: result.files)
        XCTAssertEqual(groups.count, 1, "only a.bin/b.bin are byte-identical")
        XCTAssertEqual(groups.first?.files.count, 2)
        let paths = Set(groups.first!.files.map(\.name))
        XCTAssertEqual(paths, ["a.bin", "b.bin"])
    }

    func testUnreadableFileHashIsNil() {
        XCTAssertNil(finder.hash(fileAt: dir.appendingPathComponent("does-not-exist")))
    }
}

// MARK: - Old-file pure filter

final class OldFileFinderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func daysAgo(_ d: Int) -> Date { now.addingTimeInterval(-Double(d) * 86_400) }
    private func rec(_ path: String, size: UInt64, modDays: Int, accessDays: Int) -> FileRecord {
        FileRecord(path: path, size: size, modified: daysAgo(modDays), accessed: daysAgo(accessDays))
    }

    func testIsOldRequiresBothDatesBeyondThreshold() {
        // Modified long ago but accessed recently → NOT old (still in use).
        XCTAssertFalse(OldFileFinder.isOld(modified: daysAgo(400), accessed: daysAgo(5), now: now, thresholdDays: 365))
        // Both beyond threshold → old.
        XCTAssertTrue(OldFileFinder.isOld(modified: daysAgo(400), accessed: daysAgo(400), now: now, thresholdDays: 365))
        // Both inside threshold → not old.
        XCTAssertFalse(OldFileFinder.isOld(modified: daysAgo(10), accessed: daysAgo(10), now: now, thresholdDays: 365))
    }

    func testOldFilesSortedLargestFirstAndCapped() {
        let recs = [
            rec("/a", size: 100, modDays: 500, accessDays: 500),
            rec("/b", size: 300, modDays: 500, accessDays: 500),
            rec("/c", size: 200, modDays: 500, accessDays: 500),
            rec("/fresh", size: 999, modDays: 1, accessDays: 1),   // not old
        ]
        let old = OldFileFinder(thresholdDays: 365, limit: 2).oldFiles(from: recs, now: now)
        XCTAssertEqual(old.map(\.size), [300, 200], "largest-first, capped to 2, fresh excluded")
    }
}

// MARK: - Trasher safety (reversible + protected-path guard)

final class FileTrasherTests: XCTestCase {
    private var home: URL!
    private var trasher: FileTrasher!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conso-ftrash-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        trasher = FileTrasher(safety: CleanSafety(home: home))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }
    @discardableResult
    private func write(_ rel: String, bytes: Int = 100) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    func testTrashesSelectedFileReversibly() throws {
        // A user file under Downloads (not a protected DENY root for trashing? It IS denied —
        // use a neutral location the guard allows: a plain folder under home).
        let f = try write("Projects/old/report.bin", bytes: 1234)
        let rec = FileRecord(path: f.path, size: 1234, modified: Date(), accessed: Date())
        let result = trasher.trash([rec])
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.bytesFreed, 1234)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "moved to Trash (reversible)")
        XCTAssertEqual(result.items.first?.outcome, .trashed)
    }

    func testRefusesProtectedPath() throws {
        // Keychains is a denied root — must be skipped, never trashed.
        let f = try write("Library/Keychains/login.keychain-db", bytes: 500)
        let rec = FileRecord(path: f.path, size: 500, modified: Date(), accessed: Date())
        let result = trasher.trash([rec])
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "protected file untouched")
        guard case .skipped(let reason) = result.items.first?.outcome else {
            return XCTFail("protected path must be skipped")
        }
        XCTAssertTrue(reason.contains("protected"))
    }

    func testSkipsMissingFile() {
        let rec = FileRecord(path: home.appendingPathComponent("gone.bin").path,
                             size: 0, modified: Date(), accessed: Date())
        let result = trasher.trash([rec])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
    }

    func testIsTrashableRejectsHomeRootAndOutsideHome() {
        XCTAssertFalse(trasher.isTrashable(home))
        XCTAssertFalse(trasher.isTrashable(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertTrue(trasher.isTrashable(home.appendingPathComponent("Projects/x.bin")))
    }
}

// MARK: - Scanner pruning

final class FileScannerPruneTests: XCTestCase {
    private let scanner = FileScanner(safety: CleanSafety(home: URL(fileURLWithPath: "/Users/example")))

    func testPrunesCachesVCSAndProtectedDirs() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertTrue(scanner.shouldPrune(home.appendingPathComponent("proj/node_modules")))
        XCTAssertTrue(scanner.shouldPrune(home.appendingPathComponent("proj/.git")))
        XCTAssertTrue(scanner.shouldPrune(home.appendingPathComponent("Library/Caches")))
        XCTAssertTrue(scanner.shouldPrune(home.appendingPathComponent("Library/Keychains")))
        XCTAssertTrue(scanner.shouldPrune(URL(fileURLWithPath: "/System/Library")))
        XCTAssertTrue(scanner.shouldPrune(home.appendingPathComponent("Apps/Foo.app")))
    }

    func testDoesNotPruneUserDocuments() {
        let home = URL(fileURLWithPath: "/Users/example")
        // Documents is listable (the user may want to find dupes there) — not pruned by name.
        XCTAssertFalse(scanner.shouldPrune(home.appendingPathComponent("Projects")))
        XCTAssertFalse(scanner.shouldPrune(home.appendingPathComponent("dev/myapp")))
    }
}
