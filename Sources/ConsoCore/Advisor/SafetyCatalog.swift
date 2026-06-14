import Foundation

/// The hand-curated, deterministic rules table that maps every explainable target to a
/// truthful `ExplainFacts` record. This is the ground truth the explainer is built on —
/// the model only ever *rephrases* these facts, it never originates them (the heart of
/// conso's grounding contract).
///
/// Every fact here is curated to match conso's actual behaviour:
///  • Clean categories mirror `CleanSafety` (reversible = moves to Trash) and
///    `CleanCatalog` (hidden items = recovery data, default-off).
///  • Update categories mirror `Software.swift` (Homebrew formula = a CLI library).
///  • Duplicate / old files mirror `FileFinder` (Trash candidates, keep-one semantics).
///
/// Pure / `Sendable` so it's exhaustively unit-testable without the model or the disk.
public enum SafetyCatalog {

    /// Looks up the truthful facts for a target. `sizeBytes` (a category total or a file
    /// size) is threaded through so the prose can mention it; the safety verdict never
    /// depends on size.
    public static func facts(for target: ExplainTarget, sizeBytes: UInt64? = nil) -> ExplainFacts {
        switch target {
        case .cleanCategory(let c): return cleanFacts(c, sizeBytes: sizeBytes)
        case .updateCategory(let c): return updateFacts(c, sizeBytes: sizeBytes)
        case .duplicateFile: return duplicateFacts(sizeBytes: sizeBytes)
        case .oldFile: return oldFileFacts(sizeBytes: sizeBytes)
        case .fixTask(let id): return fixFacts(id)
        }
    }

    // MARK: - Clean categories (mirror CleanSafety + CleanCatalog)

    private static func cleanFacts(_ c: CleanCategory, sizeBytes: UInt64?) -> ExplainFacts {
        switch c {
        case .systemCaches:
            return ExplainFacts(
                title: c.displayName, kind: "cache", sizeBytes: sizeBytes,
                whatItIs: "temporary files apps keep to load faster",
                isReversible: true, isRecoveryData: false, regenerates: true,
                regeneratesNote: "apps rebuild them automatically as you use them",
                risk: .low)
        case .developerJunk:
            return ExplainFacts(
                title: c.displayName, kind: "build cache", sizeBytes: sizeBytes,
                whatItIs: "Xcode DerivedData, node_modules and package-manager caches from your projects",
                isReversible: true, isRecoveryData: false, regenerates: true,
                regeneratesNote: "your tools re-create them on the next build or install",
                risk: .low)
        case .browserData:
            return ExplainFacts(
                title: c.displayName, kind: "cache", sizeBytes: sizeBytes,
                whatItIs: "cached pages and temporary browser files — your history, logins and cookies are left untouched",
                isReversible: true, isRecoveryData: false, regenerates: true,
                regeneratesNote: "your browser rebuilds them as you browse",
                risk: .low)
        case .appLeftovers:
            return ExplainFacts(
                title: c.displayName, kind: "leftover files", sizeBytes: sizeBytes,
                whatItIs: "support files and preferences left behind by apps you've already removed",
                isReversible: true, isRecoveryData: false, regenerates: false,
                risk: .medium)
        case .logs:
            return ExplainFacts(
                title: c.displayName, kind: "log files", sizeBytes: sizeBytes,
                whatItIs: "diagnostic, crash and install logs the system and apps write",
                isReversible: true, isRecoveryData: false, regenerates: true,
                regeneratesNote: "the system writes fresh logs as needed",
                risk: .low)
        case .trash:
            return ExplainFacts(
                title: c.displayName, kind: "deleted items", sizeBytes: sizeBytes,
                whatItIs: "items already waiting in the Bin",
                isReversible: false, isRecoveryData: false, regenerates: false,
                risk: .medium)

        // Hidden / recovery-data items — never default-on.
        case .apfsSnapshots:
            return ExplainFacts(
                title: c.displayName, kind: "local backup", sizeBytes: sizeBytes,
                whatItIs: "local Time Machine snapshots macOS keeps so you can roll back recent changes",
                isReversible: false, isRecoveryData: true, regenerates: true,
                regeneratesNote: "macOS already frees this space automatically when the disk gets full",
                risk: .medium)
        case .iosBackups:
            return ExplainFacts(
                title: c.displayName, kind: "device backup", sizeBytes: sizeBytes,
                whatItIs: "full backups of iPhones and iPads you've synced to this Mac",
                isReversible: false, isRecoveryData: true, regenerates: false,
                risk: .medium)
        case .mailAttachments:
            return ExplainFacts(
                title: c.displayName, kind: "downloaded files", sizeBytes: sizeBytes,
                whatItIs: "attachments the Mail app has downloaded from your messages",
                isReversible: false, isRecoveryData: true, regenerates: true,
                regeneratesNote: "Mail can re-download them from the server if needed",
                risk: .medium)
        }
    }

    // MARK: - Update categories (mirror Software.swift)

    private static func updateFacts(_ c: UpdateCategory, sizeBytes: UInt64?) -> ExplainFacts {
        // Updates are framed around UPDATING, never removal: `actionKind == .update` makes
        // the prose say "Updating is safe and reversible via the app/Homebrew" instead of
        // the old, wrong "can be removed".
        switch c {
        case .app:
            return ExplainFacts(
                title: "App update", kind: "app", sizeBytes: sizeBytes,
                whatItIs: "a newer version of an installed app, with the latest fixes and features",
                isReversible: true, isRecoveryData: false, regenerates: false,
                risk: .low, actionKind: .update)
        case .library:
            return ExplainFacts(
                title: "Library update", kind: "CLI library", sizeBytes: sizeBytes,
                whatItIs: "a newer version of a Homebrew command-line tool or library that other software depends on — updating keeps it compatible and patched",
                isReversible: true, isRecoveryData: false, regenerates: false,
                risk: .low, actionKind: .update)
        case .system:
            return ExplainFacts(
                title: "System update", kind: "macOS update", sizeBytes: sizeBytes,
                whatItIs: "a macOS update that installs through Software Update and restarts your Mac",
                isReversible: false, isRecoveryData: false, regenerates: false,
                risk: .medium, actionKind: .update)
        }
    }

    // MARK: - File-finder items (mirror FileFinder)

    private static func duplicateFacts(sizeBytes: UInt64?) -> ExplainFacts {
        // Analyze files move to the Trash (reversible) — `actionKind == .trash`.
        ExplainFacts(
            title: "Exact duplicate", kind: "duplicate file", sizeBytes: sizeBytes,
            whatItIs: "a byte-for-byte identical copy of another file — conso keeps one copy and trashes the rest",
            isReversible: true, isRecoveryData: false, regenerates: false,
            risk: .low, actionKind: .trash)
    }

    private static func oldFileFacts(sizeBytes: UInt64?) -> ExplainFacts {
        ExplainFacts(
            title: "Old & unused file", kind: "unused file", sizeBytes: sizeBytes,
            whatItIs: "a file you haven't opened or changed in over a year",
            isReversible: true, isRecoveryData: false, regenerates: false,
            risk: .medium, actionKind: .trash)
    }

    // MARK: - Optimize fixes (mirror OptimizeCatalog / FixRunner)

    /// Truthful facts for a situational Optimize repair, keyed by `FixTask.id`. Each entry
    /// describes what the fix does, whether it's reversible/safe, and whether it needs an
    /// admin password (root steps routed to the privileged helper). `actionKind == .fix`,
    /// so the prose says "Running this fix is safe…" — never "can be removed". Unknown ids
    /// fall back to a generic, honest fix description rather than crashing.
    private static func fixFacts(_ id: String) -> ExplainFacts {
        func fix(_ title: String, _ kind: String, _ whatItIs: String,
                 reversible: Bool = true, regeneratesNote: String?,
                 risk: ExplainRisk, needsAdmin: Bool) -> ExplainFacts {
            ExplainFacts(
                title: title, kind: kind, sizeBytes: nil, whatItIs: whatItIs,
                isReversible: reversible, isRecoveryData: false,
                regenerates: regeneratesNote != nil, regeneratesNote: regeneratesNote,
                risk: risk, actionKind: .fix, needsAdmin: needsAdmin)
        }
        switch id {
        case "spotlight":
            return fix("Rebuild Spotlight Index", "search index",
                       "wipes and rebuilds the Spotlight search index so search returns fresh results",
                       regeneratesNote: "macOS reindexes your files automatically afterwards, which can take a while",
                       risk: .medium, needsAdmin: true)
        case "dns":
            return fix("Flush DNS Cache", "network cache",
                       "clears the Mac's saved DNS lookups so it asks for fresh addresses",
                       regeneratesNote: "the cache refills automatically as you browse",
                       risk: .low, needsAdmin: true)
        case "quicklook":
            return fix("Rebuild Quick Look", "preview cache",
                       "clears the cache behind spacebar previews so they regenerate correctly",
                       regeneratesNote: "previews rebuild themselves the next time you look at a file",
                       risk: .low, needsAdmin: false)
        case "fonts":
            return fix("Clear Font Caches", "font cache",
                       "clears the font caches so garbled or boxed text renders correctly after a reboot",
                       regeneratesNote: "macOS rebuilds the font caches on the next restart",
                       risk: .medium, needsAdmin: true)
        case "launchservices":
            return fix("Reset Launch Services", "file-association database",
                       "rebuilds the database of which app opens which file, fixing a messy 'Open With' menu",
                       regeneratesNote: "macOS rebuilds the associations from your installed apps",
                       risk: .low, needsAdmin: false)
        case "app-prefs":
            return fix("Reset an App's Preferences", "app settings",
                       "deletes one chosen app's saved preferences so it starts fresh",
                       reversible: false,
                       regeneratesNote: "the app recreates default preferences the next time it launches",
                       risk: .medium, needsAdmin: false)
        case "restart-dock-finder":
            return fix("Restart Dock & Finder", "system UI",
                       "relaunches the Dock and Finder to clear a frozen or glitchy desktop",
                       regeneratesNote: "both relaunch instantly on their own",
                       risk: .low, needsAdmin: false)
        case "icon-cache":
            return fix("Rebuild Icon Cache", "icon cache",
                       "clears the cached app icons so wrong, blank or blurry icons are drawn fresh",
                       regeneratesNote: "macOS regenerates the icons as you use your apps",
                       risk: .low, needsAdmin: false)
        default:
            return fix("Situational fix", "repair",
                       "a targeted repair for a specific symptom on your Mac",
                       regeneratesNote: "the affected items rebuild automatically",
                       risk: .low, needsAdmin: false)
        }
    }
}
