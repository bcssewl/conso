import Foundation

/// What the "What's this?" explainer is being asked about. Every case maps to a
/// concrete thing conso can already scan or act on — a cleanable category, an update
/// kind, a file the finder surfaced, or a situational Optimize fix — so the explanation
/// is always grounded in real code.
public enum ExplainTarget: Sendable, Equatable {
    case cleanCategory(CleanCategory)
    case updateCategory(UpdateCategory)
    case duplicateFile
    case oldFile
    /// A situational Optimize repair, keyed by its `FixTask.id` (see `OptimizeCatalog`).
    /// Carried as an id (not the whole task) so this enum stays a plain value type.
    case fixTask(id: String)
}

/// How risky acting on the item is. Drives the verdict and the fallback copy.
/// Deterministic — the model never originates it.
public enum ExplainRisk: String, Sendable, Equatable { case low, medium }

/// The ACTION the explainer is framing — what the user actually does on this page. This
/// is what makes the copy context-aware: on Clean you *remove*, on Software you *update*,
/// on Optimize you *run a fix*, on Analyze you *move a file to the Trash*. Without it the
/// explainer wrongly said everything "can be removed" (e.g. on the Software page, where
/// you update, not remove). Deterministic — derived from the target, never the model.
public enum ExplainActionKind: String, Sendable, Equatable {
    case clean    // Clean items — "remove / clean up"
    case update   // Software updates — "update" (NOT remove)
    case fix      // Optimize repairs — "run this fix"
    case trash    // Analyze files — "move to the Trash"

    /// The verb used in prose, e.g. "Removing it is safe", "Updating is safe".
    public var verbGerund: String {
        switch self {
        case .clean:  return "Removing it"
        case .update: return "Updating"
        case .fix:    return "Running this fix"
        case .trash:  return "Moving it to the Trash"
        }
    }

    /// Short label fragment for the "safe" verdict chip, e.g. "Safe to remove".
    public var safeLabelObject: String {
        switch self {
        case .clean:  return "remove"
        case .update: return "update"
        case .fix:    return "run"
        case .trash:  return "move to Trash"
        }
    }
}

/// The grounded, per-item record handed to the explainer. This is the ONLY thing the
/// model sees: a small factual package conso computed from its own safety table. The
/// model rephrases `whatItIs` + the safety fields into friendly prose; it never decides
/// any of these values. Kept tiny to fit the on-device model's ~4k-token budget.
public struct ExplainFacts: Sendable, Equatable {
    /// Human title, e.g. "System Caches" or "Exact duplicate file".
    public var title: String
    /// A short noun for the kind of thing, e.g. "cache", "backup", "CLI library".
    public var kind: String
    /// On-disk size if known (a category total or a file size); nil when not applicable.
    public var sizeBytes: UInt64?
    /// One factual clause describing what the item is. The grounding seed for the model.
    public var whatItIs: String
    /// True when removal moves to the Trash (recoverable); false when it's permanent or
    /// needs special tooling. Updates are not removals — modelled as reversible (you can
    /// reinstall a prior version) only where that's truthful.
    public var isReversible: Bool
    /// True when the item IS the user's recovery/safety data (snapshots, device backups,
    /// mail attachments). These are never selected by default and warrant a stronger note.
    public var isRecoveryData: Bool
    /// True when macOS or the app regenerates the item automatically after removal.
    public var regenerates: Bool
    /// A one-clause note on what regenerates, shown when `regenerates` is true (else nil).
    public var regeneratesNote: String?
    /// Deterministic risk level for acting on the item.
    public var risk: ExplainRisk
    /// The action the user takes on this item's page — so the prose says "Updating is
    /// safe" on Software, not "can be removed". Drives the verb and the verdict label.
    public var actionKind: ExplainActionKind
    /// True when the action needs an admin password (the privileged helper). Only fixes
    /// carry this today; everything else is false. Lets the fix copy mention admin.
    public var needsAdmin: Bool

    public init(title: String, kind: String, sizeBytes: UInt64?, whatItIs: String,
                isReversible: Bool, isRecoveryData: Bool, regenerates: Bool,
                regeneratesNote: String? = nil, risk: ExplainRisk,
                actionKind: ExplainActionKind = .clean, needsAdmin: Bool = false) {
        self.title = title
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.whatItIs = whatItIs
        self.isReversible = isReversible
        self.isRecoveryData = isRecoveryData
        self.regenerates = regenerates
        self.regeneratesNote = regeneratesNote
        self.risk = risk
        self.actionKind = actionKind
        self.needsAdmin = needsAdmin
    }
}
