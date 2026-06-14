import Foundation
import UserNotifications
import ConsoCore

// App-side `Identifiable` conformance so `CleanScheduleInterval` works with `SegmentedPills`
// (ConsoCore stays SwiftUI-free, so the conformance lives in the app module).
extension CleanScheduleInterval: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// Optional, OFF-BY-DEFAULT background task that periodically runs conso's CONSERVATIVE
/// Quick Clean (`CleanCatalog.quickCleanCategories`: caches, dev junk, browser data, logs,
/// trash) and notifies the user with the bytes freed.
///
/// SAFETY (matches manual Quick Clean exactly, never more):
/// - Disabled by default; nothing runs until the user opts in in Settings.
/// - Only the Quick Clean categories — NEVER app leftovers, NEVER any hidden / recovery-data
///   item (APFS snapshots, iOS backups, mail attachments).
/// - Trash-only / reversible via `CleanExecutor` with NO snapshot deleter wired, so no root
///   work ever happens here. The one permanent step is emptying the Trash category — which is
///   exactly what manual Quick Clean already does (the bin's items are already trashed).
/// - Notifications are best-effort: if the user hasn't authorized them the clean still runs
///   silently; we never block on permission.
///
/// Scheduling uses `NSBackgroundActivityScheduler` (idiomatic macOS periodic-while-running)
/// PLUS an on-launch overdue check, so a missed window is caught up the next time conso runs.
/// Note: this only fires while conso is alive — pair with "Launch at login" for regular
/// background runs.
@MainActor
@Observable
final class AutoCleanScheduler {
    // MARK: Persistence keys

    private enum Keys {
        static let enabled = "autoClean.enabled"
        static let interval = "autoClean.interval"
        static let lastRun = "autoClean.lastRun"
    }

    // This type is `@Observable` only so it can be injected once via `.environment` and shared
    // (avoiding duplicate `NSBackgroundActivityScheduler` registrations). Its settings are read
    // through UserDefaults-backed computed properties, so none of the stored state below is
    // observed — mark it ignored.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identifier = "app.conso.autoclean"
    @ObservationIgnored private var activity: NSBackgroundActivityScheduler?
    /// Guards against overlapping runs (the on-launch check + a scheduler fire racing).
    @ObservationIgnored private var isRunning = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Settings (read/write)

    /// Whether auto-clean is enabled. FALSE by default — opt-in only.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// How often auto-clean runs (defaults to weekly when unset / unrecognized).
    var interval: CleanScheduleInterval {
        get {
            guard let raw = defaults.string(forKey: Keys.interval),
                  let value = CleanScheduleInterval(rawValue: raw) else { return .weekly }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.interval) }
    }

    /// When the last successful auto-clean completed (nil ⇒ never run ⇒ due immediately).
    private(set) var lastRun: Date? {
        get { defaults.object(forKey: Keys.lastRun) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastRun) }
    }

    // MARK: Lifecycle

    /// Starts (or restarts) the scheduler to reflect the current settings, then runs an
    /// immediate overdue catch-up if due. Idempotent — call on launch and after any settings
    /// change.
    func start() {
        reschedule()
        // On-launch catch-up: a window missed while conso was closed runs now.
        Task { await runIfDue() }
    }

    /// Applies the current settings to the background activity: registers a repeating
    /// activity when enabled, or tears down any existing one when disabled.
    func reschedule() {
        activity?.invalidate()
        activity = nil
        guard isEnabled else { return }

        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.tolerance = interval.interval * 0.2
        // The activity fires opportunistically; the real cadence is enforced by `isDue`
        // against `lastRun`, so an early wake just no-ops.
        scheduler.interval = interval.interval
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.finished); return }
            Task { @MainActor in
                await self.runIfDue()
                completion(.finished)
            }
        }
        activity = scheduler
    }

    // MARK: Run

    /// Runs a Quick Clean if (and only if) auto-clean is enabled AND due. Safe to call
    /// repeatedly — guards against re-entrancy and re-checks `isDue` each time.
    func runIfDue(now: Date = Date()) async {
        guard isEnabled, !isRunning else { return }
        guard CleanSchedule.isDue(now: now, lastRun: lastRun, interval: interval) else { return }
        isRunning = true
        defer { isRunning = false }

        let result = await Self.performQuickClean()
        lastRun = Date()
        await notify(result)
    }

    /// Scans + trashes the Quick Clean categories off the main actor. No snapshot deleter is
    /// wired (trash-only, no root work); the executor re-validates every target through
    /// `CleanSafety` and aborts the whole run if any fails, so a bad target removes nothing.
    private static func performQuickClean() async -> CleanRunResult {
        await Task.detached(priority: .background) {
            let scanner = CleanScanner()
            // Scan only the Quick Clean categories — no need to walk hidden / recovery items.
            var scans: [String: CategoryScan] = [:]
            for category in CleanSchedule.quickCleanCategories {
                let scan = scanner.scan(category)
                scans[category.rawValue] = scan
            }
            let targets = CleanSchedule.quickCleanTargets(scans: scans)
            guard !targets.isEmpty else { return CleanRunResult(items: []) }
            // Trash-only: NO `deleteSnapshot` seam — scheduled clean never does root work.
            let executor = CleanExecutor()
            do {
                return try await executor.run(targets)
            } catch {
                // A guard abort means nothing was removed — report an empty run.
                return CleanRunResult(items: [])
            }
        }.value
    }

    // MARK: Notification

    /// Posts a local notification summarizing the run. Best-effort: if notifications aren't
    /// authorized the clean has already happened — we never block on permission.
    private func notify(_ result: CleanRunResult) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "conso cleaned up"
        if result.bytesFreed > 0 {
            content.body = "Freed \(ByteFormat.string(result.bytesFreed)) to the Trash — caches, logs and dev junk."
        } else {
            content.body = "Nothing to clean right now — your Mac is already tidy."
        }
        content.sound = nil

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
