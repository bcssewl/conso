import SwiftUI

enum ThemeKind: String, CaseIterable, Identifiable {
    case modernNative = "Modern Native"
    case proDark = "Pro Dark"
    case character = "Character"
    var id: String { rawValue }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system = "Auto", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

struct Tokens {
    var bg: Color
    var card: Color
    var cardBorder: Color
    var accent: Color
    var accentSoft: Color
    var accentOn: Color   // contrasting content drawn on top of an accent fill
    var text: Color
    var text2: Color
    var text3: Color
    var hair: Color
    var good: Color
    var warn: Color
    var navBG: Color
    var navActive: Color
    var navActiveText: Color
    var glass: Bool        // translucent material surfaces vs solid fills
    var corner: CGFloat
    var cornerLarge: CGFloat
}

@MainActor
@Observable
final class ThemeStore {
    var kind: ThemeKind = .modernNative
    var appearance: Appearance = .system

    /// Forced color scheme: Pro Dark is dark-only; otherwise honour the appearance
    /// override (nil = follow the system).
    var preferredScheme: ColorScheme? {
        if kind == .proDark { return .dark }
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Pro Dark is dark-only; the others follow the system appearance.
    func tokens(_ scheme: ColorScheme) -> Tokens {
        switch kind {
        case .proDark:
            return Tokens(
                bg: Color(hex: 0x000000), card: Color(hex: 0x0A0A0A), cardBorder: Color(hex: 0x1F1F1F),
                accent: Color(hex: 0xFFFFFF), accentSoft: Color.white.opacity(0.10), accentOn: Color(hex: 0x000000),
                text: Color(hex: 0xEDEDED), text2: Color(hex: 0xA1A1A1), text3: Color(hex: 0x8A8A8A),
                hair: Color(hex: 0x1C1C1C), good: Color(hex: 0x30A46C), warn: Color(hex: 0xD4A017),
                navBG: Color(hex: 0x0E0E0E), navActive: Color(hex: 0xFFFFFF), navActiveText: Color(hex: 0x000000),
                glass: false, corner: 7, cornerLarge: 10)
        case .modernNative:
            if scheme == .dark {
                return Tokens(
                    bg: Color(hex: 0x161618), card: Color(hex: 0x2C2C2E), cardBorder: Color.white.opacity(0.09),
                    accent: Color(hex: 0x0A84FF), accentSoft: Color(hex: 0x0A84FF).opacity(0.20), accentOn: Color(hex: 0xFFFFFF),
                    text: Color(hex: 0xF5F5F7), text2: Color(hex: 0xAEAEB4), text3: Color(hex: 0x8A8A92),
                    hair: Color.white.opacity(0.10), good: Color(hex: 0x30D158), warn: Color(hex: 0xFFD60A),
                    navBG: Color.white.opacity(0.08), navActive: Color(hex: 0x3A3A3C), navActiveText: Color(hex: 0xFFFFFF),
                    glass: true, corner: 13, cornerLarge: 18)
            }
            return Tokens(
                bg: Color(hex: 0xE9EAEE), card: Color(hex: 0xFFFFFF), cardBorder: Color.black.opacity(0.065),
                accent: Color(hex: 0x007AFF), accentSoft: Color(hex: 0x007AFF).opacity(0.12), accentOn: Color(hex: 0xFFFFFF),
                text: Color(hex: 0x1D1D1F), text2: Color(hex: 0x5F5F66), text3: Color(hex: 0x71717A),
                hair: Color.black.opacity(0.075), good: Color(hex: 0x1AA251), warn: Color(hex: 0xBF8400),
                navBG: Color.black.opacity(0.05), navActive: Color(hex: 0xFFFFFF), navActiveText: Color(hex: 0x1D1D1F),
                glass: true, corner: 13, cornerLarge: 18)
        case .character:
            if scheme == .dark {
                return Tokens(
                    bg: Color(hex: 0x1A1613), card: Color(hex: 0x38302C), cardBorder: Color(hex: 0xFFA078).opacity(0.12),
                    accent: Color(hex: 0xFF7A52), accentSoft: Color(hex: 0xFF7A52).opacity(0.20), accentOn: Color(hex: 0xFFFFFF),
                    text: Color(hex: 0xF6ECE6), text2: Color(hex: 0xBCAAA0), text3: Color(hex: 0x9A8A82),
                    hair: Color(hex: 0xFFD2B4).opacity(0.10), good: Color(hex: 0x34D18A), warn: Color(hex: 0xFFC24D),
                    navBG: Color(hex: 0xFFD2B4).opacity(0.10), navActive: Color(hex: 0x4A3F3A), navActiveText: Color(hex: 0xF6ECE6),
                    glass: true, corner: 19, cornerLarge: 24)
            }
            return Tokens(
                bg: Color(hex: 0xEFEAE5), card: Color(hex: 0xFFFFFF), cardBorder: Color(hex: 0xBE785A).opacity(0.13),
                accent: Color(hex: 0xFF6A3D), accentSoft: Color(hex: 0xFF6A3D).opacity(0.13), accentOn: Color(hex: 0xFFFFFF),
                text: Color(hex: 0x2A2230), text2: Color(hex: 0x6C6270), text3: Color(hex: 0x8A7D86),
                hair: Color(hex: 0x785A3C).opacity(0.10), good: Color(hex: 0x16A36B), warn: Color(hex: 0xE08600),
                navBG: Color(hex: 0x965A3C).opacity(0.08), navActive: Color(hex: 0xFFFFFF), navActiveText: Color(hex: 0x2A2230),
                glass: true, corner: 19, cornerLarge: 24)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
