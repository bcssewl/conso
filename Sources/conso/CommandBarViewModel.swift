import Foundation
import Observation
import ConsoCore

/// The live dependencies a command needs to run. Passed in from `RootView` so the view
/// model doesn't capture SwiftUI state directly — the same handlers the in-app buttons
/// already use, so a command does EXACTLY what the corresponding UI control does (and
/// nothing more). Destructive effects route through the existing preview/confirm flow.
@MainActor
struct CommandContext {
    let router: Router
    let quick: QuickActions
    let clean: CleanModel
    let software: SoftwareModel
    let analyze: AnalyzeModel
    /// Presents the Doctor sheet (RootView owns the @State that drives it).
    let runDoctor: () -> Void
    /// The live system snapshot, so the bar can ground its answers in real telemetry.
    let snapshot: SystemSnapshot
    /// The top process names (already capped by `DoctorFacts`), for grounding.
    let topProcesses: [String]

    /// The grounded facts the "Ask conso" model answers from — built from the live
    /// snapshot exactly like the Doctor, so the answer and the Status hero never disagree.
    var doctorFacts: DoctorFacts {
        DoctorFacts.from(snapshot: snapshot, topProcesses: topProcesses)
    }
}

/// Drives the "Ask conso" command bar. As you type it shows the live ranked keyword
/// results (the as-you-type affordance). On Enter it ANSWERS the question: it grounds an
/// on-device-model reply in real `DoctorFacts`, holds the `ConsoAnswer`, and offers up to
/// two one-tap actions — degrading to the deterministic keyword launcher when the model is
/// unavailable.
///
/// Safety: keyword results and every suggested action are ALWAYS members of
/// `CommandCatalog.all`. The model never executes — `run(_:)` (only on a user tap) maps a
/// command's target onto the same handlers the in-app controls use: navigation, the Doctor
/// sheet, a rescan, a Quick Clean *preview* (never a delete), or the Keep Awake toggle.
@MainActor
@Observable
final class CommandBarViewModel {
    /// The text the user is typing.
    var query: String = "" {
        didSet { queryChanged() }
    }
    /// Ranked, closed-set results. Keyword matches appear immediately; the model may
    /// re-rank the top hit shortly after.
    private(set) var results: [ConsoCommand] = []
    /// The highlighted row (driven by ↑/↓); clamped to `results`.
    var selection: Int = 0

    /// The grounded answer produced on the last Enter, if any. While `nil` the bar shows
    /// the as-you-type keyword results; once set it shows the answer + action buttons.
    private(set) var answer: ConsoAnswer?
    /// True while the on-device model is composing an answer (Enter pressed, not yet done).
    private(set) var isAnswering = false

    private let modelResolver: CommandResolving?
    private let asker: Asking
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var answerTask: Task<Void, Never>?

    /// `modelResolver` / `asker` are injectable for tests/previews; in the app they're the
    /// on-device classifier + grounded asker on macOS 26+, and the deterministic
    /// keyword/launcher fallbacks otherwise.
    init(modelResolver: CommandResolving? = nil, asker: Asking? = nil) {
        if let modelResolver {
            self.modelResolver = modelResolver
        } else if #available(macOS 26, *) {
            self.modelResolver = FoundationModelsCommandResolver()
        } else {
            self.modelResolver = nil
        }
        if let asker {
            self.asker = asker
        } else if #available(macOS 26, *) {
            self.asker = FoundationModelsAsker()
        } else {
            self.asker = FallbackAsker()
        }
    }

    /// The currently-highlighted command, if any.
    var highlighted: ConsoCommand? {
        guard results.indices.contains(selection) else { return nil }
        return results[selection]
    }

    // MARK: - Live resolution

    /// Recomputes results on each keystroke: deterministic matches show instantly (the
    /// always-on safety net), then the on-device model gets a brief debounce to promote
    /// its single best classification to the top — still only from the closed catalog.
    private func queryChanged() {
        resolveTask?.cancel()
        // Editing after an answer returns to the live as-you-type results.
        answerTask?.cancel()
        isAnswering = false
        answer = nil
        let keyword = CommandMatcher.match(query)
        results = keyword
        selection = 0

        guard let modelResolver else { return }
        let q = query
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))   // debounce
            if Task.isCancelled { return }
            guard let best = await modelResolver.resolve(q) else { return }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.query == q else { return }
                self.promote(best)
            }
        }
    }

    /// Moves the model's pick to the top without dropping the keyword matches, so the
    /// list still shows alternatives. No-op if it's already first.
    private func promote(_ command: ConsoCommand) {
        var list = results.filter { $0.id != command.id }
        list.insert(command, at: 0)
        results = list
        selection = 0
    }

    // MARK: - Answering (Enter)

    /// Produces a grounded ANSWER for the current query: builds `DoctorFacts` from the live
    /// snapshot and asks the on-device model (or the deterministic launcher when it's
    /// unavailable). The result is held in `answer` and shown with up to two one-tap
    /// actions — nothing runs until the user taps one. No-op for an empty query.
    func submit(in ctx: CommandContext) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        resolveTask?.cancel()           // the as-you-type re-rank is moot once we answer
        answerTask?.cancel()
        isAnswering = true
        answer = nil
        let facts = ctx.doctorFacts
        answerTask = Task { [weak self, asker] in
            let result = await asker.answer(q, facts: facts)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                // Cancellation is the relevance check: `submit` cancels the prior answerTask,
                // and `queryChanged`/`reset` clear `isAnswering`. Comparing `self.query` to the
                // TRIMMED `q` would falsely fail on any surrounding whitespace and strand the
                // spinner forever, so guard ONLY on cancellation here.
                guard let self, !Task.isCancelled else { return }
                self.answer = result
                self.isAnswering = false
            }
        }
    }

    // MARK: - Keyboard

    func moveDown() { if !results.isEmpty { selection = min(selection + 1, results.count - 1) } }
    func moveUp() { if !results.isEmpty { selection = max(selection - 1, 0) } }

    /// Clears the bar (called on dismiss) so the next open starts fresh.
    func reset() {
        resolveTask?.cancel()
        answerTask?.cancel()
        isAnswering = false
        answer = nil
        query = ""
        results = []
        selection = 0
    }

    // MARK: - Execution

    /// Runs `command`'s SAFE target via the live context. Nothing destructive happens
    /// inline: Quick Clean opens the existing PREVIEW; everything else navigates,
    /// rescans, presents the Doctor sheet, or toggles a reversible setting.
    func run(_ command: ConsoCommand, in ctx: CommandContext) {
        switch command.target {
        case .navigate(let pillar):
            ctx.router.pillar = Self.appPillar(pillar)
        case .runDoctor:
            ctx.runDoctor()
        case .quickClean:
            ctx.router.pillar = .clean
            ctx.clean.start()          // ensure a scan exists before previewing
            ctx.clean.quickClean()     // opens the PREVIEW sheet — never deletes
        case .checkUpdates:
            ctx.router.pillar = .software
            ctx.software.start()
            ctx.software.refresh()
        case .openAnalyze:
            ctx.router.pillar = .analyze
            ctx.analyze.start()
        case .toggleKeepAwake:
            ctx.quick.keepAwake.toggle()
        }
    }

    /// Maps ConsoCore's portable `Pillar` onto the app's SwiftUI `Pillar`.
    static func appPillar(_ p: ConsoCore.Pillar) -> Pillar {
        switch p {
        case .clean: return .clean
        case .software: return .software
        case .optimize: return .optimize
        case .analyze: return .analyze
        case .status: return .status
        }
    }
}
