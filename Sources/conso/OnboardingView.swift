import SwiftUI
import AppKit
import UserNotifications
import ConsoCore

// MARK: - First-run onboarding

/// The first-launch setup flow: welcome → what conso does → privacy → permissions
/// (Full Disk Access · admin access · notifications, checked live) → get started.
/// Plain, user-facing language; built from the theme tokens + shared components so it
/// reads correctly across all three themes and light/dark.
struct OnboardingView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Called when the user finishes (or skips to) the end of the flow.
    var onFinish: () -> Void

    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, pillars, privacy, permissions, ready
        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .ready }
    }

    var body: some View {
        let t = theme.tokens(scheme)
        VStack(spacing: 0) {
            // Content (each step scrolls independently if it overflows).
            ScrollView {
                Group {
                    switch step {
                    case .welcome:     WelcomeStep(t: t)
                    case .pillars:     PillarsStep(t: t)
                    case .privacy:     PrivacyStep(t: t)
                    case .permissions: PermissionsStep(t: t)
                    case .ready:       ReadyStep(t: t)
                    }
                }
                .frame(maxWidth: 470)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.vertical, 32)
            }

            footer(t)
        }
        .frame(minWidth: 720, minHeight: 600)
        .background {
            if t.glass {
                VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                    .overlay(t.bg.opacity(0.72))
                    .ignoresSafeArea()
            } else {
                t.bg.ignoresSafeArea()
            }
        }
        .background(WindowConfigurator())
        .preferredColorScheme(theme.preferredScheme)
    }

    // MARK: Footer — stepper + back/next (or Get Started)

    private func footer(_ t: Tokens) -> some View {
        VStack(spacing: 16) {
            Divider().overlay(t.hair)
            HStack {
                // Back stays in place (hidden on the first step) so the layout doesn't jump.
                ConsoButton(t: t, title: "Back", kind: .ghost) { go(-1) }
                    .opacity(step.isFirst ? 0 : 1)
                    .disabled(step.isFirst)

                Spacer()
                StepDots(t: t, steps: Step.allCases.count, current: step.rawValue)
                Spacer()

                if step.isLast {
                    ConsoButton(t: t, title: "Get Started", kind: .primary, action: onFinish)
                } else {
                    ConsoButton(t: t, title: "Continue", kind: .primary) { go(1) }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.22)) { step = next }
    }
}

// MARK: - Progress stepper

private struct StepDots: View {
    let t: Tokens
    var steps: Int
    var current: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<steps, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(t.accent) : AnyShapeStyle(t.hair))
                    .frame(width: i == current ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.22), value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(steps)")
    }
}

// MARK: - Shared header

private struct StepHeader: View {
    let t: Tokens
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(t.text)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(t.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A clean, monochrome-free list glyph: just the symbol in the accent color, no
/// filled tile behind it (the tiled-pastel look reads as generic/AI-made).
private struct RowGlyph: View {
    let t: Tokens
    var symbol: String
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(t.accent)
            .frame(width: 28)
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    let t: Tokens
    var body: some View {
        VStack(spacing: 18) {
            StepHeader(
                t: t,
                title: "Welcome to conso",
                subtitle: "One simple app to clean up space, manage your apps, fix common problems, and keep an eye on how your Mac is doing."
            )
            Text("Everything runs on your Mac. Nothing is ever uploaded.")
                .font(.system(size: 12))
                .foregroundStyle(t.text3)
        }
        .padding(.top, 8)
    }
}

// MARK: - Step 2 · What conso does

private struct PillarsStep: View {
    let t: Tokens
    var body: some View {
        VStack(spacing: 18) {
            StepHeader(
                t: t,
                title: "Five tools, one app",
                subtitle: "conso replaces a drawer full of utilities with five focused tools."
            )
            VStack(spacing: 10) {
                ForEach(PillarInfo.all, id: \.title) { p in
                    PillarRow(t: t, info: p)
                }
            }
        }
    }
}

private struct PillarInfo {
    var symbol: String
    var title: String
    var blurb: String

    static let all: [PillarInfo] = [
        .init(symbol: Pillar.clean.symbol, title: "Clean",
              blurb: "Free up space safely — caches, logs and leftovers, never your own files."),
        .init(symbol: Pillar.software.symbol, title: "Software",
              blurb: "See everything you’ve installed and what has updates, in one place."),
        .init(symbol: Pillar.optimize.symbol, title: "Optimize",
              blurb: "Quick fixes for common slowdowns and glitches."),
        .init(symbol: Pillar.analyze.symbol, title: "Analyze",
              blurb: "See what’s actually taking up space on your disk."),
        .init(symbol: Pillar.status.symbol, title: "Status",
              blurb: "Live CPU, memory, network and temperature at a glance."),
    ]
}

private struct PillarRow: View {
    let t: Tokens
    var info: PillarInfo
    var body: some View {
        HStack(spacing: 13) {
            RowGlyph(t: t, symbol: info.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
                Text(info.blurb)
                    .font(.system(size: 11.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .consoCard(t)
    }
}

// MARK: - Step 3 · Privacy

private struct PrivacyStep: View {
    let t: Tokens
    var body: some View {
        VStack(spacing: 18) {
            StepHeader(
                t: t,
                title: "Private by design",
                subtitle: "conso works entirely on your Mac and always asks before changing anything."
            )
            VStack(spacing: 14) {
                PrivacyRow(t: t, symbol: "wifi.slash", title: "Nothing leaves your Mac",
                           blurb: "No account, no tracking, no uploads. Everything runs right here.")
                PrivacyRow(t: t, symbol: "hand.raised", title: "You’re in control",
                           blurb: "conso asks before it removes or changes anything.")
                PrivacyRow(t: t, symbol: "checkmark.shield", title: "Only safe cleanups",
                           blurb: "It sticks to a strict safe list — your own files are never touched.")
            }
        }
    }
}

private struct PrivacyRow: View {
    let t: Tokens
    var symbol: String
    var title: String
    var blurb: String
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RowGlyph(t: t, symbol: symbol, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                Text(blurb)
                    .font(.system(size: 11.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 4 · Permissions

private struct PermissionsStep: View {
    let t: Tokens
    @Environment(\.openURL) private var openURL

    /// Deep-links (same scheme the Analyze pillar uses for FDA).
    private let fdaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private let notifSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!

    @State private var fdaGranted = DiskScanner.hasFullDiskAccess()
    @State private var helperInstalled = HelperClient.shared.isInstalled
    @State private var helperMsg = ""
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(
                t: t,
                title: "Two quick permissions",
                subtitle: "Grant these once and you’re set. conso checks them each time it opens."
            )

            VStack(spacing: 0) {
                permRow(
                    symbol: "lock.rectangle.stack",
                    title: "Full Disk Access",
                    badgeText: fdaGranted ? "Granted" : "Not granted",
                    badgeStyle: fdaGranted ? .accent : .warm,
                    detail: "Lets conso scan and clean protected folders, like Caches and Application Support.",
                    showDivider: false
                ) {
                    if fdaGranted {
                        grantedChip
                    } else {
                        ConsoButton(t: t, title: "Open Settings", kind: .ghost) { openURL(fdaSettingsURL) }
                    }
                }

                permRow(
                    symbol: "key",
                    title: "Admin access",
                    badgeText: helperInstalled ? "Set up" : "Not set up",
                    badgeStyle: helperInstalled ? .accent : .warm,
                    detail: "Some deep cleanups and fixes need administrator rights. Set it up once with your password — you won’t be asked again.",
                    showDivider: true
                ) {
                    if helperInstalled {
                        grantedChip
                    } else {
                        ConsoButton(t: t, title: "Set up", kind: .ghost, action: installHelper)
                    }
                }

                permRow(
                    symbol: "bell",
                    title: "Notifications",
                    badgeText: notifBadgeText,
                    badgeStyle: notifBadgeStyle,
                    detail: "A heads-up when a cleanup or update finishes.",
                    showDivider: true
                ) {
                    switch notifStatus {
                    case .authorized, .provisional, .ephemeral:
                        grantedChip
                    case .denied:
                        ConsoButton(t: t, title: "Open Settings", kind: .ghost) { openURL(notifSettingsURL) }
                    default:
                        ConsoButton(t: t, title: "Allow", kind: .ghost, action: requestNotifications)
                    }
                }
            }
            .consoCard(t)

            if !helperMsg.isEmpty {
                Text(helperMsg)
                    .font(.system(size: 11)).foregroundStyle(t.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                "conso checks these each time it opens and shows you exactly what to fix.",
                systemImage: "checkmark.circle"
            )
            .font(.system(size: 11.5)).foregroundStyle(t.text3)
            .labelStyle(.titleAndIcon).multilineTextAlignment(.center)

            // First-launch note, plainly worded.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.accent)
                Text("If macOS won’t open conso the first time, go to System Settings ▸ Privacy & Security and click “Open Anyway”.")
                    .font(.system(size: 11.5)).foregroundStyle(t.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .onAppear(perform: recheck)
        // Re-verify when the window regains focus after a trip to System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
    }

    private var notifBadgeText: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Optional"
        }
    }
    private var notifBadgeStyle: BadgeStyle {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return .accent
        default: return .muted
        }
    }

    private var grantedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
            Text("Ready").font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(t.good)
    }

    @ViewBuilder
    private func permRow<Action: View>(
        symbol: String,
        title: String,
        badgeText: String,
        badgeStyle: BadgeStyle,
        detail: String,
        showDivider: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        if showDivider { Divider().overlay(t.hair) }
        HStack(spacing: 13) {
            RowGlyph(t: t, symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
                    Badge(t: t, text: badgeText, style: badgeStyle)
                }
                Text(detail)
                    .font(.system(size: 11.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func recheck() {
        fdaGranted = DiskScanner.hasFullDiskAccess()
        helperInstalled = HelperClient.shared.isInstalled
        Task { @MainActor in await refreshNotifications() }
    }

    private func installHelper() {
        do {
            try HelperClient.shared.install()
            helperMsg = "Asking for permission — approve in System Settings ▸ Login Items if prompted."
        } catch {
            helperMsg = "Couldn’t set it up: \(error.localizedDescription)"
        }
        recheck()
    }

    /// Triggers the real macOS notification permission prompt (local notifications need
    /// no special entitlement for a signed app), then refreshes the row state.
    private func requestNotifications() {
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshNotifications()
        }
    }

    @MainActor
    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifStatus = settings.authorizationStatus
    }
}

// MARK: - Step 5 · Get started

private struct ReadyStep: View {
    let t: Tokens
    var body: some View {
        VStack(spacing: 18) {
            StepHeader(
                t: t,
                title: "You’re all set",
                subtitle: "Open conso any time — from the Dock, or the live monitor in your menu bar."
            )
            VStack(spacing: 14) {
                PrivacyRow(t: t, symbol: "menubar.arrow.up.rectangle", title: "Live in your menu bar",
                           blurb: "A compact monitor shows CPU, memory and network without opening the app.")
                PrivacyRow(t: t, symbol: "slider.horizontal.3", title: "Make it yours",
                           blurb: "Pick a look — three themes to choose from, any time in Settings.")
            }
        }
    }
}
