import Foundation

/// Builds a `DoctorReport` from facts with no model involved. This is BOTH the
/// no-AI fallback AND the safety net when generation fails — so the UI always has
/// a usable, truthful report. Thresholds mirror `Health.swift` so the two agree.
public enum DoctorFallback {
    public static func report(from f: DoctorFacts) -> DoctorReport {
        var findings: [Finding] = []
        if f.diskPercent > 90 {
            findings.append(Finding(title: "Disk almost full",
                detail: "Your startup disk is \(f.diskPercent)% full. Clearing caches and large files frees space.",
                severity: .critical))
        } else if f.diskPercent > 80 {
            findings.append(Finding(title: "Disk filling up",
                detail: "Your startup disk is \(f.diskPercent)% full.",
                severity: .warn))
        }
        if f.pressure == .high {
            findings.append(Finding(title: "Memory under pressure",
                detail: "Apps are competing for RAM (\(f.memoryPercent)% used). Quitting unused apps helps.",
                severity: .warn))
        }
        if f.thermal == .serious || f.thermal == .critical {
            findings.append(Finding(title: "Running warm",
                detail: "The system is under thermal pressure — a heavy app may be the cause.",
                severity: .warn))
        }
        if f.swapBytes > 2_000_000_000 {
            findings.append(Finding(title: "Heavy swap use",
                detail: "macOS is paging memory to disk (\(ByteFormat.string(f.swapBytes))).",
                severity: .info))
        }

        let status: DoctorStatus = findings.contains { $0.severity == .critical } ? .critical
            : findings.isEmpty ? .healthy : .attention

        let headline: String
        switch status {
        case .healthy:
            headline = "Your Mac is healthy — all \(f.checksTotal) checks passed."
        case .attention:
            headline = "Your Mac is mostly fine, with \(findings.count) thing\(findings.count == 1 ? "" : "s") worth a look."
        case .critical, .unknown:
            headline = "Your Mac needs attention."
        }

        let suggestion: Suggestion?
        if f.diskPercent > 80 {
            suggestion = Suggestion(label: "Open Clean", target: .clean)
        } else if f.thermal == .serious || f.thermal == .critical {
            suggestion = Suggestion(label: "Open Optimize", target: .optimize)
        } else {
            suggestion = nil
        }

        return DoctorReport(headline: headline, status: status, score: f.score,
                            findings: findings, suggestion: suggestion, isAIGenerated: false)
    }
}
