import Foundation
import Observation

/// The route conso takes for one update. conso never silently installs third-party
/// software — every route hands off to the app's own installer. The app layer turns
/// these into `NSWorkspace`/`openURL` calls (AppKit lives there, not in ConsoCore).
public enum UpdateRoute: Equatable, Sendable {
    /// Open a deep-link URL (App Store page, Software Update settings, Login Items).
    case openURL(String)
    /// Launch an app bundle so its own (Sparkle/Electron) updater runs.
    case openApp(bundlePath: String)
    /// Run `brew upgrade` in place, streaming output (the only batchable group).
    case brewUpgrade(name: String, isCask: Bool)
    /// No actionable route (e.g. an App-Store app with unknown remote, mas absent) —
    /// the best we can do is open the App Store updates page.
    case openAppStoreUpdates
}

/// Routing helpers: given an `AppUpdate`, decide where its button should go. Kept in
/// ConsoCore (pure data) so it's unit-testable; the app layer executes the result.
public enum SoftwareRouter {
    /// macOS Software Update settings pane.
    public static let softwareUpdateSettingsURL =
        "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    /// Login Items settings pane.
    public static let loginItemsSettingsURL =
        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    /// The App Store "Updates" page (used when we have no specific app id).
    public static let appStoreUpdatesURL = "macappstore://showUpdatesPage"

    /// App Store deep-link for a specific app by its numeric adam-id.
    public static func appStoreURL(forID id: String) -> String {
        "macappstore://apps.apple.com/app/id\(id)"
    }

    /// The route for a detected update, derived from its source + routing payload.
    public static func route(for update: AppUpdate) -> UpdateRoute {
        switch update.source {
        case .system:
            return .openURL(softwareUpdateSettingsURL)
        case .appStore:
            if let id = update.masID { return .openURL(appStoreURL(forID: id)) }
            return .openAppStoreUpdates
        case .homebrew:
            if let name = update.brewName { return .brewUpgrade(name: name, isCask: update.isCask) }
            return .openAppStoreUpdates  // unreachable in practice
        case .sparkle, .electron:
            if let path = update.bundlePath { return .openApp(bundlePath: path) }
            return .openAppStoreUpdates  // unreachable in practice
        }
    }
}

/// Drives the Software page end to end: loads the installed-app inventory, runs the
/// update detectors off the main actor, and publishes everything the view binds to.
/// `@MainActor @Observable`, mirroring AnalyzeModel / MetricsViewModel.
@MainActor
@Observable
public final class SoftwareModel {
    /// Detected third-party / system app updates (system row excluded — see below).
    public private(set) var updates: [AppUpdate] = []
    /// The single macOS system update, if any. Kept separate (installs + restarts).
    public private(set) var systemUpdate: AppUpdate?
    /// Every installed `.app` (with sizes once the size pass finishes).
    public private(set) var installedApps: [InstalledApp] = []
    /// Launch agents / daemons, read-only.
    public private(set) var loginItems: [LoginItem] = []
    /// A scan is in flight (inventory + detectors).
    public private(set) var isScanning = false
    /// When the last successful scan completed (for the "checked N min ago" footnote).
    public private(set) var lastScan: Date?
    /// The brew upgrade currently running, with its streamed log (nil when idle).
    public private(set) var brewProgress: BrewProgress?

    @ObservationIgnored private let inventory = SoftwareInventory()
    @ObservationIgnored private let scanner = SoftwareScanner()
    @ObservationIgnored private let loginReader = LoginItemsReader()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    public init() {}

    // MARK: Derived counts (real data only)

    /// Number of routed app updates (excludes the system row).
    public var updateCount: Int { updates.count }
    /// Number of installed apps.
    public var appCount: Int { installedApps.count }
    /// Number of login items.
    public var loginItemCount: Int { loginItems.count }
    /// Login items that start at load (the "slow startup" proxy).
    public var slowLoginItemCount: Int { loginItems.filter(\.runAtLoad).count }
    /// Total download size across updates whose size is known (homebrew/electron = 0).
    public var totalDownloadBytes: UInt64 { updates.reduce(0) { $0 + $1.bytes } }

    /// The route for an update — the view turns this into an `NSWorkspace`/`openURL` call.
    public func route(for update: AppUpdate) -> UpdateRoute { SoftwareRouter.route(for: update) }

    // MARK: Scanning

    /// Kicks off the first full scan. Idempotent; only the first call runs.
    public func start() {
        guard !didStart else { return }
        didStart = true
        refresh()
    }

    /// Re-runs the full scan (inventory + every detector), cancelling any in flight.
    public func refresh() {
        scanTask?.cancel()
        isScanning = true
        let inventory = self.inventory
        let scanner = self.scanner
        let loginReader = self.loginReader

        scanTask = Task.detached(priority: .utility) {
            // 1. Inventory first — detectors depend on it (Sparkle/Electron/receipt).
            let apps = inventory.appsWithSizes(isCancelled: { Task.isCancelled })
            let logins = loginReader.items()
            if Task.isCancelled { return }
            // Publish inventory immediately so the Installed/Login tabs fill in early.
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.installedApps = apps
                self.loginItems = logins
            }

            // 2. Run the detectors. The synchronous (subprocess/file) ones first,
            //    then Sparkle's async network pass.
            let brew = scanner.homebrewUpdates()
            let appStore = scanner.appStoreUpdates(installed: apps)
            let electron = scanner.electronUpdates(installed: apps)
            let system = scanner.systemUpdate()
            let sparkle = await scanner.sparkleUpdates(installed: apps)
            if Task.isCancelled { return }

            let merged = Self.merge(brew: brew, appStore: appStore, sparkle: sparkle, electron: electron)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.updates = merged
                self.systemUpdate = system
                self.lastScan = Date()
                self.isScanning = false
            }
        }
    }

    /// Combines detector outputs into the displayed list. De-dupes by bundle path so an
    /// app found by two detectors (e.g. a cask that's also Sparkle) appears once, and
    /// drops the no-remote App-Store-receipt fallbacks when `mas` produced real rows.
    nonisolated static func merge(brew: [AppUpdate], appStore: [AppUpdate],
                                  sparkle: [AppUpdate], electron: [AppUpdate]) -> [AppUpdate] {
        // Sparkle gives the most precise comparison; prefer it on path collisions.
        var byPath: [String: AppUpdate] = [:]
        var ordered: [AppUpdate] = []

        func add(_ list: [AppUpdate]) {
            for u in list {
                if let path = u.bundlePath {
                    if byPath[path] != nil { continue }   // first writer wins (priority order)
                    byPath[path] = u
                }
                ordered.append(u)
            }
        }
        // Priority: Sparkle (real remote) > App Store > Homebrew > Electron (unknown remote).
        add(sparkle)
        add(appStore)
        add(brew)
        add(electron)
        // Sort: known-remote updates first, then by name.
        return ordered.sorted { lhs, rhs in
            if lhs.remoteVersionKnown != rhs.remoteVersionKnown { return lhs.remoteVersionKnown }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Homebrew upgrade (in-place, streamed)

    /// Runs `brew upgrade <name>` and streams its output into `brewProgress`, then
    /// re-scans on completion. The only route conso performs in place — everything
    /// else hands off to the app's own installer.
    public func runBrewUpgrade(name: String, isCask: Bool) {
        guard brewProgress == nil, let brew = SoftwareScanner.brewPath else { return }
        brewProgress = BrewProgress(name: name)

        let progress = brewProgress
        Task.detached(priority: .utility) {
            var args = ["upgrade"]
            if isCask { args.append("--cask") }
            args.append(name)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: brew)
            task.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            // Stream output line-by-line into the progress log on the main actor.
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor in progress?.append(chunk) }
            }

            let exitStatus: Int32
            do {
                try task.run()
                task.waitUntilExit()
                exitStatus = task.terminationStatus
            } catch {
                exitStatus = -1
                await MainActor.run { progress?.append("\nFailed to launch brew.\n") }
            }
            handle.readabilityHandler = nil

            await MainActor.run { progress?.finish(success: exitStatus == 0) }
        }
    }

    /// Dismisses the brew progress sheet and refreshes the update list.
    public func finishBrewUpgrade() {
        brewProgress = nil
        refresh()
    }
}

/// Observable log + status for an in-flight `brew upgrade`, shown in a sheet.
@MainActor
@Observable
public final class BrewProgress: Identifiable {
    public let id = UUID()
    public let name: String
    public private(set) var log: String = ""
    public private(set) var isRunning = true
    public private(set) var succeeded = false

    public init(name: String) { self.name = name }

    public func append(_ text: String) { log += text }

    public func finish(success: Bool) {
        isRunning = false
        succeeded = success
        log += success ? "\nUpdate complete.\n" : "\nUpdate finished with errors.\n"
    }
}
