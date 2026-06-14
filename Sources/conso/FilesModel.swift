import Foundation
import Observation
import ConsoCore

/// Drives the Analyze → Files finder: walks a chosen folder off the main actor, finds
/// exact by-content duplicates and old/unused files, tracks the user's selection
/// (keep-one for each duplicate group; checkbox for old files), and trashes the selected
/// files reversibly through `FileTrasher`.
///
/// Scans are cancellable — changing the folder or rescanning cancels any in-flight scan
/// before starting the next. `@MainActor` so its observable state reads directly from the
/// view; the heavy walk + hashing run on a detached utility task.
@MainActor
@Observable
final class FilesModel {
    /// The folder being scanned. Defaults to the user's home.
    private(set) var root: URL
    /// Duplicate groups (most-reclaimable-first), populated after a scan.
    private(set) var duplicates: [DuplicateGroup] = []
    /// Old / unused files (largest-first), populated after a scan.
    private(set) var oldFiles: [FileRecord] = []

    /// A scan is running.
    private(set) var isScanning = false
    /// The phase label shown while scanning ("Walking…", "Hashing duplicates…").
    private(set) var phase: String = ""
    /// The result set was capped (huge folder) — surfaced to the user.
    private(set) var capped = false
    /// A subtree was unreadable (FDA / permissions) — the map is partial.
    private(set) var partial = false
    /// Whether Full Disk Access is currently granted (probed live on each scan).
    private(set) var fdaGranted = false
    /// At least one scan has completed (so empty states only show post-scan).
    private(set) var didScan = false

    /// Per group: the path the user chose to KEEP. Defaults to the group's first file.
    var keepByGroup: [String: String] = [:]
    /// Selected old-file paths to trash.
    var selectedOld: Set<String> = []

    /// Age threshold (days) for the old-file finder.
    let thresholdDays = OldFileFinder.defaultThresholdDays

    @ObservationIgnored private var task: Task<Void, Never>?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = root
    }

    // MARK: - Derived

    /// Bytes reclaimable if the user keeps one copy of each duplicate group.
    var duplicateReclaimable: UInt64 { DuplicateFinder.reclaimableBytes(duplicates) }

    /// Total bytes of the currently-selected old files.
    var selectedOldBytes: UInt64 {
        oldFiles.filter { selectedOld.contains($0.path) }.reduce(0) { $0 &+ $1.size }
    }

    /// The trash candidates for a group: every file EXCEPT the kept one.
    func candidates(in group: DuplicateGroup) -> [FileRecord] {
        let keep = keepByGroup[group.id] ?? group.files.first?.path
        return group.files.filter { $0.path != keep }
    }

    /// The path kept for a group (defaults to its first / largest file).
    func keptPath(in group: DuplicateGroup) -> String? {
        keepByGroup[group.id] ?? group.files.first?.path
    }

    // MARK: - Folder picking

    /// Sets a new root and immediately rescans it.
    func setRoot(_ url: URL) {
        root = url
        scan()
    }

    // MARK: - Scanning

    /// Kicks off (or re-runs) the scan of the current root. Cancels any in-flight scan.
    func scan() {
        task?.cancel()
        isScanning = true
        didScan = false
        duplicates = []
        oldFiles = []
        keepByGroup = [:]
        selectedOld = []
        capped = false
        partial = false
        phase = "Walking folder…"

        let root = self.root
        let threshold = self.thresholdDays
        task = Task.detached(priority: .utility) {
            let fda = DiskScanner.hasFullDiskAccess()
            let scanner = FileScanner()
            let result = scanner.scan(root, isCancelled: { Task.isCancelled })
            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self, root == self.root else { return }
                self.fdaGranted = fda
                self.phase = "Hashing duplicates…"
            }

            let finder = DuplicateFinder()
            let dupes = finder.findDuplicates(in: result.files, isCancelled: { Task.isCancelled })
            if Task.isCancelled { return }

            let old = OldFileFinder(thresholdDays: threshold).oldFiles(from: result.files, now: Date())
            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self, root == self.root else { return }
                self.duplicates = dupes
                self.oldFiles = old
                self.keepByGroup = Dictionary(uniqueKeysWithValues: dupes.compactMap { g in
                    g.files.first.map { (g.id, $0.path) }
                })
                self.capped = result.capped
                self.partial = result.partial || !fda
                self.didScan = true
                self.isScanning = false
                self.phase = ""
            }
        }
    }

    // MARK: - Trashing

    /// Trashes every non-kept copy across all duplicate groups (reversible, guarded).
    /// Rescans afterwards so the lists reflect what's gone.
    func trashDuplicateCandidates() {
        let records = duplicates.flatMap { candidates(in: $0) }
        trash(records)
    }

    /// Trashes the selected old files (reversible, guarded), then rescans.
    func trashSelectedOld() {
        let records = oldFiles.filter { selectedOld.contains($0.path) }
        trash(records)
    }

    /// Toggles an old-file selection.
    func toggleOld(_ path: String) {
        if selectedOld.contains(path) { selectedOld.remove(path) } else { selectedOld.insert(path) }
    }

    private func trash(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }
        let trasher = FileTrasher()
        Task.detached(priority: .userInitiated) {
            _ = trasher.trash(records)
            await MainActor.run { [weak self] in self?.scan() }
        }
    }
}
