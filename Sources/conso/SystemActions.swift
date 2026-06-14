import SwiftUI
import AppKit

/// Real, safe quick actions for the menu-bar HUD.
@MainActor
@Observable
final class QuickActions {
    let keepAwake = KeepAwakeBox()
    private(set) var hiddenFilesShown = false

    /// Toggles Finder's "show all files" and relaunches Finder.
    func toggleHiddenFiles() {
        hiddenFilesShown.toggle()
        run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", hiddenFilesShown ? "YES" : "NO"])
        run("/usr/bin/killall", ["Finder"])
    }

    func cleanScreen() { CleanOverlay.shared.show(mode: .screen) }
    func cleanKeys() { CleanOverlay.shared.show(mode: .keys) }

    private func run(_ path: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        try? task.run()
    }
}

/// Thin @Observable wrapper around ConsoCore's KeepAwake for the HUD.
import ConsoCore
@MainActor
@Observable
final class KeepAwakeBox {
    private let impl = KeepAwake()
    var isActive: Bool { impl.isActive }
    func toggle() { impl.toggle() }
}

// MARK: - Clean Screen / Clean Keys overlay

/// A full-screen dim overlay for wiping the screen or keyboard. While shown for
/// "keys", it becomes key and swallows keystrokes so you can clean without typing.
/// Always dismissable with the mouse (Done button) — never traps the user.
@MainActor
final class CleanOverlay {
    static let shared = CleanOverlay()
    enum Mode { case screen, keys }
    private var window: NSWindow?

    func show(mode: Mode) {
        hide()
        guard let screen = NSScreen.main else { return }
        let window = KeySwallowWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.swallowsKeys = (mode == .keys)
        window.contentView = NSHostingView(rootView: CleanOverlayView(mode: mode) { [weak self] in self?.hide() })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Borderless window that can become key and (optionally) eat key events.
final class KeySwallowWindow: NSWindow {
    var swallowsKeys = false
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if swallowsKeys { return }            // swallow — wiping keys
        if event.keyCode == 53 { return }      // Esc: ignore (use Done button)
        super.keyDown(with: event)
    }
}

private struct CleanOverlayView: View {
    let mode: CleanOverlay.Mode
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(mode == .screen ? 0.92 : 0.82).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: mode == .screen ? "display" : "keyboard")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.85))
                Text(mode == .screen ? "Clean your screen" : "Keyboard locked — clean your keys")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                Text(mode == .screen
                     ? "Wipe the display safely. Input is unaffected."
                     : "Keystrokes are ignored while this is open.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Button(action: dismiss) {
                    Text("Done").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 9).padding(.horizontal, 26)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
        }
    }
}
