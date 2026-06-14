import Foundation

/// Deterministic, offline ranking of a free-text query against the FIXED command
/// catalog. This is BOTH the fallback (when the on-device model is unavailable) and the
/// always-on safety net: it can only ever return commands from `CommandCatalog.all`, so
/// no query — however adversarial — can produce an action outside the closed set.
///
/// Scoring is case-insensitive and keyword-driven: an exact title/keyword match beats a
/// substring match, which beats a per-word token overlap. Gibberish that matches nothing
/// returns an empty list (the UI then shows "no matches" rather than guessing).
public enum CommandMatcher {
    /// Best matches for `query`, highest-scoring first. Empty when nothing is relevant.
    public static func match(_ query: String, in catalog: [ConsoCommand] = CommandCatalog.all) -> [ConsoCommand] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let queryTokens = tokens(q)

        let scored: [(command: ConsoCommand, score: Int)] = catalog.compactMap { cmd in
            let s = score(query: q, tokens: queryTokens, command: cmd)
            return s > 0 ? (cmd, s) : nil
        }
        // Stable order: by score desc, then by catalog order (preserved by enumerated index).
        return scored
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
                return lhs.offset < rhs.offset
            }
            .map(\.element.command)
    }

    /// The single best match (or nil) — used by the keyword resolver.
    public static func bestMatch(_ query: String, in catalog: [ConsoCommand] = CommandCatalog.all) -> ConsoCommand? {
        match(query, in: catalog).first
    }

    // MARK: - Scoring

    private static func score(query q: String, tokens queryTokens: [String], command cmd: ConsoCommand) -> Int {
        var best = 0
        let title = normalize(cmd.title)

        // Exact equality with the title or a keyword — strongest signal.
        if q == title { best = max(best, 1000) }
        for kw in cmd.keywords where q == normalize(kw) { best = max(best, 900) }

        // Whole-phrase substring: the query contains a keyword, or a keyword contains
        // the query (typing the start of a phrase). Longer overlaps score higher.
        for kw in cmd.keywords {
            let k = normalize(kw)
            if k.isEmpty { continue }
            if q.contains(k) { best = max(best, 500 + k.count) }
            if k.contains(q) { best = max(best, 300 + q.count) }
        }
        if title.contains(q) { best = max(best, 400 + q.count) }
        if q.contains(title) { best = max(best, 350) }

        // Per-token overlap against the title + every keyword: handles word-order
        // differences and partial phrases ("space free up" → "free up space").
        let haystack = Set(tokens(title) + cmd.keywords.flatMap { tokens(normalize($0)) })
        var overlap = 0
        for t in queryTokens where t.count >= 2 {
            if haystack.contains(t) { overlap += 1 }
            else if haystack.contains(where: { $0.hasPrefix(t) || t.hasPrefix($0) }) { overlap += 1 }
        }
        if overlap > 0 { best = max(best, 100 + overlap * 20) }

        return best
    }

    // MARK: - Normalization

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static let separators = CharacterSet.alphanumerics.inverted

    private static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: separators).filter { !$0.isEmpty }
    }
}
