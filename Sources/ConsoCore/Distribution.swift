import Foundation

/// How this copy of conso was signed and distributed. Read from the
/// `ConsoDistributionChannel` Info.plist key (set by the build).
///
/// The privileged helper's XPC connection is validated against a pinned Apple
/// Team ID, so it can only register and run in the **team-signed developer
/// build**. The downloadable, self-signed DMG has no team identity, so the four
/// root-helper features (rebuild Spotlight, flush DNS, clear system font caches,
/// delete APFS snapshots) can't work there — the UI presents them as unavailable
/// instead of offering an install that would fail. Everything else works fully.
public enum DistributionChannel: String, Sendable, CaseIterable {
    /// Team-signed local build (Xcode). Full functionality, helper included.
    case developer
    /// Self-signed downloadable DMG (no Apple account). Root-helper features disabled.
    case selfSigned = "self-signed"

    /// Parses the raw `ConsoDistributionChannel` value. Anything that isn't an
    /// explicit self-signed marker — including a missing value or an unsubstituted
    /// `$(CONSO_DIST_CHANNEL)` build variable — reads as `.developer`, so a local
    /// build always keeps full functionality.
    public static func parse(_ raw: String?) -> DistributionChannel {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "self-signed", "selfsigned": return .selfSigned
        default: return .developer
        }
    }

    /// True only for the developer build, where the team-validated privileged
    /// helper can register and drive root operations.
    public var supportsPrivilegedHelper: Bool { self == .developer }
}
