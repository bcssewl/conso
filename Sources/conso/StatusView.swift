import SwiftUI
import ConsoCore

struct StatusView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(MetricsViewModel.self) private var metrics
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = theme.tokens(scheme)
        let s = metrics.snapshot
        // A real Mac always reports memory + cores; a default snapshot (both 0) means the
        // first sample hasn't landed yet, so show a brief skeleton instead of empty cards.
        let loading = s.memoryTotal == 0 && s.cpuCoreCount == 0
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // TimelineView ticks every second so "Ns ago" counts up live and
                // resets when the 1s sampler updates `lastSampledAt`.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    PillarHeader(t: t, title: "Status",
                                 subtitle: loading ? "starting…"
                                     : "live · 60s window · \(secondsAgo(metrics.lastSampledAt, now: ctx.date))s ago")
                }

                if loading {
                    loadingGrid(t)
                } else {
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            healthHero(t, s).fill().gridCellColumns(2)
                            cpuCard(t, s).fill()
                            gpuCard(t, s).fill()
                        }
                        GridRow {
                            memoryCard(t, s).fill()
                            diskCard(t, s).fill()
                            networkCard(t, s).fill()
                            if let b = metrics.battery { batteryCard(t, b).fill() } else { Color.clear }
                        }
                    }

                    processTable(t)
                }
            }
            .padding(20)
        }
    }

    // MARK: Loading state (before the first sample lands)

    /// Skeleton placeholders mirroring the live grid + process table, so the layout
    /// doesn't jump when the first sample arrives a fraction of a second later.
    private func loadingGrid(_ t: Tokens) -> some View {
        VStack(spacing: 14) {
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    SkeletonCard(t: t, chartHeight: 78).fill().gridCellColumns(2)
                    SkeletonCard(t: t).fill()
                    SkeletonCard(t: t).fill()
                }
                GridRow {
                    SkeletonCard(t: t).fill()
                    SkeletonCard(t: t).fill()
                    SkeletonCard(t: t).fill()
                    SkeletonCard(t: t).fill()
                }
            }
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    if i > 0 { Divider().overlay(t.hair) }
                    HStack(spacing: 12) {
                        SkeletonBlock(t: t, height: 22, width: 22, corner: 6)
                        SkeletonBlock(t: t, height: 13, width: 160)
                        Spacer()
                        SkeletonBlock(t: t, height: 12, width: 54)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
            .consoCard(t)
        }
    }

    // MARK: Health hero

    private func healthHero(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        // One source of truth: the snapshot's pressure (kernel signal, set by the provider)
        // so the Status hero, Doctor, and explainer never disagree.
        let pressure = s.memoryPressure
        let report = Health.evaluate(diskFraction: s.diskFraction, pressure: pressure, thermal: s.thermal,
                                     swapUsed: s.swapUsed, loadAverage: s.loadAverage, coreCount: s.cpuCoreCount)
        let ringColor = report.score >= 95 ? t.good : report.score >= 75 ? t.accent : t.warn
        return Panel(t: t) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text2)
                        clabel("Health", t)
                        // Reflects the ACTUAL checks evaluated by Health (driven by the
                        // report, not a literal) — e.g. "5/5 checks".
                        Badge(t: t, text: "\(report.checksPassed)/\(report.checksTotal) checks",
                              style: report.checksPassed == report.checksTotal ? .muted : .warm)
                        Badge(t: t, text: "\(metrics.host.chip) · \(shortOS(metrics.host.osVersion))", style: .muted)
                    }
                    Text(report.grade).font(.system(size: 22, weight: .semibold)).foregroundStyle(t.text)
                        .padding(.top, 12)
                    Text(report.summary).font(.system(size: 12.5)).foregroundStyle(t.text3).padding(.top, 5)
                    Text("up \(UptimeFormat.string(s.uptime)) · since \(bootDateLabel(s.uptime))")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(t.text3).padding(.top, 14)
                }
                Spacer(minLength: 0)
                ZStack {
                    Ring(fraction: Double(report.score) / 100, color: ringColor, track: t.hair)
                        .frame(width: 104, height: 104)
                    VStack(spacing: 3) {
                        Text("\(report.score)").font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(t.text)
                        Text("SCORE").font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(t.text3)
                    }
                }
            }
        }
    }

    // MARK: Metric cards

    private func cpuCard(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        return metricCard(t, "CPU", symbol: "cpu", badge: tempBadge(s)) {
            percentText(t, s.cpuUsage)
        } sub: {
            "\(s.cpuCoreCount) cores · load \(String(format: "%.2f", s.loadAverage))"
        } chart: {
            BarHistogram(values: Array(metrics.cpuHistory.suffix(22)), color: t.accent).frame(height: 36)
        }
    }

    private func gpuCard(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        // CPU & GPU share one die on Apple Silicon, so the die temp applies here too.
        // Distinct icon (cube.transparent ≈ graphics/3D) so GPU doesn't share the CPU's "cpu" symbol.
        metricCard(t, "GPU", symbol: "cube.transparent", badge: tempBadge(s)) {
            percentText(t, s.gpuUsage)
        } sub: {
            s.gpuCoreCount > 0 ? "\(s.gpuCoreCount) cores" : "Apple GPU"
        } chart: {
            Sparkline(values: Array(metrics.gpuHistory.suffix(40)), color: t.good).frame(height: 36)
        }
    }

    /// Die temperature badge (shared CPU/GPU), falling back to the thermal-state word.
    private func tempBadge(_ s: SystemSnapshot) -> (String, BadgeStyle) {
        s.dieTempC.map { ("\(Int($0.rounded()))°C", $0 >= 80 ? .warm : .muted) }
            ?? (s.thermal.label, s.thermal.isWarm ? .warm : .muted)
    }

    private func percentText(_ t: Tokens, _ fraction: Double) -> Text {
        Text("\(Int((fraction * 100).rounded()))").font(.system(size: 30, weight: .regular).monospacedDigit()).foregroundStyle(t.text)
        + Text("%").font(.system(size: 16, weight: .regular)).foregroundStyle(t.text3)
    }

    private func memoryCard(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        // One source of truth: the snapshot's pressure (kernel signal, set by the provider)
        // so the Status hero, Doctor, and explainer never disagree.
        let pressure = s.memoryPressure
        return metricCard(t, "Memory", symbol: "memorychip", badge: (ByteFormat.string(s.memoryTotal), .muted)) {
            valueWithUnit(t, ByteFormat.string(s.memoryUsed))
        } sub: {
            "pressure \(pressure.label) · \(s.swapUsed == 0 ? "no swap" : "\(ByteFormat.string(s.swapUsed)) swap")"
        } chart: {
            Meter(fraction: s.memoryFraction, color: t.accent, track: t.hair).padding(.top, 8)
        }
    }

    private func diskCard(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        let free = s.diskTotal >= s.diskUsed ? s.diskTotal - s.diskUsed : 0
        return metricCard(t, "Disk", symbol: "internaldrive", badge: (ByteFormat.string(s.diskTotal), .muted)) {
            valueWithUnit(t, ByteFormat.string(s.diskUsed))
        } sub: {
            "\(ByteFormat.string(free)) free · \(Filesystem.displayName())"
        } chart: {
            Meter(fraction: s.diskFraction, color: s.diskFraction > 0.85 ? t.warn : t.accent, track: t.hair).padding(.top, 8)
        }
    }

    private func networkCard(_ t: Tokens, _ s: SystemSnapshot) -> some View {
        let link = NetworkLink.label()
        let offline = link == "Offline"
        // Wired links have no PHY mode, so show a generic globe rather than the Wi-Fi glyph.
        let symbol = offline ? "wifi.slash" : (link.hasPrefix("Wi-Fi") ? "wifi" : "globe")
        return metricCard(t, "Network", symbol: symbol, badge: (link, offline ? .warm : .muted)) {
            offline
                ? Text("Offline").font(.system(size: 21, weight: .regular)).foregroundStyle(t.text3)
                : Text("↓ \(RateFormat.perSecondBits(s.netDown))").font(.system(size: 21, weight: .regular).monospacedDigit()).foregroundStyle(t.text)
        } sub: {
            offline ? "no active connection" : "↑ \(RateFormat.perSecondBits(s.netUp))"
        } chart: {
            AreaSpark(values: metrics.netDownHistory, color: t.accent).frame(height: 36)
        }
    }

    private func batteryCard(_ t: Tokens, _ b: BatteryInfo) -> some View {
        metricCard(t, "Battery", symbol: b.isCharging ? "battery.100.bolt" : "battery.100",
                   badge: b.healthPercent.map { ("\($0)% health", .muted) }) {
            percentText(t, Double(b.percent) / 100)
        } sub: {
            (b.cycleCount.map { "\($0) cycles · " } ?? "") + b.timeLabel
        } chart: {
            HStack(spacing: 6) {
                Circle().fill(b.isCharging ? t.good : t.accent).frame(width: 6, height: 6)
                Text(b.isCharging ? "Charging" : (b.onACPower ? "Plugged in" : "On battery"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(b.isCharging ? t.good : t.text2)
                Spacer()
            }.padding(.top, 10)
        }
    }

    // MARK: Card scaffold

    private func metricCard<Value: View, Chart: View>(
        _ t: Tokens, _ label: String, symbol: String, badge: (String, BadgeStyle)?,
        @ViewBuilder value: () -> Value, sub: () -> String, @ViewBuilder chart: () -> Chart
    ) -> some View {
        Panel(t: t) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text2)
                    clabel(label, t)
                    Spacer()
                    if let badge { Badge(t: t, text: badge.0, style: badge.1) }
                }
                value()
                Text(sub()).font(.system(size: 11.5)).foregroundStyle(t.text3)
                chart()
            }
        }
    }

    private func valueWithUnit(_ t: Tokens, _ formatted: String) -> some View {
        let parts = formatted.split(separator: " ", maxSplits: 1)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.first.map(String.init) ?? formatted)
                .font(.system(size: 26, weight: .regular).monospacedDigit()).foregroundStyle(t.text)
            if parts.count == 2 {
                Text(String(parts[1])).font(.system(size: 14, weight: .regular)).foregroundStyle(t.text3)
            }
        }
    }

    // MARK: Process table

    private func processTable(_ t: Tokens) -> some View {
        let maxCPU = max(metrics.processes.map(\.cpu).max() ?? 1, 1)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 70, alignment: .trailing)
                HStack(spacing: 3) {
                    Text("CPU")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(t.accent)
                }.frame(width: 110, alignment: .trailing)
                Text("MEM").frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .bold)).tracking(0.4).foregroundStyle(t.text3)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(t.hair)

            ForEach(Array(metrics.processes.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Divider().overlay(t.hair) }
                processRow(t, p, maxCPU: maxCPU)
            }
        }
        .consoCard(t)
    }

    private func processRow(_ t: Tokens, _ p: ProcRow, maxCPU: Double) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon = AppIconResolver.forRunningProcess(pid: p.pid) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.accentSoft)
                        .frame(width: 22, height: 22)
                        .overlay(Text(p.name.prefix(1).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(t.accent))
                }
                Text(p.name).font(.system(size: 13)).foregroundStyle(t.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.pid)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(t.text3).frame(width: 70, alignment: .trailing)
            HStack(spacing: 9) {
                Capsule().fill(t.hair).frame(width: 54, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(t.accent).frame(width: 54 * CGFloat(min(1, p.cpu / maxCPU)), height: 5)
                    }
                Text(cpuText(p.cpu)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(t.text2).frame(width: 47, alignment: .trailing)
            }
            .frame(width: 110, alignment: .trailing)
            Text(ByteFormat.string(p.memBytes)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(t.text2).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: Helpers

    /// Whole seconds since the last sample, clamped at 0. Driven by the TimelineView
    /// clock so it ticks up live (1s, 2s…) between refreshes and resets on each sample.
    private func secondsAgo(_ sampledAt: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(sampledAt)))
    }

    private func cpuText(_ c: Double) -> String {
        c >= 10 ? "\(Int(c.rounded()))%" : String(format: "%.1f%%", c)
    }

    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    /// Boot date as "Jun 10", derived from uptime.
    private func bootDateLabel(_ uptime: TimeInterval) -> String {
        Self.monthDay.string(from: Date(timeIntervalSinceNow: -uptime))
    }

    /// "Version 26.3.1 (Build …)" → "26.3.1".
    private func shortOS(_ full: String) -> String {
        let tokens = full.split(separator: " ")
        if let idx = tokens.firstIndex(where: { $0.first?.isNumber == true }) { return String(tokens[idx]) }
        return full
    }
}
