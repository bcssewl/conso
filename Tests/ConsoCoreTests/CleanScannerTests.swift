import XCTest
@testable import ConsoCore

// MARK: - Git-dirty decision (pure)

final class GitStatusTests: XCTestCase {
    func testCleanRepoIsNotDirty() {
        XCTAssertFalse(GitStatus.isDirty(porcelain: ""))
        XCTAssertFalse(GitStatus.isDirty(porcelain: "\n  \n"))
    }

    func testModifiedFileIsDirty() {
        XCTAssertTrue(GitStatus.isDirty(porcelain: " M src/main.swift\n"))
    }

    func testUntrackedFileIsDirty() {
        XCTAssertTrue(GitStatus.isDirty(porcelain: "?? newfile.txt\n"))
    }

    func testStagedAndConflictedAreDirty() {
        XCTAssertTrue(GitStatus.isDirty(porcelain: "A  added.swift\n"))
        XCTAssertTrue(GitStatus.isDirty(porcelain: "UU conflict.swift\n"))
    }
}

// MARK: - Bundle-id heuristic (pure)

final class CleanScannerHeuristicTests: XCTestCase {
    private let scanner = CleanScanner(safety: CleanSafety(home: URL(fileURLWithPath: "/tmp/none")))

    func testReverseDNSNamesLookLikeBundleIDs() {
        XCTAssertTrue(scanner.looksLikeBundleID("com.acme.app"))
        XCTAssertTrue(scanner.looksLikeBundleID("org.mozilla.firefox"))
    }

    func testPlainFoldersDoNot() {
        XCTAssertFalse(scanner.looksLikeBundleID("Google"))
        XCTAssertFalse(scanner.looksLikeBundleID("My App Support"))
        XCTAssertFalse(scanner.looksLikeBundleID("noseparators"))
        XCTAssertFalse(scanner.looksLikeBundleID(".hidden"))
    }
}

// MARK: - Scanner against a sandboxed temp "home"

final class CleanScannerScanTests: XCTestCase {
    private var home: URL!
    private var scanner: CleanScanner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conso-scan-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        scanner = CleanScanner(safety: CleanSafety(home: home))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ rel: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    func testSystemCachesSumsChildrenAndYieldsTargets() throws {
        try writeFile("Library/Caches/com.acme.app/blob.bin", bytes: 100_000)
        try writeFile("Library/Caches/com.other.tool/data.bin", bytes: 50_000)
        let scan = scanner.scan(.systemCaches)
        XCTAssertGreaterThan(scan.bytes, 0)
        XCTAssertEqual(scan.targets.count, 2)
        // Every emitted target must itself be safe-to-delete.
        for t in scan.targets {
            XCTAssertTrue(scanner.safety.isSafeToDelete(t.url, category: .systemCaches))
        }
    }

    func testLogsScannedAsRoot() throws {
        try writeFile("Library/Logs/app.log", bytes: 10_000)
        let scan = scanner.scan(.logs)
        XCTAssertGreaterThan(scan.bytes, 0)
        XCTAssertTrue(scan.targets.contains { $0.path.hasSuffix("/Library/Logs") })
    }

    func testTrashScanned() throws {
        try writeFile(".Trash/old/file.bin", bytes: 20_000)
        let scan = scanner.scan(.trash)
        XCTAssertGreaterThan(scan.bytes, 0)
        XCTAssertFalse(scan.targets.isEmpty)
    }

    func testBrowserOnlyCacheLeavesNotProfileData() throws {
        let base = "Library/Application Support/Google/Chrome/Default"
        try writeFile("\(base)/Cache/c.bin", bytes: 80_000)
        try writeFile("\(base)/Code Cache/js/x.bin", bytes: 40_000)
        try writeFile("\(base)/History", bytes: 30_000)       // must NOT be picked up
        try writeFile("\(base)/Cookies", bytes: 30_000)       // must NOT be picked up
        let scan = scanner.scan(.browserData)
        XCTAssertEqual(scan.targets.count, 2, "only Cache + Code Cache leaves")
        XCTAssertTrue(scan.targets.allSatisfy { $0.path.contains("Cache") })
        XCTAssertFalse(scan.targets.contains { $0.path.hasSuffix("/History") || $0.path.hasSuffix("/Cookies") })
    }

    func testAppLeftoversOnlyOrphanBundleIDs() throws {
        // A made-up bundle id that is definitely not installed.
        let orphan = "com.conso.definitely-not-installed-\(UUID().uuidString.prefix(6))"
        try writeFile("Library/Application Support/\(orphan)/state.bin", bytes: 70_000)
        // A plain folder that must be ignored (not reverse-DNS).
        try writeFile("Library/Application Support/Google/keep.bin", bytes: 70_000)
        let scan = scanner.scan(.appLeftovers)
        XCTAssertTrue(scan.targets.contains { $0.path.contains(orphan) })
        XCTAssertFalse(scan.targets.contains { $0.path.hasSuffix("/Google") })
    }

    func testNodeModulesFoundUnderDeveloper() throws {
        try writeFile("Developer/proj/node_modules/pkg/index.js", bytes: 120_000)
        let targets = scanner.findNodeModules(under: home.appendingPathComponent("Developer"),
                                              isCancelled: { false })
        XCTAssertEqual(targets.count, 1)
        XCTAssertTrue(targets[0].path.hasSuffix("/node_modules"))
        XCTAssertGreaterThan(targets[0].bytes, 0)
    }

    func testNodeModulesDoesNotDescendIntoItself() throws {
        // A nested node_modules inside another should not be double-counted as a target.
        try writeFile("Developer/proj/node_modules/a/node_modules/b/index.js", bytes: 60_000)
        let targets = scanner.findNodeModules(under: home.appendingPathComponent("Developer"),
                                              isCancelled: { false })
        XCTAssertEqual(targets.count, 1, "only the outer node_modules is a target")
        XCTAssertTrue(targets[0].path.hasSuffix("/proj/node_modules"))
    }

    func testSubtreeBytesDoesNotFollowDirectorySymlink() throws {
        // A real subtree of 100 KB, plus a sibling symlink pointing INTO it. subtreeBytes
        // on the parent must not double-count the link target.
        try writeFile("real/data.bin", bytes: 100_000)
        let parent = home.appendingPathComponent("walkme")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("real"))
        let bytes = scanner.subtreeBytes(parent, isCancelled: { false })
        XCTAssertEqual(bytes, 0, "a symlinked dir's target bytes must not be counted")
    }

    func testSymlinkedNodeModulesNotTreatedAsTarget() throws {
        // A symlink named node_modules pointing at a real dir must NOT be reported as a target.
        try writeFile("Developer/proj/realdir/index.js", bytes: 50_000)
        let nm = home.appendingPathComponent("Developer/proj/node_modules")
        try FileManager.default.createSymbolicLink(
            at: nm, withDestinationURL: home.appendingPathComponent("Developer/proj/realdir"))
        let targets = scanner.findNodeModules(under: home.appendingPathComponent("Developer"),
                                              isCancelled: { false })
        XCTAssertTrue(targets.isEmpty, "a symlinked node_modules must not be a deletable target")
    }

    func testSnapshotsAreHelperGated() {
        let scan = scanner.scan(.apfsSnapshots)
        XCTAssertTrue(scan.needsHelper, "APFS snapshot deletion must be flagged needs-helper")
        XCTAssertEqual(scan.bytes, 0, "snapshot sizes aren't enumerable from userland")
    }

    func testScanAllCoversEveryCategory() {
        let all = scanner.scanAll()
        XCTAssertEqual(Set(all.map(\.category)), Set(CleanCategory.allCases))
    }
}
