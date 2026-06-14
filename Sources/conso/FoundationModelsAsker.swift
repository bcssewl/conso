import Foundation
import ConsoCore
import FoundationModels

/// Thrown inside an on-device model call when the model yields an empty answer, so the
/// surrounding `withTimeout` / `catch` routes to the deterministic fallback. Shared by the
/// on-device AI adapters (Asker / Doctor / Explainer).
struct EmptyModelAnswer: Error {}

/// Upper bound on any on-device model call before the adapter drops to its deterministic
/// fallback — so a stalled model can never leave a surface "thinking…" indefinitely. Shared
/// by the Asker / Doctor / Explainer / Resolver adapters.
let aiCallTimeoutSeconds: Double = 8

/// On-device implementation of `Asking` for the "Ask conso" command bar. The model
/// answers a natural-language QUESTION about this Mac, grounded ONLY in the supplied
/// `DoctorFacts`, and chooses up to two one-tap actions from the FIXED command catalog.
///
/// How it stays safe and grounded:
///  1. The grounded facts go in the prompt; the untrusted question + process names go ONLY
///     in the prompt, never in `instructions` — conso's prompt-injection defense (mirrors
///     the Doctor / Explainer / Resolver).
///  2. The model writes a SHORT plain-language `answer` and picks actions from a closed
///     `@Generable` enum of catalog ids (plus `.none`) — guided generation can't emit an
///     action outside the set.
///  3. Whatever ids it returns are re-validated against `CommandCatalog` inside
///     `ConsoAnswer.init`, which drops anything unknown.
///  4. On ANY error / unavailability / empty answer it falls back to `FallbackAsker` — the
///     deterministic keyword launcher — so the bar is never dead.
@available(macOS 26, *)
struct FoundationModelsAsker: Asking {
    /// The deterministic net behind the model — the offline launcher behavior.
    private let fallback = FallbackAsker()

    func answer(_ question: String, facts: DoctorFacts) async -> ConsoAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return await fallback.answer(question, facts: facts)
        }
        // Bound the on-device call (a stalled model would otherwise leave the bar
        // "thinking…" forever) and fall through to the deterministic launcher on timeout /
        // any error / empty answer, so the bar always resolves. Shared plumbing in
        // `runGroundedModel`; only the prompt/instructions/map differ.
        return await runGroundedModel(
            instructions: Self.instructions,
            prompt: Self.prompt(question: trimmed, facts: facts),
            generating: AskSchema.self,
            map: { schema in
                let text = schema.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw EmptyModelAnswer() }
                return Self.map(schema, text: text)
            },
            fallback: { await fallback.answer(question, facts: facts) })
    }

    /// Trusted developer policy. The untrusted question + process names NEVER go here —
    /// only in the prompt — which is conso's prompt-injection defense.
    ///
    /// Calm, short, neutral wording on purpose: tense phrasing can trip Apple's on-device
    /// safety guardrails ("Safety guardrails were triggered"), which silently drops us to
    /// the deterministic launcher. Neutral wording reduces those false-positive refusals.
    static let instructions = """
    You are conso, a calm and friendly Mac-maintenance assistant. Answer the owner's
    question about their Mac in plain language, then offer up to two helpful actions.
    Rules:
    - Use ONLY the facts in the prompt. Never invent numbers, file names, or app names.
    - Keep the answer to 1–3 short sentences. Reassuring. No marketing language. No emoji.
    - Choose at most two actions from the provided list, or none — only ids from that list.
    - If the question is NOT about this Mac's health or conso's maintenance tools (e.g. web
      search, general trivia, launching arbitrary apps, writing text), set outOfScope to
      true and briefly, politely decline instead of answering.
    """

    /// Builds the prompt: the grounded facts (formatted like the Doctor's), the closed
    /// action list (titles + ids), and the user's question. The model sees only this.
    static func prompt(question: String, facts f: DoctorFacts) -> String {
        let actions = CommandCatalog.all
            .map { "- \($0.id): \($0.title) — \($0.subtitle)" }
            .joined(separator: "\n")
        // We do NOT inject raw process names verbatim — arbitrary app/binary names are a
        // common safety-filter trigger and add no grounding value to a health answer. We
        // generalise to a neutral count so the answer stays grounded without a refusal.
        let busiest: String
        switch f.topProcesses.count {
        case 0:  busiest = "n/a"
        case 1:  busiest = "one app is using the most resources"
        default: busiest = "a few apps are using the most resources"
        }
        return """
        This Mac's current health facts:
        Score: \(f.score)/100 (\(f.grade)); \(f.checksPassed)/\(f.checksTotal) checks passed.
        CPU \(f.cpuPercent)%, memory \(f.memoryPercent)%, disk \(f.diskPercent)%, swap \(ByteFormat.string(f.swapBytes)).
        Thermal: \(f.thermal.label). Memory pressure: \(f.pressure.label).
        Activity: \(busiest).

        Available actions:
        \(actions)

        The owner asks: "\(question)"

        Answer their question grounded only in the facts above, then choose up to two of the
        listed actions (by id) that would help. If the question isn't about this Mac's health
        or conso's tools, set outOfScope and decline.
        """
    }

    /// Maps the schema → `ConsoAnswer`, resolving each chosen action to its catalog id.
    /// `ConsoAnswer.init` re-validates the ids, so unknowns are dropped even here.
    static func map(_ s: AskSchema, text: String) -> ConsoAnswer {
        let ids = s.outOfScope ? [] : s.actions.compactMap(\.catalogID)
        return ConsoAnswer(answer: text, suggestedCommandIDs: ids,
                           inScope: !s.outOfScope, isAIGenerated: true)
    }
}

/// The structured output the model fills in. It writes a short grounded `answer`, flags
/// whether the question was in scope, and picks up to two actions from `AskAction` — a
/// closed enum whose cases mirror `CommandCatalog.ids`. Guided generation cannot emit an
/// action outside this enum.
@available(macOS 26, *)
@Generable
struct AskSchema {
    @Guide(description: "A 1–3 sentence plain-language answer grounded ONLY in the facts given. Never invent numbers or names. If out of scope, a brief polite decline.")
    var answer: String
    @Guide(description: "True when the question is NOT about this Mac's health or conso's maintenance tools.")
    var outOfScope: Bool
    @Guide(description: "Up to two actions from the list that would help the owner.", .maximumCount(2))
    var actions: [AskAction]
}

/// The closed set of actions the model may suggest. Cases mirror `CommandCatalog.ids`
/// exactly; `catalogID` maps each back to its id (re-validated by `ConsoAnswer.init`), so
/// the model physically cannot name an action that isn't in the closed catalog.
@available(macOS 26, *)
@Generable
enum AskAction {
    case openClean       // switch to the Clean page
    case openSoftware    // switch to the Software page
    case openOptimize    // switch to the Optimize page
    case openAnalyze     // switch to the Analyze page
    case openStatus      // switch to the Status page (live metrics)
    case runDoctor       // run the plain-language health check (Doctor)
    case freeUpSpace     // Free up space / Quick Clean — opens a review preview
    case checkUpdates    // check for app and system updates
    case findDuplicates  // find duplicates / see what's using the disk
    case keepAwake       // keep the Mac awake (toggle, reversible)

    /// The matching `CommandCatalog` id. `ConsoAnswer.init` re-validates this against the
    /// catalog, so even this mapping can't smuggle in a bad command.
    var catalogID: String? {
        switch self {
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
