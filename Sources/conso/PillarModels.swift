import Foundation
import Observation
import ConsoCore

/// Drives the Clean pillar end to end: scans the user's real cache/junk off the main
/// actor (sizes feed the ring + footers), holds the selection (categories default mostly
/// on; recovery-data hidden items default off), and orchestrates the preview → confirm →
/// execute flow. All deletion is reversible (`trashItem`) and routed through the tested
/// `CleanSafety` guard in `CleanScanner`/`CleanExecutor`.
@MainActor
@Observable
final class CleanModel {
    var categories = CleanCatalog.categories()
    var hiddenItems = CleanCatalog.hiddenItems()

    /// A scan is in flight (sizes resolving).
    private(set) var isScanning = false
    /// True once at least one scan has completed (so the UI can show real-vs-pending sizes).
    private(set) var didScan = false
    /// The concrete per-category scan results (targets + flags), keyed by category id.
    private(set) var scans: [String: CategoryScan] = [:]

    /// The preview sheet currently shown before a clean run (nil = no sheet).
    var preview: CleanPreview?
    /// The result summary shown after a run (nil = no summary).
    var result: CleanRunResult?
    /// A run aborted by the safety guard (surfaced as an error banner).
    var abortError: String?

    @ObservationIgnored private let scanner = CleanScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The in-flight clean run, stored so it can actually be cancelled (the detached task's
    /// `Task.isCancelled` is dead otherwise — nothing ever cancels it). Mirrors `scanTask`.
    @ObservationIgnored private var cleanRunTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    /// True when the privileged helper is installed, so APFS-snapshot rows can be selected
    /// and actually removed (otherwise they're locked with "needs the privileged helper —
    /// install it in Settings").
    var helperInstalled: Bool { HelperClient.shared.isInstalled }

    // MARK: Selection

    func toggleCategory(_ id: String) { toggle(id, in: &categories) }
    func toggleHidden(_ id: String) { toggle(id, in: &hiddenItems) }

    func setAllCategories(_ selected: Bool) {
        for i in categories.indices { categories[i].isSelected = selected }
    }

    private func toggle(_ id: String, in items: inout [CleanItem]) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isSelected.toggle()
    }

    /// Total of everything found in the safe-categories sweep (the hero figure).
    var reclaimableBytes: UInt64 { categories.totalBytes }

    /// True when a hidden item is helper-gated (e.g. APFS snapshots) — can't be removed
    /// without a privileged helper, so the UI shows a "needs helper" note.
    func needsHelper(_ id: String) -> Bool { scans[id]?.needsHelper ?? false }
    /// True when a hidden item needs Full Disk Access to read/act on (Mail attachments).
    func needsFDA(_ id: String) -> Bool { scans[id]?.needsFDA ?? false }

    // MARK: Scanning

    /// Kicks off the first scan. Idempotent — only the first call runs.
    func start() {
        guard !didStart else { return }
        didStart = true
        rescan()
    }

    /// Re-runs the scan of every category off the main actor, then folds the real sizes
    /// back into the category/hidden rows (selection is preserved).
    func rescan() {
        scanTask?.cancel()
        isScanning = true
        let scanner = self.scanner
        scanTask = Task.detached(priority: .utility) {
            let results = scanner.scanAll(isCancelled: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.apply(results)
                self.isScanning = false
                self.didScan = true
            }
        }
    }

    /// Folds scan results into the displayed rows, preserving the user's selection.
    private func apply(_ results: [CategoryScan]) {
        var byID: [String: CategoryScan] = [:]
        for r in results { byID[r.category.rawValue] = r }
        scans = byID
        for i in categories.indices {
            categories[i].bytes = byID[categories[i].id]?.bytes ?? 0
        }
        for i in hiddenItems.indices {
            hiddenItems[i].bytes = byID[hiddenItems[i].id]?.bytes ?? 0
        }
    }

    // MARK: Preview → confirm → execute

    /// The targets for the currently-selected rows (categories + hidden), drawn from the
    /// last scan. Used to build the preview.
    private func selectedTargets() -> [CleanTarget] {
        var ids = Set(categories.filter(\.isSelected).map(\.id))
        ids.formUnion(hiddenItems.filter(\.isSelected).map(\.id))
        return ids.flatMap { scans[$0]?.targets ?? [] }
    }

    /// Targets for a fixed set of categories (used by Quick Clean).
    private func targets(in categories: Set<CleanCategory>) -> [CleanTarget] {
        categories.flatMap { scans[$0.rawValue]?.targets ?? [] }
    }

    /// "Review & Clean" — builds the preview for the selected rows. NEVER deletes; the
    /// actual run only happens on `confirm(_:)` from the sheet.
    func review() {
        let targets = selectedTargets()
        preview = CleanPreview(kind: .review, targets: targets, scans: scans,
                               selectedIDs: selectedCategoryIDs())
    }

    /// "Quick Clean" — conservative subset only (caches/dev/browser + logs + trash), still
    /// previewed before anything is removed.
    func quickClean() {
        let targets = targets(in: CleanCatalog.quickCleanCategories)
        let ids = CleanCatalog.quickCleanCategories.map(\.rawValue)
        preview = CleanPreview(kind: .quick, targets: targets, scans: scans, selectedIDs: Set(ids))
    }

    private func selectedCategoryIDs() -> Set<String> {
        var ids = Set(categories.filter(\.isSelected).map(\.id))
        ids.formUnion(hiddenItems.filter(\.isSelected).map(\.id))
        return ids
    }

    /// User confirmed the preview — perform the run off the main actor and publish the
    /// summary (or an abort error). Re-scans afterwards so sizes reflect what's left.
    ///
    /// The executor is built HERE (not stored) so the APFS-snapshot deleter routes to the
    /// privileged helper ONLY when it's installed; otherwise no deleter is wired and
    /// snapshots are skipped honestly ("install the privileged helper in Settings"),
    /// mirroring how `OptimizeModel.confirmRun()` wires its root-runner.
    func confirm(_ preview: CleanPreview) {
        self.preview = nil
        // A previous run shouldn't outlive a new confirm; cancel it before starting.
        cleanRunTask?.cancel()
        let targets = preview.targets
        let deleteSnapshot: SnapshotDeleter?
        if HelperClient.shared.isInstalled {
            deleteSnapshot = { date in await HelperClient.shared.deleteSnapshot(date) }
        } else {
            deleteSnapshot = nil
        }
        let executor = CleanExecutor(deleteSnapshot: deleteSnapshot)
        cleanRunTask = Task.detached(priority: .userInitiated) {
            do {
                // `Task.isCancelled` here reads THIS stored task, so `cancelPreview`/teardown
                // can actually abort the run mid-flight.
                let result = try await executor.run(targets, isCancelled: { Task.isCancelled })
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.result = result
                    self.rescan()
                }
            } catch let abort as CleanAborted {
                await MainActor.run { [weak self] in
                    self?.abortError = abort.localizedDescription
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.abortError = error.localizedDescription
                }
            }
        }
    }

    /// Dismiss the preview without cleaning, and abort any in-flight clean run.
    func cancelPreview() {
        preview = nil
        cleanRunTask?.cancel()
    }
    /// Dismiss the result summary.
    func dismissResult() { result = nil }
    /// Dismiss the abort error.
    func dismissAbort() { abortError = nil }
}

/// A clean about to happen, shown in the preview sheet before any removal. Carries the
/// concrete targets grouped by category with their sizes, so the user sees exactly what
/// will move to Trash.
struct CleanPreview: Identifiable {
    enum Kind { case review, quick }
    let id = UUID()
    let kind: Kind
    let targets: [CleanTarget]
    let scans: [String: CategoryScan]
    let selectedIDs: Set<String>

    /// Total bytes that would be reclaimed.
    var totalBytes: UInt64 { targets.totalBytes }

    /// One per-category section of the preview sheet. Carries its concrete `items` (sorted
    /// largest-first) so the row can expand to show exactly what will move to Trash.
    struct Group: Identifiable {
        let category: CleanCategory
        let bytes: UInt64
        let count: Int
        let needsHelper: Bool
        let needsFDA: Bool
        /// This category's targets, sorted by size (largest first), so the expanded list
        /// leads with what reclaims the most space.
        let items: [CleanTarget]
        var id: CleanCategory { category }
    }

    /// Targets grouped by category, in catalog order, for the sheet's per-category sections.
    var groups: [Group] {
        CleanCategory.allCases.compactMap { cat in
            let items = targets.filter { $0.category == cat }
            guard !items.isEmpty else { return nil }
            let scan = scans[cat.rawValue]
            // Largest-first; stable tiebreak on path so the order is deterministic.
            let sorted = items.sortedBySizeThenPath()
            return Group(category: cat, bytes: items.totalBytes, count: items.count,
                         needsHelper: scan?.needsHelper ?? false, needsFDA: scan?.needsFDA ?? false,
                         items: sorted)
        }
    }

    var title: String { kind == .quick ? "Quick Clean" : "Review & Clean" }
}

/// Holds the user's selection for the Optimize ("Fix a problem") pillar and drives the
/// real run. Every task is default-off — nothing runs until the user picks it. User-level
/// fixes run for real via `FixRunner`; root-level steps route to the privileged helper
/// when it's installed (`HelperClient`), and are flagged "install the privileged helper in
/// Settings" — never faked — when it isn't.
@MainActor
@Observable
final class OptimizeModel {
    var tasks = OptimizeCatalog.tasks()

    /// A brief detect pass on first appear so the UI shows a momentary "checking…" state
    /// rather than popping the full list in instantly. The fix catalog is synchronous, so
    /// this is a short cosmetic settle, not a real probe.
    private(set) var isDetecting = true
    /// True once the detect pass has completed.
    private(set) var didDetect = false
    @ObservationIgnored private var didStartDetect = false

    /// Executes the user-level steps (and root steps via the helper when installed) and
    /// publishes per-task status (bound by the sheet). Rebuilt at confirm time so the run
    /// is wired to the helper only when it's actually installed (see `confirmRun`).
    private(set) var runner = FixRunner()

    /// The confirmation dialog before a run (nil = not shown). Lists what will run now
    /// vs. what needs the helper.
    var pendingConfirmation: RunPlan?
    /// The app-picker sheet for the "Reset an App's Preferences" fix (nil = not shown).
    var appPicker: AppPickerState?
    /// True once the results sheet should show (mirrors the runner having results).
    var showingResults = false

    /// The chosen bundle id per app-picker task (id → bundle id), filled by the picker.
    @ObservationIgnored private var bundleIDsByTask: [String: String] = [:]
    @ObservationIgnored private let inventory = SoftwareInventory()

    /// Timestamp of the last Optimize run (nil ⇒ never run), so the stat strip can show a
    /// REAL "Last run" instead of fabricated data. Observed (drives the view) and mirrored to
    /// UserDefaults so it survives relaunch. Mirrors `AutoCleanScheduler.lastRun`.
    private(set) var lastRun: Date? {
        didSet { defaults.set(lastRun, forKey: Self.lastRunKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private static let lastRunKey = "optimize.lastRun"

    /// `defaults` is injectable for tests/previews; seeds `lastRun` from persisted state.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastRun = defaults.object(forKey: Self.lastRunKey) as? Date
    }

    // MARK: Detect (first appear)

    /// Kicks off the one-time detect pass. Idempotent — only the first call runs.
    func detect() {
        guard !didStartDetect else { return }
        didStartDetect = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.tasks = OptimizeCatalog.tasks()
            self.isDetecting = false
            self.didDetect = true
        }
    }

    // MARK: Selection

    func toggle(_ id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isSelected.toggle()
    }

    func setAll(_ selected: Bool) {
        for i in tasks.indices { tasks[i].isSelected = selected }
    }

    private var selectedTasks: [FixTask] { tasks.filter(\.isSelected) }

    // MARK: Confirm → run

    /// Entry point for "Run Selected Fixes". If a selected fix needs a bundle id and none
    /// is chosen yet, opens the app picker first; otherwise opens the confirm dialog.
    func runSelected() {
        let selected = selectedTasks
        guard !selected.isEmpty else { return }
        // Any app-picker task still missing a bundle id → pick one first.
        if let needsPick = selected.first(where: { $0.requiresAppPicker && bundleIDsByTask[$0.id] == nil }) {
            openAppPicker(for: needsPick)
            return
        }
        pendingConfirmation = RunPlan(tasks: selected, bundleIDsByTask: bundleIDsByTask)
    }

    /// User confirmed the dialog — start the run and show the results sheet. The runner is
    /// rebuilt here so root steps route to the privileged helper ONLY when it's installed;
    /// otherwise no root-runner is wired and those steps are skipped honestly ("install the
    /// privileged helper in Settings"), never failed and never faked.
    func confirmRun() {
        let plan = pendingConfirmation
        pendingConfirmation = nil
        guard let plan else { return }
        let runRoot: RootRunner?
        if HelperClient.shared.isInstalled {
            runRoot = { key in await HelperClient.shared.runFix(key) }
        } else {
            runRoot = nil
        }
        runner = FixRunner(runRoot: runRoot)
        runner.run(plan.tasks, bundleIDsByTask: plan.bundleIDsByTask)
        lastRun = Date()
        showingResults = true
    }

    func cancelConfirmation() { pendingConfirmation = nil }

    /// Dismiss the results sheet and clear the run.
    func dismissResults() {
        showingResults = false
        runner.reset()
    }

    // MARK: App picker (for Reset an App's Preferences)

    /// Opens the picker for `task`, loading the installed-app list off the main actor.
    private func openAppPicker(for task: FixTask) {
        let state = AppPickerState(taskID: task.id)
        appPicker = state
        let inventory = self.inventory
        Task.detached(priority: .userInitiated) {
            let apps = inventory.apps().filter { !$0.bundleID.isEmpty }
            await MainActor.run { [weak self] in
                guard let self, self.appPicker?.taskID == task.id else { return }
                self.appPicker?.apps = apps
                self.appPicker?.isLoading = false
            }
        }
    }

    /// The picker chose `bundleID` for its task — record it and continue to confirmation.
    func choosePickedApp(_ bundleID: String) {
        guard let state = appPicker else { return }
        bundleIDsByTask[state.taskID] = bundleID
        appPicker = nil
        runSelected()   // re-enter: any remaining picker opens next, else confirm.
    }

    /// Dismiss the picker without choosing (cancels the whole run).
    func cancelAppPicker() { appPicker = nil }
}

/// The set of fixes about to run, shown in the confirm dialog (split into what runs now
/// vs. what's routed to / deferred to the privileged helper).
struct RunPlan: Identifiable {
    let id = UUID()
    let tasks: [FixTask]
    let bundleIDsByTask: [String: String]

    /// Fixes with at least one user-level step that runs now.
    var runsNow: [FixTask] {
        tasks.filter { task in
            if task.requiresAppPicker { return bundleIDsByTask[task.id] != nil }
            return !task.userSteps.isEmpty
        }
    }
    /// Fixes that are fully helper-gated (nothing runs now).
    var helperOnly: [FixTask] { tasks.filter { $0.userSteps.isEmpty && !$0.requiresAppPicker } }
    /// Fixes that run now but defer some root work to the helper.
    var partial: [FixTask] { tasks.filter { !$0.userSteps.isEmpty && $0.needsHelper } }
    /// Per-task warnings to surface in the dialog.
    var warnings: [(name: String, text: String)] {
        tasks.compactMap { $0.warning.isEmpty ? nil : ($0.name, $0.warning) }
    }
}

/// State for the "Reset an App's Preferences" app picker sheet.
@MainActor
@Observable
final class AppPickerState: Identifiable {
    let id = UUID()
    let taskID: String
    var apps: [InstalledApp] = []
    var isLoading = true
    /// A free-form bundle-id typed by the user (escape hatch when the app isn't listed).
    var manualBundleID = ""

    init(taskID: String) { self.taskID = taskID }
}
