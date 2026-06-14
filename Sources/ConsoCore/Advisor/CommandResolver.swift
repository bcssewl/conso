import Foundation

/// The seam between a typed query and a chosen command. Implementations classify the
/// query into AT MOST ONE command from the FIXED catalog — they never originate an
/// action and never execute one. On the app side, an on-device-model resolver layers
/// over the deterministic `KeywordCommandResolver`, falling back to it on any failure.
public protocol CommandResolving: Sendable {
    /// The single best command for `query`, or nil when nothing matches. The result is
    /// ALWAYS a member of `CommandCatalog.all` — out-of-set output is impossible.
    func resolve(_ query: String) async -> ConsoCommand?
}

/// The deterministic, offline resolver. Always available, always safe; used directly as
/// the fallback and as the always-on net behind the model resolver.
public struct KeywordCommandResolver: CommandResolving {
    private let catalog: [ConsoCommand]

    public init(catalog: [ConsoCommand] = CommandCatalog.all) {
        self.catalog = catalog
    }

    public func resolve(_ query: String) async -> ConsoCommand? {
        CommandMatcher.bestMatch(query, in: catalog)
    }
}
