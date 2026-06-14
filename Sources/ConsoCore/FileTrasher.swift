import Foundation

// MARK: - Per-file finder result

/// What happened to one file the finder tried to trash. Reuses the `CleanOutcome` vocabulary
/// (trashed / skipped / failed) — the finder NEVER permanently deletes, so `.deleted` is
/// not produced here.
public struct FileTrashResult: Identifiable, Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let outcome: CleanOutcome
    public var id: String { path }

    public init(path: String, bytes: UInt64, outcome: CleanOutcome) {
        self.path = path
        self.bytes = bytes
        self.outcome = outcome
    }

    public var didRemove: Bool {
        if case .trashed = outcome { return true }
        return false
    }
}

/// The aggregate of a finder trash run.
public struct FileTrashRunResult: Equatable, Sendable {
    public let items: [FileTrashResult]
    public init(items: [FileTrashResult]) { self.items = items }

    public var trashedCount: Int { items.filter(\.didRemove).count }
    public var skippedCount: Int { items.filter { if case .skipped = $0.outcome { return true }; return false }.count }
    public var failedCount: Int { items.filter { if case .failed = $0.outcome { return true }; return false }.count }
    public var bytesFreed: UInt64 { items.filter(\.didRemove).reduce(0) { $0 &+ $1.bytes } }
}

// MARK: - Trasher

/// Moves user-selected finder files to the Trash. SAFE by construction:
///  1. Every path is re-checked against a protected-path guard (denylist + system roots)
///     FRESH at trash time — never the scanner's cached verdict. A protected path is
///     SKIPPED with a reason (the finder shouldn't surface them, but defence in depth).
///  2. Removal is ALWAYS `FileManager.trashItem` — reversible, never a permanent delete.
///  3. Failures are surfaced per-item (fail loud), never swallowed.
///
/// Unlike `CleanExecutor` this does NOT abort the whole batch on a bad path: finder files
/// live anywhere under home (including Documents), so there's no category allowlist to
/// pre-flight against — instead each file is guarded individually and a rejected one is
/// skipped, not fatal. Stateless / `Sendable`.
public struct FileTrasher: Sendable {
    public let safety: CleanSafety

    public init(safety: CleanSafety = CleanSafety()) {
        self.safety = safety
    }

    /// Trashes each record, guarding every path first. `fileManager` is injectable for
    /// testing. Honours `isCancelled` between items.
    public func trash(_ records: [FileRecord], fileManager fm: FileManager = .default,
                      isCancelled: @Sendable () -> Bool = { false }) -> FileTrashRunResult {
        var results: [FileTrashResult] = []
        for r in records {
            if isCancelled() { break }
            results.append(trashOne(r, fm: fm))
        }
        return FileTrashRunResult(items: results)
    }

    private func trashOne(_ r: FileRecord, fm: FileManager) -> FileTrashResult {
        func result(_ o: CleanOutcome) -> FileTrashResult {
            FileTrashResult(path: r.path, bytes: r.size, outcome: o)
        }
        // Guard FIRST — never trash a protected/system path, no matter what the user picked.
        guard isTrashable(r.url) else {
            return result(.skipped(reason: "protected path — refused"))
        }
        guard fm.fileExists(atPath: r.path) else {
            return result(.skipped(reason: "no longer present"))
        }
        do {
            try fm.trashItem(at: r.url, resultingItemURL: nil)
            return result(.trashed)
        } catch {
            return result(.failed(reason: error.localizedDescription))
        }
    }

    /// True only if `url` may be trashed: it must resolve to somewhere strictly inside the
    /// user's home, not be the home root, contain no `..` escape, and not sit under any
    /// sensitive (credential / sync / system) root. User documents/media ARE trashable when
    /// explicitly selected — only credential/system subtrees are categorically refused.
    func isTrashable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != safety.home.path, resolved.path != "/" else { return false }
        if resolved.pathComponents.contains("..") { return false }
        guard safety.isInside(resolved, of: safety.home) else { return false }
        for root in FileSafety.sensitiveRoots(home: safety.home)
        where safety.isAtOrInside(resolved, of: root) { return false }
        return true
    }
}
