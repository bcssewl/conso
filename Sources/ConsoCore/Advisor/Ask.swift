import Foundation

/// A grounded answer to a natural-language question typed into the "Ask conso" bar.
///
/// This is the value the bar shows after the user presses Enter: a short plain-language
/// `answer` (grounded ONLY in real `DoctorFacts` / the closed command catalog) plus up to
/// a couple of one-tap actions to offer. Every suggested id is GUARANTEED to exist in
/// `CommandCatalog` — `init` drops any id that doesn't, so the UI can render the actions
/// without re-checking. The model can never smuggle in an action outside the closed set.
public struct ConsoAnswer: Equatable, Sendable {
    /// The plain-language reply shown to the user. For in-scope questions this is a
    /// 1–3 sentence grounded answer; for out-of-scope ones it's a short polite decline.
    public let answer: String
    /// Up to a few catalog command ids to offer as one-tap actions. ALWAYS validated to
    /// exist in `CommandCatalog` (unknown ids are dropped at init), and never executed
    /// here — the app runs one only when the user taps it.
    public let suggestedCommandIDs: [String]
    /// Whether the question is about this Mac's health or conso's tools. When false the
    /// UI shows the polite decline plus a couple of example commands.
    public let inScope: Bool
    /// True when the on-device model produced the answer; false for the deterministic
    /// keyword fallback (the UI shows a subtle "Basic" hint in that case).
    public let isAIGenerated: Bool

    /// Builds an answer, VALIDATING every suggested id against `CommandCatalog` and
    /// dropping any that isn't a real command. Duplicates are removed (first wins).
    public init(answer: String, suggestedCommandIDs: [String], inScope: Bool, isAIGenerated: Bool) {
        self.answer = answer
        var seen = Set<String>()
        self.suggestedCommandIDs = suggestedCommandIDs.filter { id in
            guard CommandCatalog.command(id: id) != nil, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        self.inScope = inScope
        self.isAIGenerated = isAIGenerated
    }

    /// The resolved commands for `suggestedCommandIDs`, in order — a convenience for the
    /// UI so it can render action buttons without re-looking-up the catalog.
    public var suggestedCommands: [ConsoCommand] {
        suggestedCommandIDs.compactMap { CommandCatalog.command(id: $0) }
    }
}

/// The seam between a typed question and a grounded answer. Implementations NEVER throw —
/// any failure (model unavailable, error, empty output) degrades to the deterministic
/// `FallbackAsker` — so the bar always shows a usable reply. Mirrors `DoctorAdvising`.
public protocol Asking: Sendable {
    /// Answers `question` grounded in `facts`. The returned answer's suggested ids are
    /// always members of `CommandCatalog.all`.
    func answer(_ question: String, facts: DoctorFacts) async -> ConsoAnswer
}

/// The no-AI implementation: the current keyword launcher, repackaged as an answer.
///
/// Runs the deterministic `CommandMatcher` on the question. If anything matches, it offers
/// the top 1–2 commands with a short lead-in; if nothing matches, it declines politely and
/// points at example commands. Always available, always safe, always closed over the
/// catalog — this IS the offline / Apple-Intelligence-off behavior.
public struct FallbackAsker: Asking {
    private let catalog: [ConsoCommand]

    public init(catalog: [ConsoCommand] = CommandCatalog.all) {
        self.catalog = catalog
    }

    /// The line shown when nothing matches — keeps the bar useful by naming what conso
    /// can actually help with.
    public static let outOfScopeMessage =
        "I can help with your Mac’s health and conso’s tools — try “free up space” or “run doctor”."

    public func answer(_ question: String, facts: DoctorFacts) async -> ConsoAnswer {
        let matches = CommandMatcher.match(question, in: catalog)
        guard !matches.isEmpty else {
            return ConsoAnswer(answer: Self.outOfScopeMessage, suggestedCommandIDs: [],
                               inScope: false, isAIGenerated: false)
        }
        let ids = Array(matches.prefix(2)).map(\.id)
        return ConsoAnswer(answer: "Here’s what I can do for that:", suggestedCommandIDs: ids,
                           inScope: true, isAIGenerated: false)
    }
}
