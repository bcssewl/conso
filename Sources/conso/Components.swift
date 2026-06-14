import SwiftUI
import ConsoCore

extension View {
    /// Stretch to fill both axes — used for equal-size grid cells.
    func fill() -> some View { frame(maxWidth: .infinity, maxHeight: .infinity) }
}

/// The conso logo mark, which changes with the selected theme.
struct ThemeLogo: View {
    let kind: ThemeKind
    var body: some View {
        Group {
            if let mark = ThemeAssets.mark(for: kind) {
                Image(nsImage: mark).resizable().interpolation(.high)
            } else if let app = AppIconResolver.consoMark {
                Image(nsImage: app).resizable().interpolation(.high)
            } else {
                Image(systemName: "waveform.path.ecg").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Page header (.phead)

struct PillarHeader: View {
    let t: Tokens
    var title: String
    var subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 23, weight: .medium)).foregroundStyle(t.text)
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(t.text3)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Summary stat strip (.statrow / .stat)

struct StatCell: View {
    let t: Tokens
    var symbol: String
    var key: String
    var value: String
    var valueSuffix: String = ""
    var detail: String
    var body: some View {
        Panel(t: t) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text3)
                    Text(key).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(t.text3)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(t.text)
                    if !valueSuffix.isEmpty {
                        Text(valueSuffix).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text3)
                    }
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(t.text3)
            }
        }
    }
}

// MARK: - Source / status badge (.cbadge)

enum BadgeStyle { case neutral, muted, warm, accent }

struct Badge: View {
    let t: Tokens
    var text: String
    var style: BadgeStyle = .neutral
    var body: some View {
        let (fg, bg): (Color, Color) = {
            switch style {
            case .neutral: return (t.text2, t.hair)
            case .muted:   return (t.text3, t.hair.opacity(0.6))
            case .warm:    return (t.warn, t.warn.opacity(0.16))
            case .accent:  return (t.accent, t.accentSoft)
            }
        }()
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(bg, in: Capsule())
            .fixedSize()
    }
}

// MARK: - Segmented pills (matches the top-bar glass nav pill)

/// A segmented control styled like the nav pill: a glass/material capsule holding
/// content-hugging pills, the active one filled with `navActive`.
struct SegmentedPills<T: Identifiable & Equatable>: View {
    let t: Tokens
    let options: [T]
    @Binding var selection: T
    var label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                let active = opt == selection
                Button { selection = opt } label: {
                    Text(label(opt))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(active ? t.navActiveText : t.text2)
                        .padding(.vertical, 6).padding(.horizontal, 13)
                        .background(active ? AnyShapeStyle(t.navActive) : AnyShapeStyle(Color.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(t.glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(t.navBG), in: Capsule())
        .overlay(Capsule().strokeBorder(t.cardBorder, lineWidth: t.glass ? 1 : 0))
        .fixedSize()
    }
}

// MARK: - Checkbox toggle (.check)

struct CheckToggle: View {
    let t: Tokens
    var isOn: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isOn ? AnyShapeStyle(t.accent) : AnyShapeStyle(Color.clear))
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : t.cardBorder, lineWidth: 1.5)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(t.accentOn)
                }
            }
    }
}

// MARK: - Buttons

struct ConsoButton: View {
    let t: Tokens
    var title: String
    var kind: Kind = .primary
    var large: Bool = false
    var action: () -> Void = {}
    enum Kind { case primary, ghost }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: large ? 14 : 12.5, weight: .semibold))
                .foregroundStyle(kind == .primary ? t.accentOn : t.text)
                .padding(.vertical, large ? 10 : 7)
                .padding(.horizontal, large ? 20 : 14)
                .background(
                    kind == .primary ? AnyShapeStyle(t.accent) : AnyShapeStyle(t.hair),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section card with header + footer (.catpanel / .uppanel family)

struct SectionCard<Header: View, Content: View, Footer: View>: View {
    let t: Tokens
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(t.hair)
            content
            Divider().overlay(t.hair)
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .consoCard(t)
    }
}

/// Small uppercase section title used in card headers.
struct CardTitle: View {
    let t: Tokens
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .semibold)).tracking(0.4)
            .foregroundStyle(t.text2)
    }
}

// MARK: - Segmented ring (Clean hero — composition of reclaimable categories)

struct SegmentRing: View {
    var values: [Double]      // raw weights, drawn in order with fading opacity
    var color: Color
    var track: Color
    var lineWidth: CGFloat = 18
    var gap: Double = 0.006   // fraction of the circle left blank between segments

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            ForEach(Array(offsets.enumerated()), id: \.offset) { i, seg in
                Circle()
                    .trim(from: seg.start, to: seg.end)
                    .stroke(color.opacity(opacity(for: i)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }

    /// Start/end trim positions (0...1) for each weighted segment, with a small gap between.
    private var offsets: [(start: CGFloat, end: CGFloat)] {
        let total = max(values.reduce(0, +), 0.0001)
        var cursor = 0.0
        return values.map { v in
            let frac = v / total
            let start = cursor + gap / 2
            let end = cursor + frac - gap / 2
            cursor += frac
            return (CGFloat(max(start, 0)), CGFloat(max(end, start)))
        }
    }

    private func opacity(for i: Int) -> Double {
        max(0.28, 1.0 - Double(i) * 0.14)
    }
}

// MARK: - Skeleton (loading shimmer)

/// A rounded placeholder block that shimmers while content loads. Theme-token-driven
/// (fills with `hair`, sweeps a faint highlight across) so it reads as a momentary
/// loading state, not a permanent element. Reused by Status / Clean / Optimize.
struct SkeletonBlock: View {
    let t: Tokens
    var height: CGFloat = 14
    var width: CGFloat? = nil
    var corner: CGFloat = 6
    @State private var phase: CGFloat = -1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
            .fill(t.hair)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                GeometryReader { g in
                    shape.fill(
                        LinearGradient(colors: [.clear, t.text3.opacity(0.18), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: g.size.width * 0.5)
                    .offset(x: phase * g.size.width * 1.5)
                }
            }
            .clipShape(shape)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

/// A loading placeholder shaped like a metric/list card: a couple of short label lines,
/// a big value bar, and a chart-height block. Used to keep the layout stable while the
/// first sample/scan lands.
struct SkeletonCard: View {
    let t: Tokens
    var chartHeight: CGFloat = 36
    var body: some View {
        Panel(t: t) {
            VStack(alignment: .leading, spacing: 9) {
                SkeletonBlock(t: t, height: 11, width: 84)
                SkeletonBlock(t: t, height: 26, width: 110)
                SkeletonBlock(t: t, height: 11, width: 140)
                SkeletonBlock(t: t, height: chartHeight, corner: 7).padding(.top, 2)
            }
        }
    }
}

// MARK: - Empty state

/// A compact, centered "nothing here" panel: an icon chip, a title, and a short message.
/// Subtle and momentary — no large illustrations. Used for "All clean" and "Nothing to
/// fix" style states across the pillars.
struct EmptyState: View {
    let t: Tokens
    var icon: String
    var title: String
    var message: String
    var tint: Color? = nil

    var body: some View {
        let color = tint ?? t.good
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.opacity(0.14))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(color))
            VStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(t.text)
                Text(message).font(.system(size: 12.5)).foregroundStyle(t.text3)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36).padding(.horizontal, 20)
        .consoCard(t)
    }
}

// MARK: - Bar histogram (CPU card)

struct BarHistogram: View {
    var values: [Double]   // each 0...1
    var color: Color
    var body: some View {
        GeometryReader { g in
            let n = max(values.count, 1)
            let spacing: CGFloat = 3
            let barW = max(1, (g.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(0.92))
                        .frame(width: barW, height: max(3, g.size.height * CGFloat(max(0, min(1, v)))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Filled area chart (Network card)

struct AreaSpark: View {
    var values: [Double]   // raw; normalized to the local max
    var color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, 0.0001)
            let pts: [CGPoint] = values.count > 1 ? values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(i) / CGFloat(values.count - 1),
                        y: h * (1 - CGFloat(max(0, min(1, v / maxV)))))
            } : []
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.13))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Labeled progress bar (Analyze largest-folders)

struct BarRow: View {
    let t: Tokens
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(t.hair)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 5)
    }
}
