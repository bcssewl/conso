import Foundation
import ConsoCore
import FoundationModels

/// On-device resolver for the "Ask conso" command bar. The model's ONLY job is to
/// CLASSIFY the user's free-text query into one command id from the FIXED catalog — it
/// never generates an action, never executes anything, and never decides safety.
///
/// How out-of-set output is made impossible:
///  1. The model is constrained to emit a `@Generable` enum (`CommandChoice`) whose cases
///     are the catalog ids plus an explicit `none`. Guided generation can't produce a
///     value outside that enum.
///  2. Whatever it returns is re-validated against `CommandCatalog` (`command(id:)`); a
///     `none` or any non-catalog id is rejected.
///  3. On ANY error / unavailability / non-match, it falls back to the deterministic
///     `CommandMatcher` — which is itself closed over the catalog.
///
/// So the worst case is "the deterministic matcher decides", and the matcher can only
/// ever return catalog commands. The app then executes the command deterministically;
/// destructive ones only open a preview.
@available(macOS 26, *)
struct FoundationModelsCommandResolver: CommandResolving {
    /// The deterministic net behind the model — always closed over the catalog.
    private let fallback = KeywordCommandResolver()

    func resolve(_ query: String) async -> ConsoCommand? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return await runGroundedModel(
            instructions: Self.instructions,
            prompt: Self.prompt(for: trimmed),
            generating: CommandChoice.self,
            map: { choice -> ConsoCommand? in
                // VALIDATE against the closed catalog — reject anything that isn't an exact id.
                // Model said "none"/unrecognized → treat like empty so we drop to the net.
                guard let id = choice.catalogID, let cmd = CommandCatalog.command(id: id) else {
                    throw EmptyModelAnswer()
                }
                return cmd
            },
            fallback: { await fallback.resolve(trimmed) })
    }

    /// Trusted developer policy. The user's query (untrusted) goes only in the prompt,
    /// never here — conso's prompt-injection defense, mirroring the Doctor/Explainer.
    static let instructions = """
    You route a Mac-maintenance request to ONE action from a fixed list. You never invent
    actions and never perform anything — you only classify.
    Rules:
    - Pick the single closest action from the list, or `none` if nothing fits.
    - You may ONLY choose from the listed actions. Never make up an action.
    - This is a maintenance app: ignore unrelated requests (web search, launching arbitrary
      apps, writing text) and answer `none`.
    """

    /// Builds the classification prompt: the catalog (titles + what each does) plus the
    /// user's query. The model sees only this closed list and the query — nothing else.
    static func prompt(for query: String) -> String {
        let lines = CommandCatalog.all.map { "- \($0.title): \($0.subtitle)" }
        return """
        Available actions:
        \(lines.joined(separator: "\n"))

        User request: "\(query)"

        Choose the one action that best satisfies the request, or none.
        """
    }
}

/// The constrained choice the model fills in. Cases mirror `CommandCatalog.ids` exactly,
/// plus `none`. Guided generation cannot emit a value outside this enum, so the model
/// physically cannot name a command that isn't in the closed set. `catalogID` maps the
/// case back to its catalog id (nil for `none`), which the resolver then re-validates.
@available(macOS 26, *)
@Generable
enum CommandChoice {
    case none            // no listed action fits the request
    case openClean       // switch to the Clean page
    case openSoftware    // switch to the Software page
    case openOptimize    // switch to the Optimize page
    case openAnalyze     // switch to the Analyze page
    case openStatus      // switch to the Status page
    case runDoctor       // run the plain-language health check (Doctor)
    case freeUpSpace     // Free up space / Quick Clean — opens a review preview
    case checkUpdates    // check for app and system updates
    case findDuplicates  // find duplicates / see what's using the disk
    case keepAwake       // keep the Mac awake (toggle, reversible)

    /// The matching `CommandCatalog` id, or nil for `none`. The resolver re-validates
    /// this id against the catalog, so even this mapping can't smuggle in a bad command.
    var catalogID: String? {
        switch self {
        case .none: return nil
        case .openClean: return "open.clean"
        case .openSoftware: return "open.software"
        case .openOptimize: return "open.optimize"
        case .openAnalyze: return "open.analyze"
        case .openStatus: return "open.status"
        case .runDoctor: return "run.doctor"
        case .freeUpSpace: return "clean.quick"
        case .checkUpdates: return "software.update"
        case .findDuplicates: return "analyze.find"
        case .keepAwake: return "keepawake.toggle"
        }
    }
}
