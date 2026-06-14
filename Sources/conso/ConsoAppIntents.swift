import AppIntents
import SwiftUI
import ConsoCore

/// Bridges App Intents (Spotlight / Shortcuts) into the running app. Intents can't reach
/// RootView's @State directly, so they post a pending command id here; RootView observes
/// it and runs the SAME safe effect the in-app command bar uses. The set of ids is the
/// closed `CommandCatalog`, so an intent can only ever trigger a catalog command.
@MainActor
@Observable
final class AppIntentBridge {
    static let shared = AppIntentBridge()
    private init() {}

    /// The command id an intent requested, consumed (set back to nil) by RootView.
    var pendingCommandID: String?

    /// Records an intent's request. Validated against the catalog so a bad id is dropped.
    func request(_ id: String) {
        guard CommandCatalog.command(id: id) != nil else { return }
        pendingCommandID = id
    }
}

// MARK: - Intents (each performs the SAME safe deterministic effect — open/preview/rescan)

/// "Run Doctor" — presents conso's plain-language health check.
struct RunDoctorIntent: AppIntent {
    static let title: LocalizedStringResource = "Run conso Doctor"
    static let description = IntentDescription("Open conso and run a plain-language health check of your Mac.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentBridge.shared.request("run.doctor")
        return .result()
    }
}

/// "Quick Clean" — opens conso's Quick Clean REVIEW (never deletes without confirmation).
struct QuickCleanIntent: AppIntent {
    static let title: LocalizedStringResource = "conso Quick Clean"
    static let description = IntentDescription("Open conso's Quick Clean review. Nothing is removed until you confirm.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentBridge.shared.request("clean.quick")
        return .result()
    }
}

/// "Open Analyze" — disk treemap + duplicate / large-file finder.
struct OpenAnalyzeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open conso Analyze"
    static let description = IntentDescription("Open conso's disk analyzer to see what's using your space.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentBridge.shared.request("analyze.find")
        return .result()
    }
}

/// "Check for Updates" — rescans for app and system updates.
struct CheckUpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Updates in conso"
    static let description = IntentDescription("Open conso's Software page and rescan for app and system updates.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentBridge.shared.request("software.update")
        return .result()
    }
}

// MARK: - Shortcuts provider (surfaces the intents in Spotlight / Shortcuts)

struct ConsoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunDoctorIntent(),
            phrases: ["Run \(.applicationName) Doctor", "Check my Mac's health with \(.applicationName)"],
            shortTitle: "Run Doctor",
            systemImageName: "stethoscope")
        AppShortcut(
            intent: QuickCleanIntent(),
            phrases: ["Quick Clean with \(.applicationName)", "Free up space with \(.applicationName)"],
            shortTitle: "Quick Clean",
            systemImageName: "sparkles")
        AppShortcut(
            intent: OpenAnalyzeIntent(),
            phrases: ["Analyze my disk with \(.applicationName)", "What's using my disk in \(.applicationName)"],
            shortTitle: "Analyze Disk",
            systemImageName: "chart.bar")
        AppShortcut(
            intent: CheckUpdatesIntent(),
            phrases: ["Check for updates in \(.applicationName)"],
            shortTitle: "Check Updates",
            systemImageName: "arrow.down.circle")
    }
}
