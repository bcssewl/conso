import Foundation

/// Which Sparkle update track the user follows. Mirrors Trace's dual-feed model:
/// stable users get only released versions; beta users get the rolling pre-release feed
/// (which also contains stable builds, so a beta tester is never stranded behind stable).
public enum UpdateChannel: String, Sendable, CaseIterable {
    case stable
    case beta

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }
}

/// Derives the Sparkle appcast feed URL for a channel.
///
/// conso hosts updates on GitHub Releases, exactly like Trace:
///   - **Stable** → `…/releases/latest/download/appcast.xml` (GitHub's "latest" alias,
///     which skips pre-releases).
///   - **Beta** → `…/releases/download/beta-feed/appcast.xml` (a rolling pre-release
///     whose appcast asset is refreshed on every release).
public enum UpdateFeed {
    private static let stableSuffix = "/releases/latest/download/appcast.xml"
    private static let betaSuffix = "/releases/download/beta-feed/appcast.xml"

    /// The feed URL for `channel`, derived from the app's configured stable feed.
    /// Returns the stable feed unchanged for `.stable`. For `.beta`, rewrites the
    /// GitHub "releases/latest" path to the rolling beta feed; returns nil if the
    /// configured feed isn't that expected GitHub shape (caller stays on stable).
    public static func url(for channel: UpdateChannel, stableFeed: String) -> String? {
        switch channel {
        case .stable:
            return stableFeed
        case .beta:
            guard stableFeed.hasSuffix(stableSuffix) else { return nil }
            return String(stableFeed.dropLast(stableSuffix.count)) + betaSuffix
        }
    }
}
