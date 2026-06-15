import SwiftUI
import AppKit
import ConsoCore

@main
struct ConsoApp: App {
    @State private var theme = ThemeStore()
    @State private var metrics = MetricsViewModel()
    @State private var router = Router()
    @State private var quick = QuickActions()
    @State private var autoClean = AutoCleanScheduler()
    /// The single Sparkle updater, held for the app's lifetime (or scheduled checks stop).
    /// Shared by the Window and the MenuBarExtra via the environment.
    @StateObject private var updater = UpdaterController()

    /// First-run gate: false until the user completes onboarding, then sticky.
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some Scene {
        Window("conso", id: "main") {
            Group {
                if didOnboard {
                    RootView()
                } else {
                    OnboardingView { didOnboard = true }
                }
            }
                .environment(theme)
                .environment(metrics)
                .environment(router)
                .environment(quick)
                .environment(autoClean)
                .environmentObject(updater)
                .onAppear {
                    metrics.start()
                    // Start the optional scheduled auto-clean (off by default; only acts when
                    // the user has enabled it). Runs an on-launch overdue catch-up internally.
                    autoClean.start()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    // Force the Dock icon (bypasses macOS's icon cache for unsigned bundles).
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        NSApp.applicationIconImage = icon
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Standard macOS "Check for Updates…" item, just below "About conso".
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }

        MenuBarExtra("conso", systemImage: "waveform.path.ecg") {
            HUDView()
                .environment(theme)
                .environment(metrics)
                .environment(router)
                .environment(quick)
                .environmentObject(updater)
        }
        .menuBarExtraStyle(.window)
    }
}
