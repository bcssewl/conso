import Foundation
import ConsoCore
import FoundationModels

/// Maps the on-device model's availability onto conso's pure enum.
@available(macOS 26, *)
enum DoctorModel {
    static func availability() -> AdvisorAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable(let other): return .unsupported("\(other)")
        }
    }
}

/// The shape the model fills in — a *mirror* of `DoctorReport`, kept separate so the
/// domain type stays portable and we can pin factual fields after generation.
@available(macOS 26, *)
@Generable
struct DoctorReportSchema {
    @Guide(description: "One friendly sentence summarizing overall health. Use only the facts given.")
    var headline: String
    @Guide(description: "Overall status.")
    var status: SchemaStatus
    @Guide(description: "Most important findings first.", .maximumCount(3))
    var findings: [SchemaFinding]
}

@available(macOS 26, *)
@Generable
enum SchemaStatus { case healthy, attention, critical, unknown }

@available(macOS 26, *)
@Generable
struct SchemaFinding {
    @Guide(description: "Short title, e.g. 'Disk almost full'.")
    var title: String
    @Guide(description: "One plain sentence explaining it. Only use the facts provided; never invent numbers.")
    var detail: String
    @Guide(description: "How serious it is.")
    var severity: SchemaSeverity
}

@available(macOS 26, *)
@Generable
enum SchemaSeverity { case info, warn, critical }

/// On-device implementation. Falls back to the deterministic report on ANY error or
/// when the model is unavailable, so callers always get a usable report.
@available(macOS 26, *)
struct FoundationModelsDoctorAdvisor: DoctorAdvising {
    func generateReport(from facts: DoctorFacts) async -> DoctorReport {
        await runGroundedModel(
            instructions: Self.instructions,
            prompt: Self.prompt(for: facts),
            generating: DoctorReportSchema.self,
            map: { schema in
                // Standardized empty-answer guard: a blank headline → deterministic fallback.
                guard !schema.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw EmptyModelAnswer() }
                return Self.map(schema, facts: facts)
            },
            fallback: { DoctorFallback.report(from: facts) })
    }

    /// Trusted developer policy. Untrusted data (process names) NEVER goes here — it
    /// goes only in the prompt — which is conso's prompt-injection defense.
    ///
    /// Kept calm, short and neutral on purpose: tense or alarming phrasing can trip Apple's
    /// on-device safety guardrails ("Safety guardrails were triggered"), which silently
    /// drops us to the deterministic fallback. Calm wording reduces those false positives.
    static let instructions = """
    You are conso's friendly Mac health helper. Explain system health in plain, calm language.
    Rules:
    - Use ONLY the facts in the prompt. Never invent numbers, file names, or app names.
    - Do NOT put specific numbers or percentages in the findings' titles or details — describe
      them qualitatively (e.g. "disk is getting full", not "disk is 86% full"). The score chip
      is the only pinned number; numbers stated in findings can disagree with it.
    - Be concise and reassuring. No marketing language. No emoji.
    - If the facts show no problem, say the Mac is healthy.
    """

    static func prompt(for f: DoctorFacts) -> String {
        // We do NOT inject raw process names verbatim — arbitrary app/binary names (often
        // from untrusted bundles) are a common trigger for the on-device safety filter and
        // add no grounding value here. We generalise to a neutral "the busiest app" count,
        // so the summary stays grounded in the numbers without risking a refusal.
        let busiest: String
        switch f.topProcesses.count {
        case 0:  busiest = "n/a"
        case 1:  busiest = "one app is using the most resources"
        default: busiest = "a few apps are using the most resources"
        }
        return """
        Summarize this Mac's health for its owner.
        Score: \(f.score)/100 (\(f.grade)); \(f.checksPassed)/\(f.checksTotal) checks passed.
        CPU \(f.cpuPercent)%, memory \(f.memoryPercent)%, disk \(f.diskPercent)%, swap \(ByteFormat.string(f.swapBytes)).
        Thermal: \(f.thermal.label). Memory pressure: \(f.pressure.label).
        Activity: \(busiest).
        """
    }

    /// Maps schema → domain, PINNING factual fields to conso's own numbers: the
    /// score and the suggestion target come from facts, never from the model.
    static func map(_ s: DoctorReportSchema, facts f: DoctorFacts) -> DoctorReport {
        let status: DoctorStatus
        switch s.status {
        case .healthy: status = .healthy
        case .attention: status = .attention
        case .critical: status = .critical
        case .unknown: status = .unknown
        }
        let findings = s.findings.map { sf -> Finding in
            let sev: Severity
            switch sf.severity {
            case .info: sev = .info
            case .warn: sev = .warn
            case .critical: sev = .critical
            }
            return Finding(title: sf.title, detail: sf.detail, severity: sev)
        }
        let suggestion: Suggestion?
        if f.diskPercent > 80 {
            suggestion = Suggestion(label: "Open Clean", target: .clean)
        } else if f.thermal == .serious || f.thermal == .critical {
            suggestion = Suggestion(label: "Open Optimize", target: .optimize)
        } else {
            suggestion = nil
        }
        return DoctorReport(headline: s.headline, status: status, score: f.score,
                            findings: findings, suggestion: suggestion, isAIGenerated: true)
    }
}
