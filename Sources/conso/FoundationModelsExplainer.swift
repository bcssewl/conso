import Foundation
import ConsoCore
import FoundationModels

/// The shape the model fills in for the "What's this?" explainer. The model only writes
/// `summary`; the verdict and every factual field are PINNED from `ExplainFacts` after
/// generation, so the model can never decide whether an item is safe to remove.
@available(macOS 26, *)
@Generable
struct ExplainSummarySchema {
    @Guide(description: "A friendly 1–2 sentence explanation of what the item is and whether the stated action is safe. Use ONLY the facts given; never invent file names, sizes, or claims.")
    var summary: String
}

/// On-device implementation of `Explaining`. The model only rephrases the grounded
/// `whatItIs`/safety facts into a friendly summary; the verdict and all factual fields
/// come from `ExplainFacts`. Falls back to `ExplainFallback` on ANY error or when the
/// model is unavailable, so callers always get a usable report. Mirrors
/// `FoundationModelsDoctorAdvisor`.
@available(macOS 26, *)
struct FoundationModelsExplainer: Explaining {
    func explain(_ facts: ExplainFacts) async -> ExplainReport {
        await runGroundedModel(
            instructions: Self.instructions,
            prompt: Self.prompt(for: facts),
            generating: ExplainSummarySchema.self,
            map: { schema in
                let summary = schema.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                // Empty → route to the deterministic prose like any other failure.
                guard !summary.isEmpty else { throw EmptyModelAnswer() }
                return Self.map(schema, facts: facts)
            },
            fallback: { ExplainFallback.report(from: facts) })
    }

    /// Trusted developer policy. Untrusted data (item titles / file names) NEVER goes
    /// here — it goes only in the prompt — which is conso's prompt-injection defense.
    ///
    /// Kept short, calm and neutral on purpose: terse "remove / delete / wipe" phrasing
    /// is exactly what trips Apple's on-device safety guardrails ("Safety guardrails were
    /// triggered"), which silently drops us to the deterministic fallback. We describe the
    /// task in everyday maintenance terms and let the per-item action verb (below) carry
    /// the specifics, which reduces false-positive refusals without losing grounding.
    static let instructions = """
    You are conso's maintenance helper. In plain, calm, everyday language, explain what an
    item is and whether the described action is safe and easy to undo.
    Rules:
    - Use ONLY the facts in the prompt. Never invent file names, numbers, or safety claims.
    - Keep it to 1–2 short sentences. Neutral and reassuring. No marketing language. No emoji.
    - If the item is the user's backup or recovery data, gently note it's their safety net
      and best left in place unless they're sure they no longer need it.
    """

    /// Builds the prompt. Item titles (untrusted) appear only here, never in instructions.
    /// We phrase the request around the page's ACTION (update / run / tidy up / move to
    /// Trash) rather than a blunt "remove", so the model both says the right verb AND is
    /// less likely to trip the safety filter on deletion-flavoured wording.
    static func prompt(for f: ExplainFacts) -> String {
        let action: String
        switch f.actionKind {
        case .clean:  action = "tidying this up"
        case .update: action = "updating this"
        case .fix:    action = "running this fix"
        case .trash:  action = "moving this to the Trash"
        }
        var lines = [
            "Briefly explain this Mac maintenance item to its owner.",
            "Title: \(f.title)",
            "Kind: \(f.kind)",
            "What it is: \(f.whatItIs)",
            "Action: \(action).",
            "Easily undone: \(f.isReversible ? "yes" : "no").",
        ]
        if f.isRecoveryData { lines.append("This is the owner's backup / recovery data.") }
        if let bytes = f.sizeBytes, bytes > 0 { lines.append("Size: \(ByteFormat.string(bytes)).") }
        if f.regenerates, let note = f.regeneratesNote { lines.append("Rebuilds itself: \(note).") }
        if f.needsAdmin { lines.append("Needs the owner's admin password.") }
        lines.append("Describe what it is and whether \(action) is safe and easy to undo.")
        return lines.joined(separator: "\n")
    }

    /// Maps schema → domain, PINNING the verdict, action and factual fields to conso's own
    /// facts: the model contributes only the phrased `summary`.
    static func map(_ s: ExplainSummarySchema, facts f: ExplainFacts) -> ExplainReport {
        let summary = s.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the model returned nothing usable, fall back to the deterministic prose.
        guard !summary.isEmpty else { return ExplainFallback.report(from: f) }
        return ExplainReport(title: f.title,
                             summary: summary,
                             verdict: ExplainVerdict.from(f),
                             actionKind: f.actionKind,
                             isAIGenerated: true)
    }
}
