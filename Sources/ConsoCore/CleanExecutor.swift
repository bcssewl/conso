import Foundation

// MARK: - Per-item outcome

/// What happened to one target during a clean run. "Fail loud" (macos-lessons §3):
/// every target ends as exactly one of these and the UI surfaces skipped/failed —
/// nothing is swallowed.
public enum CleanOutcome: Equatable, Sendable {
    /// Moved to the Trash (reversible — the user can restore it).
    case trashed
    /// Permanently removed (ONLY the Trash category — emptying ~/.Trash).
    case deleted
    /// Not attempted by design (needs a privileged helper, e.g. APFS snapshots, or the
    /// item no longer exists). Carries a human reason.
    case skipped(reason: String)
    /// Attempted but failed (permission denied / locked). Carries the error text.
    case failed(reason: String)
}

/// The result for one target after a clean run: which path, how many bytes it freed (only
/// counted when it actually went away), and the outcome.
public struct CleanItemResult: Identifiable, Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let category: CleanCategory
    public let outcome: CleanOutcome
    public var id: String { path }

    public init(path: String, bytes: UInt64, category: CleanCategory, outcome: CleanOutcome) {
        self.path = path
        self.bytes = bytes
        self.category = category
        self.outcome = outcome
    }

    /// True when this item was removed (trashed or deleted) — counts toward bytes freed.
    public var didRemove: Bool {
        switch outcome { case .trashed, .deleted: return true; default: return false }
    }
}

/// The aggregate result of a clean run.
public struct CleanRunResult: Equatable, Sendable {
    public let items: [CleanItemResult]

    public init(items: [CleanItemResult]) { self.items = items }

    public var trashedCount: Int { items.filter { $0.outcome == .trashed || $0.outcome == .deleted }.count }
    public var skippedCount: Int { items.filter { if case .skipped = $0.outcome { return true }; return false }.count }
    public var failedCount: Int { items.filter { if case .failed = $0.outcome { return true }; return false }.count }
    /// Bytes actually freed (only removed items count).
    public var bytesFreed: UInt64 { items.filter(\.didRemove).reduce(0) { $0 + $1.bytes } }
    public var failedItems: [CleanItemResult] { items.filter { if case .failed = $0.outcome { return true }; return false } }
}

/// A guard-failure that aborts the ENTIRE run before anything is removed. Surfaced to the
/// user — conso never partially deletes past a target that fails the safety check.
public struct CleanAborted: Error, Equatable, Sendable {
    public let path: String
    public let category: CleanCategory
    public var localizedDescription: String {
        "Aborted before deleting anything: a selected item failed the safety check (\(path))."
    }
}

// MARK: - Executor

/// Routes a single APFS local-snapshot deletion (by its `YYYY-MM-DD-HHMMSS` timestamp) to
/// the privileged helper and returns whether it succeeded plus the helper's combined
/// output. The app supplies `HelperClient.shared.deleteSnapshot`; ConsoCore never imports
/// the app or XPC, so this closure is the only seam between the tested executor and the
/// privileged side — mirrors `FixRunner`'s `RootRunner`.
public typealias SnapshotDeleter = @Sendable (String) async -> (ok: Bool, output: String)

/// Performs the clean. SAFE by construction:
/// 1. Re-checks **every** target through `CleanSafety` (fresh, not the scanner's cached
///    verdict). If any selected target fails → the whole run ABORTS (`CleanAborted`) and
///    nothing is removed.
/// 2. Removal uses `FileManager.trashItem` for all categories (reversible) — the only
///    permanent delete is the Trash category itself (emptying ~/.Trash).
/// 3. APFS snapshots are routed to the privileged helper via the injected `deleteSnapshot`
///    seam when one is wired; with none, they're skipped honestly ("install the helper").
/// Stateless / `Sendable`; runs on a detached task.
public struct CleanExecutor: Sendable {
    public let safety: CleanSafety

    /// Routes APFS snapshot deletion to the privileged helper. nil → snapshots are skipped
    /// honestly ("install the privileged helper in Settings to remove snapshots"). The app
    /// injects `HelperClient.shared.deleteSnapshot` only when the helper is installed.
    public let deleteSnapshot: SnapshotDeleter?

    public init(safety: CleanSafety = CleanSafety(), deleteSnapshot: SnapshotDeleter? = nil) {
        self.safety = safety
        self.deleteSnapshot = deleteSnapshot
    }

    /// Runs the clean for `targets`. PRE-FLIGHT: validates the entire batch against the
    /// guard first and throws `CleanAborted` on the first failure — so a bad target stops
    /// the run *before* a single file moves. Then removes each target, recording a
    /// per-item outcome (never swallowing a failure).
    ///
    /// Async because snapshot deletion `await`s the privileged-helper seam; non-snapshot
    /// removal stays the same synchronous `FileManager` work, just inside an async func.
    /// `fileManager` is injectable for testing; production passes the default.
    public func run(_ targets: [CleanTarget], fileManager fm: FileManager = .default,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> CleanRunResult {
        // 1. Pre-flight: validate EVERYTHING before removing ANYTHING.
        for target in targets {
            // Snapshots are helper-gated — they're not real filesystem paths and must not
            // be guard-checked as such; they're handled in the removal loop (delete via the
            // helper, or skip when no helper is wired).
            if target.category == .apfsSnapshots { continue }
            guard safety.isSafeToDelete(target.url, category: target.category) else {
                throw CleanAborted(path: target.path, category: target.category)
            }
        }

        // 2. Remove, recording each outcome.
        var results: [CleanItemResult] = []
        for target in targets {
            if isCancelled() { break }
            results.append(await remove(target, fm: fm))
        }
        return CleanRunResult(items: results)
    }

    /// Removes one already-pre-flighted target. Snapshots route to the privileged helper
    /// (or skip when none is wired); the Trash category is permanently deleted (emptying
    /// the bin); everything else is trashed.
    private func remove(_ target: CleanTarget, fm: FileManager) async -> CleanItemResult {
        func result(_ o: CleanOutcome) -> CleanItemResult {
            CleanItemResult(path: target.path, bytes: target.bytes, category: target.category, outcome: o)
        }

        if target.category == .apfsSnapshots {
            // APFS snapshot deletion needs root (`tmutil deletelocalsnapshots <date>`), so
            // it's routed to the privileged helper via the injected `deleteSnapshot` seam —
            // NOT the Optimize RootRunner (that runs FIXED whitelisted commands by key,
            // whereas this needs the PER-SNAPSHOT timestamp). The target's `path` is the
            // snapshot NAME, not a filesystem path.
            guard let deleteSnapshot else {
                return result(.skipped(reason: "install the privileged helper in Settings to remove snapshots"))
            }
            // Extract + strictly validate the timestamp before it leaves the process; the
            // helper re-validates server-side, but a name we can't parse is skipped here.
            guard let date = SnapshotName.date(from: target.path) else {
                return result(.skipped(reason: "unrecognized snapshot"))
            }
            let r = await deleteSnapshot(date)
            return result(r.ok ? .deleted : .failed(reason: r.output))
        }

        // Re-check existence (the user may have changed things between scan and run).
        guard fm.fileExists(atPath: target.path) else {
            return result(.skipped(reason: "no longer present"))
        }

        // Final, per-item guard re-check (belt and braces — the pre-flight already passed,
        // but a TOCTOU symlink swap would be caught here too).
        guard safety.isSafeToDelete(target.url, category: target.category) else {
            return result(.skipped(reason: "failed safety re-check"))
        }

        if target.category == .trash {
            // Emptying the bin is the one permanent delete (the items are already trashed).
            do {
                try fm.removeItem(at: target.url)
                return result(.deleted)
            } catch {
                return result(.failed(reason: error.localizedDescription))
            }
        }

        // Reversible: move to Trash so the user can restore.
        do {
            try fm.trashItem(at: target.url, resultingItemURL: nil)
            return result(.trashed)
        } catch {
            return result(.failed(reason: error.localizedDescription))
        }
    }
}
