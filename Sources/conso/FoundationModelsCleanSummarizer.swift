import Foundation
import ConsoCore
import FoundationModels

/// The shape the model fills in for the Clean confirmation summary. The model only writes
/// `summary`; every number, category and safety claim is PINNED from `CleanSummaryFacts`,
/// so the model can never decide what is deleted or invent a figure. Mirrors
/// `ExplainSummarySchema`.
@available(macOS 26, *)
@Generable
struct CleanSummarySchema {
    @Guide(description: "A short, calm 1–2 sentence summary of what this clean will free and whether it's reversible. Use ONLY the facts given; never invent file names, sizes, or claims.")
    var summary: String
}

/// On-device implementation of `CleanSummarizing`. The model only rephrases the AGGREGATED
/// facts (per-category totals, the few biggest items, total size/count, reversibility) into
/// a friendly paragraph; it never sees the raw target list. Falls back to
/// `CleanSummaryFallback` on ANY error or when the model is unavailable, so the sheet always
/// has a usable summary. Mirrors `FoundationModelsExplainer`.
@available(macOS 26, *)
struct FoundationModelsCleanSummarizer: CleanSummarizing {
    func summarize(_ facts: CleanSummaryFacts) async -> CleanSummaryReport {
        // Nothing to summarize → the deterministic line, no model call.
        guard facts.totalCount > 0 else { return CleanSummaryFallback.report(from: facts) }
        return await runGroundedModel(
            instructions: Self.instructions,
            prompt: Self.prompt(for: facts),
            generating: CleanSummarySchema.self,
            map: { schema in
                let text = schema.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw EmptyModelAnswer() }
                return CleanSummaryReport(summary: text, isAIGenerated: true)
            },
            fallback: { CleanSummaryFallback.report(from: facts) })
    }

    /// Trusted developer policy. Untrusted data (item / category names) NEVER goes here — it
    /// goes only in the prompt — which is conso's prompt-injection defense.
    ///
    /// Calm, neutral wording on purpose: blunt "delete / wipe" phrasing trips Apple's
    /// on-device safety guardrails ("Safety guardrails were triggered"), which silently drops
    /// us to the deterministic fallback. We frame it as tidying up and let the facts carry
    /// the specifics, which reduces false-positive refusals without losing grounding.
    static let instructions = """
    You are conso's maintenance helper. In plain, calm, everyday language, summarize what a
    cleanup will free up and whether it can be undone.
    Rules:
    - Use ONLY the facts in the prompt. Never invent file names, numbers, or safety claims.
    - Keep it to 1–2 short sentences. Neutral and reassuring. No marketing language. No emoji.
    - If some of it is the owner's backup or recovery data, gently note it's their safety net
      and best reviewed before continuing.
    """

    /// Builds the prompt from the AGGREGATED facts only — per-category totals, the few
    /// biggest items, the overall size/count and the safety verdict. The raw target list is
    /// never sent (it would blow the token budget and trip the guardrails). Category / item
    /// names (untrusted) appear only here, never in instructions.
    static func prompt(for f: CleanSummaryFacts) -> String {
        var lines = [
            "Summarize this Mac cleanup for its owner.",
            "It is a \(f.isQuickClean ? "Quick Clean (a conservative sweep)" : "reviewed clean").",
            "Total: \(ByteFormat.string(f.totalBytes)) across \(f.totalCount) item\(f.totalCount == 1 ? "" : "s").",
        ]
        if !f.categories.isEmpty {
            let cats = f.categories
                .map { "- \($0.category.displayName): \(ByteFormat.string($0.bytes)) (\($0.count) item\($0.count == 1 ? "" : "s"))" }
                .joined(separator: "\n")
            lines.append("By category, largest first:")
            lines.append(cats)
        }
        if !f.topItems.isEmpty {
            let items = f.topItems
                .map { "- \($0.name): \(ByteFormat.string($0.bytes))" }
                .joined(separator: "\n")
            lines.append("Biggest individual items:")
            lines.append(items)
        }
        lines.append("Everything reversible (moves to the Trash): \(f.isFullyReversible ? "yes" : "no").")
        if f.includesRecoveryData {
            lines.append("Some of this is the owner's backup / recovery data.")
        }
        lines.append("In 1–2 calm sentences, say roughly how much it frees, what most of it is, and whether it's reversible.")
        return lines.joined(separator: "\n")
    }
}
