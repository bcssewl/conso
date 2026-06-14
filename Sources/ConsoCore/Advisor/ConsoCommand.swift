import Foundation

/// The deterministic effect a command performs. EVERY case is SAFE: it either
/// navigates, opens a sheet, opens a *preview* (never deletes), rescans, or toggles a
/// non-destructive helper. The app layer maps these onto Router / Doctor sheet /
/// QuickActions / pillar models — the model and the matcher only ever *choose* one of
/// these; they can never describe an action that isn't in this closed set.
public enum ConsoCommandTarget: Equatable, Sendable {
    /// Switch to a pillar (no side effect beyond navigation).
    case navigate(Pillar)
    /// Present the Doctor health sheet.
    case runDoctor
    /// Go to Clean and open the Quick Clean *preview* (proposes — never deletes).
    case quickClean
    /// Go to Software and rescan for updates.
    case checkUpdates
    /// Go to Analyze (treemap / file finder — "what's using my disk", duplicates).
    case openAnalyze
    /// Toggle Keep Awake (safe, fully reversible, non-destructive).
    case toggleKeepAwake

    /// Which pillar (if any) this target lives in, so the matcher's metadata stays
    /// in one place and the app layer can reuse it for navigation.
    public var pillar: Pillar? {
        switch self {
        case .navigate(let p): return p
        case .quickClean: return .clean
        case .checkUpdates: return .software
        case .openAnalyze: return .analyze
        case .runDoctor, .toggleKeepAwake: return nil
        }
    }
}

/// The five maintenance pillars, mirrored from the app's `Pillar` so ConsoCore can own
/// the navigation targets without a SwiftUI dependency. The app maps these 1:1.
public enum Pillar: String, CaseIterable, Sendable, Equatable {
    case clean, software, optimize, analyze, status
}

/// One entry in conso's FIXED, closed command allowlist. The on-device model is only
/// ever allowed to pick one of these by `id`; it can never originate a new command or a
/// new effect. Each command carries display text + the keywords the deterministic
/// matcher (and the model's grounding prompt) use.
public struct ConsoCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    public let target: ConsoCommandTarget

    public init(id: String, title: String, subtitle: String, keywords: [String], target: ConsoCommandTarget) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.target = target
    }
}

/// The fixed command set. Defining it once, here, means the matcher, the model
/// validator, and the UI all share exactly the same closed allowlist — nothing the
/// model emits can fall outside `CommandCatalog.all`.
public enum CommandCatalog {
    public static let all: [ConsoCommand] = [
        // Navigation
        ConsoCommand(
            id: "open.clean",
            title: "Open Clean",
            subtitle: "Caches, logs, and junk you can safely reclaim",
            keywords: ["clean", "cleanup", "junk", "cache", "caches", "logs", "trash", "remove files"],
            target: .navigate(.clean)),
        ConsoCommand(
            id: "open.software",
            title: "Open Software",
            subtitle: "Installed apps, updates, and login items",
            keywords: ["software", "apps", "applications", "installed", "login items"],
            target: .navigate(.software)),
        ConsoCommand(
            id: "open.optimize",
            title: "Open Optimize",
            subtitle: "Fix common problems and tune your Mac",
            keywords: ["optimize", "optimise", "fix", "tune", "speed up", "repair", "slow"],
            target: .navigate(.optimize)),
        ConsoCommand(
            id: "open.analyze",
            title: "Open Analyze",
            subtitle: "Disk treemap and the duplicate / large-file finder",
            keywords: ["analyze", "analyse", "disk map", "treemap", "explore disk"],
            target: .openAnalyze),
        ConsoCommand(
            id: "open.status",
            title: "Open Status",
            subtitle: "Live CPU, memory, GPU, and temperature",
            keywords: ["status", "metrics", "monitor", "cpu", "memory", "gpu", "temperature", "live"],
            target: .navigate(.status)),

        // Doctor
        ConsoCommand(
            id: "run.doctor",
            title: "Run Doctor",
            subtitle: "A plain-language health check of your Mac",
            keywords: ["doctor", "health", "checkup", "check up", "diagnose", "diagnostics", "how is my mac", "is my mac ok"],
            target: .runDoctor),

        // Quick Clean / Free up space → PREVIEW only
        ConsoCommand(
            id: "clean.quick",
            title: "Free up space",
            subtitle: "Open Quick Clean — review before anything is removed",
            keywords: ["free up space", "free space", "quick clean", "reclaim", "make space", "disk space", "more space", "low on space", "running out of space"],
            target: .quickClean),

        // Check for updates
        ConsoCommand(
            id: "software.update",
            title: "Check for updates",
            subtitle: "Rescan for app and system updates",
            keywords: ["check for updates", "updates", "update", "upgrade apps", "outdated", "new versions"],
            target: .checkUpdates),

        // Find duplicates / what's using my disk
        ConsoCommand(
            id: "analyze.find",
            title: "Find duplicates",
            subtitle: "See what's using your disk and find duplicate files",
            keywords: ["find duplicates", "duplicates", "duplicate files", "what's using my disk", "whats using my disk", "what is using my disk", "large files", "biggest files", "disk usage", "where did my space go"],
            target: .openAnalyze),

        // Keep Awake (safe toggle)
        ConsoCommand(
            id: "keepawake.toggle",
            title: "Keep my Mac awake",
            subtitle: "Toggle Keep Awake — prevents sleep (reversible)",
            keywords: ["keep awake", "keep my mac awake", "stay awake", "prevent sleep", "don't sleep", "no sleep", "caffeinate", "insomnia"],
            target: .toggleKeepAwake),
    ]

    /// Looks a command up by its exact id. The model validator uses this to REJECT any
    /// id that isn't in the closed set, so out-of-catalog output is impossible.
    public static func command(id: String) -> ConsoCommand? {
        all.first { $0.id == id }
    }

    /// All valid command ids — handed to the model's prompt so it can only choose from
    /// this list, and used to validate whatever it returns.
    public static var ids: [String] { all.map(\.id) }
}
