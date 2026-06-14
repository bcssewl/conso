import Foundation

/// The deterministic safety verdict shown as a chip. Derived purely from `ExplainFacts`
/// (never from the model): recovery data is its own category so the UI can warn loudest,
/// `caution` covers medium-risk / non-reversible removals, `safe` is the low-risk default.
public enum ExplainVerdict: String, Sendable, Equatable { case safe, caution, recoveryData }

/// The plain-language explanation the "What's this?" popover renders. The deterministic
/// fallback builds it directly; the live model produces a mirror whose `verdict` and
/// factual fields are PINNED from `ExplainFacts` (the model only phrases `summary`).
public struct ExplainReport: Sendable, Equatable {
    public var title: String
    public var summary: String
    public var verdict: ExplainVerdict
    /// The action the item's page performs, so the verdict chip label reads "Safe to
    /// update" / "Safe to run" / "Safe to move to Trash" instead of always "remove".
    public var actionKind: ExplainActionKind
    public var isAIGenerated: Bool

    public init(title: String, summary: String, verdict: ExplainVerdict,
                actionKind: ExplainActionKind = .clean, isAIGenerated: Bool) {
        self.title = title
        self.summary = summary
        self.verdict = verdict
        self.actionKind = actionKind
        self.isAIGenerated = isAIGenerated
    }
}

public extension ExplainVerdict {
    /// The deterministic mapping from grounded facts to a verdict. Recovery data always
    /// wins (it's the user's safety net); otherwise medium-risk or non-reversible items
    /// are caution, and everything else is safe. This is the single source of truth the
    /// fallback AND the live path both use — the model never picks the verdict.
    static func from(_ f: ExplainFacts) -> ExplainVerdict {
        if f.isRecoveryData { return .recoveryData }
        if f.risk == .medium || !f.isReversible { return .caution }
        return .safe
    }

    /// Short label for the chip. Default keeps the historical "remove" framing for
    /// callers that don't pass an action; prefer `label(for:)` so the verb matches the
    /// page (Update / Run / Move to Trash), which is what makes the chip context-aware.
    var label: String { label(for: .clean) }

    /// The chip label phrased for the given action — "Safe to update" on Software,
    /// "Safe to run" on Optimize, "Safe to move to Trash" on Analyze, "Safe to remove"
    /// on Clean. Caution/recovery wording is action-agnostic.
    func label(for action: ExplainActionKind) -> String {
        switch self {
        case .safe: return "Safe to \(action.safeLabelObject)"
        case .caution: return "Review first"
        case .recoveryData: return "Recovery data"
        }
    }
}
