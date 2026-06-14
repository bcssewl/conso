import Foundation

/// Where an update comes from. macOS forbids silent third-party installs, so conso
/// only *detects* updates and routes each to its own installer — the action label
/// encodes that hand-off.
public enum UpdateSource: String, Sendable, CaseIterable, Identifiable {
    case appStore, homebrew, sparkle, electron, system
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appStore: return "App Store"
        case .homebrew: return "Homebrew"
        case .sparkle:  return "Sparkle"
        case .electron: return "Electron"
        case .system:   return "System"
        }
    }

    /// The button conso shows — it never updates third-party apps itself.
    public var actionLabel: String {
        switch self {
        case .appStore: return "Open App Store"
        case .homebrew: return "Update"               // brew can update in place
        case .sparkle:  return "Open App"
        case .electron: return "Open App"
        case .system:   return "Open Software Update"
        }
    }
}

/// What *kind* of thing an update is, so the UI can filter App vs Library vs System.
/// This is a pure, deterministic classification of the update's source/type — no
/// heuristics, no AI. The rule:
///   • **Library** = a Homebrew *formula* (CLI tool / library, e.g. ffmpeg, cmake).
///   • **App** = a Homebrew *cask*, a Mac App Store app, a Sparkle app, an Electron app.
///   • **System** = a macOS / softwareupdate system update.
public enum UpdateCategory: String, Sendable, CaseIterable, Identifiable {
    case app, library, system
    public var id: String { rawValue }

    /// Plural label used in the filter pills ("Apps", "Libraries", "System").
    public var pluralName: String {
        switch self {
        case .app:     return "Apps"
        case .library: return "Libraries"
        case .system:  return "System"
        }
    }
}

/// A detected update for one app, carrying everything the app layer needs to route
/// it to the right installer. `source` decides the button; the routing fields below
/// (`masID`, `bundlePath`, `brewName`) tell the button *where* to go.
public struct AppUpdate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let glyph: String        // single-letter icon stand-in (when no real icon)
    public let fromVersion: String
    public let toVersion: String
    public let bytes: UInt64
    public let source: UpdateSource
    public let daysOutOfDate: Int

    // MARK: Routing payload (set by the detector that found this update)

    /// Mac App Store numeric adam-id, used to deep-link `macappstore://…/id<masID>`.
    public let masID: String?
    /// On-disk `.app` bundle path — used to launch Sparkle/Electron apps so their
    /// own updater runs, and to resolve the real icon.
    public let bundlePath: String?
    /// Homebrew formula/cask token, passed to `brew upgrade <brewName>`.
    public let brewName: String?
    /// True when conso couldn't determine the remote version (e.g. Electron apps,
    /// or App-Store apps detected only by receipt with `mas` absent). The UI says
    /// "update available" rather than inventing a version number.
    public let remoteVersionKnown: Bool
    /// Whether this Homebrew item is a cask (`brew upgrade --cask`) vs a formula.
    public let isCask: Bool

    public init(id: String, name: String, glyph: String, fromVersion: String,
                toVersion: String, bytes: UInt64, source: UpdateSource, daysOutOfDate: Int = 0,
                masID: String? = nil, bundlePath: String? = nil, brewName: String? = nil,
                remoteVersionKnown: Bool = true, isCask: Bool = false) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.bytes = bytes
        self.source = source
        self.daysOutOfDate = daysOutOfDate
        self.masID = masID
        self.bundlePath = bundlePath
        self.brewName = brewName
        self.remoteVersionKnown = remoteVersionKnown
        self.isCask = isCask
    }

    /// Pure, deterministic category derived from `source` (+ brew formula-vs-cask).
    /// A Homebrew *formula* is a CLI tool / library; a Homebrew *cask* installs a GUI
    /// app, so it groups with the other app installers. macOS/softwareupdate is System.
    public var category: UpdateCategory {
        switch source {
        case .system:
            return .system
        case .homebrew:
            // Formula → library (CLI tool); cask → app (GUI app installer).
            return isCask ? .app : .library
        case .appStore, .sparkle, .electron:
            return .app
        }
    }
}

public extension Array where Element == AppUpdate {
    var totalBytes: UInt64 { reduce(0) { $0 + $1.bytes } }
}

/// Sample data for SwiftUI previews and tests only. The live Software page is driven
/// by `SoftwareModel` (real inventory + detectors), not this catalog.
public enum SoftwareCatalog {
    /// The macOS system update, kept separate from app updates (installs + restarts).
    public static func systemUpdate() -> AppUpdate {
        AppUpdate(id: "macos", name: "macOS Update", glyph: "", fromVersion: "Sequoia 15.5",
                  toVersion: "15.6", bytes: 3_100_000_000, source: .system)
    }

    public static func appUpdates() -> [AppUpdate] {
        [
            AppUpdate(id: "xcode", name: "Xcode", glyph: "X", fromVersion: "16.0", toVersion: "16.1",
                      bytes: 1_200_000_000, source: .appStore, daysOutOfDate: 4),
            AppUpdate(id: "vscode", name: "Visual Studio Code", glyph: "V", fromVersion: "1.89", toVersion: "1.90",
                      bytes: 142_000_000, source: .electron, daysOutOfDate: 4),
            AppUpdate(id: "raycast", name: "Raycast", glyph: "R", fromVersion: "1.70", toVersion: "1.71",
                      bytes: 28_000_000, source: .sparkle, daysOutOfDate: 4),
            AppUpdate(id: "figma", name: "Figma", glyph: "F", fromVersion: "124", toVersion: "125",
                      bytes: 96_000_000, source: .sparkle, daysOutOfDate: 4),
            AppUpdate(id: "ffmpeg", name: "ffmpeg", glyph: "f", fromVersion: "6.1", toVersion: "7.0",
                      bytes: 18_000_000, source: .homebrew, daysOutOfDate: 4),
            AppUpdate(id: "slack", name: "Slack", glyph: "S", fromVersion: "4.37", toVersion: "4.38",
                      bytes: 180_000_000, source: .electron, daysOutOfDate: 4),
            AppUpdate(id: "notion", name: "Notion", glyph: "N", fromVersion: "3.9", toVersion: "4.0",
                      bytes: 110_000_000, source: .electron, daysOutOfDate: 4),
        ]
    }

    public static let installedAppCount = 214
    public static let loginItemCount = 12
    public static let slowLoginItemCount = 3
}
