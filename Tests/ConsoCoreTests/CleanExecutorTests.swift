import XCTest
@testable import ConsoCore

/// The executor is the only thing that removes files, so its safety behaviours are
/// nailed down: it ABORTS the whole batch before touching anything if a single target
/// fails the guard, it reports per-item outcomes (never swallowing), and it never deletes
/// permanently except for the Trash category.
final class CleanExecutorTests: XCTestCase {
    private var home: URL!
    private var safety: CleanSafety!
    private var executor: CleanExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conso-exec-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        safety = CleanSafety(home: home)
        executor = CleanExecutor(safety: safety)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeDir(_ rel: String, bytes: Int = 1000) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.appendingPathComponent("f.bin").path,
                                       contents: Data(count: bytes))
        return url
    }

    // MARK: Abort-on-guard-failure

    func testAbortsEntireRunIfAnyTargetUnsafe_andRemovesNothing() async throws {
        let safeDir = try makeDir("Library/Caches/com.acme.app")
        // An unsafe target: Documents (denylisted) mislabelled as a cache.
        let unsafeDir = try makeDir("Documents/important")
        let targets = [
            CleanTarget(path: safeDir.path, bytes: 1000, category: .systemCaches),
            CleanTarget(path: unsafeDir.path, bytes: 1000, category: .systemCaches),
        ]
        do {
            _ = try await executor.run(targets)
            XCTFail("expected CleanAborted")
        } catch {
            XCTAssertTrue(error is CleanAborted)
        }
        // CRITICAL: the safe dir must still exist — abort happens BEFORE any removal.
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeDir.path),
                      "nothing must be removed when the batch is aborted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafeDir.path))
    }

    // MARK: Reversible trashing

    func testTrashesCacheTargetsAndReportsBytesFreed() async throws {
        let a = try makeDir("Library/Caches/com.acme.app", bytes: 4000)
        let b = try makeDir("Library/Caches/com.other.tool", bytes: 6000)
        let targets = [
            CleanTarget(path: a.path, bytes: 4000, category: .systemCaches),
            CleanTarget(path: b.path, bytes: 6000, category: .systemCaches),
        ]
        let result = try await executor.run(targets)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.trashedCount, 2)
        XCTAssertEqual(result.bytesFreed, 10_000)
        // Reversible: the items left their original location (went to Trash).
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(result.items.allSatisfy { $0.outcome == .trashed })
    }

    // MARK: Skip missing / helper-gated

    func testSkipsMissingTargetWithoutFailing() async throws {
        let ghost = home.appendingPathComponent("Library/Caches/com.gone.app")
        let target = CleanTarget(path: ghost.path, bytes: 0, category: .systemCaches)
        let result = try await executor.run([target])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        if case .skipped = result.items.first?.outcome {} else {
            XCTFail("missing target should be skipped, not failed/trashed")
        }
    }

    func testSnapshotsAreSkippedWhenNoHelperWired() async throws {
        // With no deleter injected, snapshots must be skipped (not trashed/failed) and the
        // skip reason must point the user at Settings.
        let snap = CleanTarget(path: "com.apple.TimeMachine.2026-06-14-101500.local",
                               bytes: 0, category: .apfsSnapshots)
        let result = try await executor.run([snap])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        guard case .skipped(let reason) = result.items.first?.outcome else {
            return XCTFail("snapshot should be skipped when no helper is wired")
        }
        XCTAssertTrue(reason.contains("Settings"), "skip reason should point at Settings")
    }

    // MARK: Snapshot deletion via the injected helper seam

    func testSnapshotDeletedViaHelperOnSuccess() async throws {
        let recorder = DateRecorder()
        let deleter: SnapshotDeleter = { date in recorder.record(date); return (true, "Deleted local snapshot '\(date)'") }
        let exec = CleanExecutor(safety: safety, deleteSnapshot: deleter)
        let snap = CleanTarget(path: "com.apple.TimeMachine.2026-06-14-101500.local",
                               bytes: 0, category: .apfsSnapshots)
        let result = try await exec.run([snap])
        XCTAssertEqual(recorder.dates, ["2026-06-14-101500"], "the extracted timestamp must be passed to the helper")
        XCTAssertEqual(result.items.first?.outcome, .deleted)
        XCTAssertEqual(result.trashedCount, 1) // .deleted counts toward removed
    }

    func testSnapshotFailsLoudWhenHelperReportsFailure() async throws {
        let deleter: SnapshotDeleter = { _ in (false, "Operation not permitted") }
        let exec = CleanExecutor(safety: safety, deleteSnapshot: deleter)
        let snap = CleanTarget(path: "com.apple.TimeMachine.2026-06-14-101500.local",
                               bytes: 0, category: .apfsSnapshots)
        let result = try await exec.run([snap])
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.trashedCount, 0)
        guard case .failed(let reason) = result.items.first?.outcome else {
            return XCTFail("a helper failure must surface as .failed (fail loud)")
        }
        XCTAssertEqual(reason, "Operation not permitted")
    }

    func testUnrecognizedSnapshotNameSkippedAndNeverReachesHelper() async throws {
        let recorder = DateRecorder()
        let deleter: SnapshotDeleter = { date in recorder.record(date); return (true, "should not run") }
        let exec = CleanExecutor(safety: safety, deleteSnapshot: deleter)
        // A name whose timestamp can't be parsed must be skipped without calling the helper.
        let snap = CleanTarget(path: "com.apple.TimeMachine.not-a-date.local",
                               bytes: 0, category: .apfsSnapshots)
        let result = try await exec.run([snap])
        XCTAssertTrue(recorder.dates.isEmpty, "an unparseable snapshot name must never reach the helper")
        XCTAssertEqual(result.skippedCount, 1)
        guard case .skipped(let reason) = result.items.first?.outcome else {
            return XCTFail("unrecognized snapshot should be skipped")
        }
        XCTAssertEqual(reason, "unrecognized snapshot")
    }

    // MARK: Trash category empties (permanent)

    func testTrashCategoryPermanentlyDeletes() async throws {
        let item = try makeDir(".Trash/old-download", bytes: 2000)
        let target = CleanTarget(path: item.path, bytes: 2000, category: .trash)
        let result = try await executor.run([target])
        XCTAssertEqual(result.items.first?.outcome, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertEqual(result.bytesFreed, 2000)
    }
}

/// A tiny lock-guarded recorder so a `@Sendable` snapshot-deleter closure can capture the
/// dates it was handed without tripping the concurrency checker (it can't capture a
/// mutable `var`). `@unchecked Sendable` is sound here: every access is behind the lock.
private final class DateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _dates: [String] = []
    func record(_ date: String) { lock.lock(); _dates.append(date); lock.unlock() }
    var dates: [String] { lock.lock(); defer { lock.unlock() }; return _dates }
}
