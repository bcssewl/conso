import XCTest
@testable import ConsoCore

/// The safety net. conso DELETES the user's files, so this guard is exercised
/// exhaustively against a sandboxed temp "home": allowed caches must pass; documents,
/// the system, the home root, symlink escapes, `..` escapes, and browser
/// history/cookies must all be REJECTED. A regression here is a data-loss bug.
final class CleanSafetyTests: XCTestCase {
    /// An isolated temp directory standing in for the user's home, so tests never touch
    /// (or depend on) the real home and can build symlinks safely.
    private var home: URL!
    private var safety: CleanSafety!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conso-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Resolve so /var vs /private/var symlinking doesn't surprise the guard.
        safety = CleanSafety(home: home.resolvingSymlinksInPath().standardizedFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func make(_ rel: String, dir: Bool = true) throws -> URL {
        let url = safety.home.appendingPathComponent(rel)
        if dir {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return url
    }

    // MARK: - Allowed

    func testSystemCacheSubfolderIsSafe() throws {
        let url = try make("Library/Caches/com.acme.app")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .systemCaches))
    }

    func testDerivedDataIsSafe() throws {
        let url = try make("Library/Developer/Xcode/DerivedData/MyApp-abc123")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .developerJunk))
    }

    func testNodeModulesUnderDeveloperIsSafe() throws {
        let url = try make("Developer/myproj/node_modules")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .developerJunk))
    }

    func testLogsAreSafe() throws {
        let url = try make("Library/Logs/DiagnosticReports")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .logs))
    }

    func testTrashIsSafe() throws {
        let url = try make(".Trash/old-file")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .trash))
    }

    func testBrowserCacheLeafIsSafe() throws {
        let url = try make("Library/Application Support/Google/Chrome/Default/Cache")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .browserData))
    }

    func testBrowserCodeCacheIsSafe() throws {
        let url = try make("Library/Application Support/Google/Chrome/Default/Code Cache/js")
        XCTAssertTrue(safety.isSafeToDelete(url, category: .browserData))
    }

    // MARK: - Rejected: protected user data

    func testDocumentsRejected() throws {
        let url = try make("Documents/taxes.pdf", dir: false)
        // Even if a (buggy) caller passed Documents to a cache category, deny wins.
        for cat in CleanCategory.allCases {
            XCTAssertFalse(safety.isSafeToDelete(url, category: cat), "Documents must never be deletable (\(cat))")
        }
    }

    func testDesktopAndPicturesRejected() throws {
        let desktop = try make("Desktop/screenshot.png", dir: false)
        let pictures = try make("Pictures/Photos Library.photoslibrary")
        XCTAssertFalse(safety.isSafeToDelete(desktop, category: .systemCaches))
        XCTAssertFalse(safety.isSafeToDelete(pictures, category: .systemCaches))
    }

    func testKeychainRejected() throws {
        let url = try make("Library/Keychains/login.keychain-db", dir: false)
        XCTAssertFalse(safety.isSafeToDelete(url, category: .systemCaches))
    }

    func testICloudRejected() throws {
        let url = try make("Library/Mobile Documents/com~apple~CloudDocs/file.txt", dir: false)
        XCTAssertFalse(safety.isSafeToDelete(url, category: .systemCaches))
    }

    func testMobileSyncRejectedForCacheCategories() throws {
        let url = try make("Library/Application Support/MobileSync/Backup/abc/Info.plist", dir: false)
        // App-leftovers/caches must not reach MobileSync even though it's under App Support.
        XCTAssertFalse(safety.isSafeToDelete(url, category: .appLeftovers))
        XCTAssertFalse(safety.isSafeToDelete(url, category: .systemCaches))
    }

    // MARK: - Rejected: browser history / cookies / logins

    func testBrowserHistoryRejected() throws {
        let history = try make("Library/Application Support/Google/Chrome/Default/History", dir: false)
        let cookies = try make("Library/Application Support/Google/Chrome/Default/Cookies", dir: false)
        let logins = try make("Library/Application Support/Google/Chrome/Default/Login Data", dir: false)
        XCTAssertFalse(safety.isSafeToDelete(history, category: .browserData))
        XCTAssertFalse(safety.isSafeToDelete(cookies, category: .browserData))
        XCTAssertFalse(safety.isSafeToDelete(logins, category: .browserData))
    }

    func testBrowserProfileRootRejected() throws {
        // The profile root holds history/cookies — only cache LEAVES may go.
        let profile = try make("Library/Application Support/Google/Chrome/Default")
        XCTAssertFalse(safety.isSafeToDelete(profile, category: .browserData))
    }

    func testSafariRejectedEntirely() throws {
        let url = try make("Library/Safari/History.db", dir: false)
        XCTAssertFalse(safety.isSafeToDelete(url, category: .browserData))
    }

    // MARK: - Rejected: system & out-of-home

    func testSystemPathsRejected() {
        for p in ["/System/Library/Caches", "/usr/bin", "/bin/ls", "/Library/Caches", "/etc/hosts"] {
            let url = URL(fileURLWithPath: p)
            XCTAssertFalse(safety.isSafeToDelete(url, category: .systemCaches), "\(p) must be rejected")
        }
    }

    func testHomeRootItselfRejected() {
        XCTAssertFalse(safety.isSafeToDelete(safety.home, category: .systemCaches))
        XCTAssertFalse(safety.isSafeToDelete(safety.home, category: .trash))
    }

    func testFilesystemRootRejected() {
        XCTAssertFalse(safety.isSafeToDelete(URL(fileURLWithPath: "/"), category: .systemCaches))
    }

    func testOtherUserHomeRejected() {
        let other = URL(fileURLWithPath: "/Users/someoneelse/Library/Caches/x")
        XCTAssertFalse(safety.isSafeToDelete(other, category: .systemCaches))
    }

    // MARK: - Rejected: escapes

    func testDotDotEscapeRejected() {
        // A path that tries to climb out of Caches back to Documents.
        let escape = safety.home.appendingPathComponent("Library/Caches/../../Documents/secret.txt")
        XCTAssertFalse(safety.isSafeToDelete(escape, category: .systemCaches))
    }

    func testDotDotToHomeRootRejected() {
        let escape = safety.home.appendingPathComponent("Library/Caches/../..")
        XCTAssertFalse(safety.isSafeToDelete(escape, category: .systemCaches))
    }

    func testSymlinkOutOfAllowlistRejected() throws {
        // A symlink that lives in an allowed cache dir but points at Documents.
        let cacheDir = try make("Library/Caches")
        let documents = try make("Documents")
        let link = cacheDir.appendingPathComponent("evil-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: documents)
        // The guard resolves the symlink, so the *target* (Documents) is what's judged.
        XCTAssertFalse(safety.isSafeToDelete(link, category: .systemCaches),
                       "a symlink pointing out of the allowlist must be rejected on its target")
    }

    func testSymlinkToSystemRejected() throws {
        let cacheDir = try make("Library/Caches")
        let link = cacheDir.appendingPathComponent("sys-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System"))
        XCTAssertFalse(safety.isSafeToDelete(link, category: .systemCaches))
    }

    // MARK: - Wrong-category isolation

    func testDerivedDataNotAllowedForBrowserCategory() throws {
        let url = try make("Library/Developer/Xcode/DerivedData/MyApp-abc")
        XCTAssertFalse(safety.isSafeToDelete(url, category: .browserData),
                       "an allowlist entry only counts for its own category")
    }

    func testTrashNotAllowedForOtherCategory() throws {
        let url = try make(".Trash/old")
        XCTAssertFalse(safety.isSafeToDelete(url, category: .systemCaches))
    }
}
