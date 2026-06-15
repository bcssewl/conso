import Foundation
import Combine
import os
import SwiftUI
import Sparkle
import ConsoCore

/// The build's distribution channel, read once from Info.plist (`ConsoDistributionChannel`).
/// `.developer` for team-signed local builds, `.selfSigned` for the downloadable DMG.
enum AppDistribution {
    static let channel = DistributionChannel.parse(
        Bundle.main.object(forInfoDictionaryKey: "ConsoDistributionChannel") as? String)

    /// The privileged helper validates a pinned Apple Team ID, so it only works in the
    /// team-signed developer build. Self-signed DMGs disable the four root features.
    static var supportsPrivilegedHelper: Bool { channel.supportsPrivilegedHelper }
}

/// Vends the active appcast feed URL to Sparkle for the chosen channel. Sparkle may query
/// this off the main actor, so the resolved URL is held behind a lock and refreshed (from
/// the main actor) whenever the channel changes. Returning nil falls back to Info.plist's
/// `SUFeedURL` (the stable feed).
nonisolated final class UpdaterFeedDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    private let feed = OSAllocatedUnfairLock<String?>(initialState: nil)
    func setFeed(_ url: String?) { feed.withLock { $0 = url } }
    func feedURLString(for updater: SPUUpdater) -> String? { feed.withLock { $0 } }
}

/// Owns the single Sparkle updater for the app's lifetime. Created once in `ConsoApp` and
/// injected into the environment so the Window and the MenuBarExtra share one instance
/// (Sparkle requires the controller to outlive the app, or scheduled checks stop).
///
/// Auto-check + the 24h interval come from Info.plist; the user can override auto-check and
/// pick the Stable/Beta channel in Settings (persisted in UserDefaults). Stable/Beta is the
/// dual-feed model: Stable reads `releases/latest`, Beta the rolling `beta-feed` release.
@MainActor
final class UpdaterController: ObservableObject {
    static let channelKey = "com.conso.updates.channel"

    private let feedDelegate = UpdaterFeedDelegate()
    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    /// The configured stable feed (Info.plist `SUFeedURL`).
    let stableFeed: String

    /// Drives the "Check for Updates…" menu item's enabled state.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's automatic-update-check setting.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// The update track the user follows. Persisted; applied to the feed delegate.
    @Published var channel: UpdateChannel {
        didSet { applyChannel() }
    }

    init() {
        stableFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: Self.channelKey) ?? "") ?? .stable
        // Placeholder until the real updater exists (didSet does not fire during init).
        automaticallyChecksForUpdates = true
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: feedDelegate, userDriverDelegate: nil)

        // Seed the feed from the saved channel BEFORE starting, then start the updater.
        feedDelegate.setFeed(UpdateFeed.url(for: channel, stableFeed: stableFeed))
        controller.startUpdater()
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        // Keep the menu item's enabled state in sync with the updater.
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    private func applyChannel() {
        UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey)
        feedDelegate.setFeed(UpdateFeed.url(for: channel, stableFeed: stableFeed))
    }

    /// Shows Sparkle's standard "checking / update available / up to date" UI.
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// The "Check for Updates…" menu command (app menu, after the About item). Disabled while
/// Sparkle is mid-check so the user can't stack requests.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterController
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
