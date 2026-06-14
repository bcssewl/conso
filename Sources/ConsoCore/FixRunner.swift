import Foundation
import Observation

// MARK: - Per-task status

/// Where one fix is in its run. "Fail loud" (macos-lessons §3): a task ends as exactly
/// one terminal state and the UI surfaces skipped/failed — nothing is swallowed, and a
/// root-only fix is never faked as "done".
public enum FixStatus: Equatable, Sendable {
    /// Queued, not started yet.
    case pending
    /// User-level steps are executing.
    case running
    /// Every step that should run succeeded (user-level, and any root-level steps routed
    /// through the privileged helper). `summary` is the captured output/exit summary.
    case done(summary: String)
    /// The user-level steps ran but at least one root step was skipped (the privileged
    /// helper isn't installed, so it was deferred). `summary` covers what *did* run.
    case partial(summary: String)
    /// A step failed: a user-level step (non-zero exit/launch failure) OR a root step the
    /// helper ran and reported as failed. `message` is the error.
    case failed(message: String)
    /// Nothing ran: every step needs the privileged helper and it isn't installed.
    case skippedNeedsHelper
    /// Nothing ran: the task needs an app/bundle id picked first and none was chosen.
    case skippedNeedsPicker
}

/// The live result for one fix in a run: the task it came from and its current status.
public struct FixResult: Identifiable, Equatable, Sendable {
    public let taskID: String
    public let name: String
    /// True when this fix has root steps deferred to the helper (for the UI badge).
    public let needsHelper: Bool
    public var status: FixStatus
    public var id: String { taskID }

    public init(taskID: String, name: String, needsHelper: Bool, status: FixStatus = .pending) {
        self.taskID = taskID
        self.name = name
        self.needsHelper = needsHelper
        self.status = status
    }
}

// MARK: - Pure step execution (testable summarization)

/// The captured outcome of running one user-level step: exit status + combined output.
public struct StepRun: Equatable, Sendable {
    public let executable: String
    public let status: Int32
    public let output: String   // stdout+stderr, trimmed
    public init(executable: String, status: Int32, output: String) {
        self.executable = executable
        self.status = status
        self.output = output
    }
    public var succeeded: Bool { status == 0 }
}

/// The captured outcome of a root step the privileged helper ran on our behalf: its
/// whitelist command key, whether it succeeded, and the combined output it returned.
public struct RootStepRun: Equatable, Sendable {
    public let commandKey: String
    public let ok: Bool
    public let output: String
    public init(commandKey: String, ok: Bool, output: String) {
        self.commandKey = commandKey
        self.ok = ok
        self.output = output
    }
}

/// Pure helpers for building commands and summarizing output — unit-tested without
/// touching `Process`, so the runner's logic is verifiable.
public enum FixCommand {
    /// Builds the concrete `defaults delete <bundle-id>` step for the app-prefs fix.
    /// Returns nil for an empty/blank bundle id (nothing to run).
    public static func appPrefsStep(bundleID: String) -> FixStep? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return FixStep(executable: "/usr/bin/defaults", args: ["delete", id], needsRoot: false)
    }

    /// Folds the user-step runs (and whether any root step was skipped) into the terminal
    /// status + human summary shown in the results sheet. The first failed step makes the
    /// whole task `failed`; otherwise it's `done`, or `partial` when a root step was deferred.
    public static func summarize(_ runs: [StepRun], skippedRootSteps: Int) -> FixStatus {
        summarize(runs, rootRuns: [], skippedRootSteps: skippedRootSteps)
    }

    /// Folds the user-step runs, the root-step runs the helper actually performed, and the
    /// count of root steps that were SKIPPED (no helper installed) into the terminal status
    /// + human summary. A failed user step OR a failed helper root step makes the whole
    /// task `failed`; otherwise it's `partial` when any root step was skipped, else `done`.
    public static func summarize(_ runs: [StepRun], rootRuns: [RootStepRun],
                                 skippedRootSteps: Int) -> FixStatus {
        // A failed user step wins (and is reported first — it ran before the root steps).
        if let failure = runs.first(where: { !$0.succeeded }) {
            let tool = (failure.executable as NSString).lastPathComponent
            let detail = failure.output.isEmpty ? "exited with status \(failure.status)" : failure.output
            return .failed(message: "\(tool): \(detail)")
        }
        // A failed root step the helper ran also fails the task loudly.
        if let failure = rootRuns.first(where: { !$0.ok }) {
            let detail = failure.output.isEmpty ? "the privileged helper reported failure" : failure.output
            return .failed(message: "\(failure.commandKey) (admin): \(detail)")
        }
        var lines = runs.map { run -> String in
            let tool = (run.executable as NSString).lastPathComponent
            return run.output.isEmpty ? "\(tool): ok" : "\(tool): \(run.output)"
        }
        lines += rootRuns.map { run in
            run.output.isEmpty ? "\(run.commandKey) (admin): ok" : "\(run.commandKey) (admin): \(run.output)"
        }
        if skippedRootSteps > 0 {
            lines.append("\(skippedRootSteps) step\(skippedRootSteps == 1 ? "" : "s") need the privileged helper — install it in Settings (skipped)")
            return .partial(summary: lines.joined(separator: "\n"))
        }
        return .done(summary: lines.isEmpty ? "ok" : lines.joined(separator: "\n"))
    }
}

// MARK: - Runner

/// Routes a single whitelisted root command (by its `rootCommandKey`) to a privileged
/// helper and returns whether it succeeded plus the helper's combined output. The app
/// supplies `HelperClient.shared.runFix`; ConsoCore never imports the app or XPC, so this
/// closure is the only seam between the tested runner and the privileged side.
public typealias RootRunner = @Sendable (String) async -> (ok: Bool, output: String)

/// Runs the selected fixes' USER-level steps in-process and publishes a per-task status.
/// SAFE & HONEST by construction:
/// - USER steps run in-process here. ROOT steps are NEVER executed in-process — they're
///   routed to the privileged helper via the injected `RootRunner` (by `rootCommandKey`).
/// - With NO root-runner (or none wired), a fix with only root steps is `skippedNeedsHelper`
///   and a mixed fix ends `partial` (its root work is deferred — "install the helper").
/// - With a root-runner, root steps run through the helper and fold into the terminal
///   status (`done`/`failed`/`partial`).
/// - The app-prefs fix needs a bundle id; without one it's `skippedNeedsPicker`.
/// Steps run off the main actor; results are published back on the main actor.
@MainActor
@Observable
public final class FixRunner {
    /// Per-task results, in run order. Drives the progress/results sheet.
    public private(set) var results: [FixResult] = []
    /// True while a run is in flight.
    public private(set) var isRunning = false
    /// True once a run has completed (so the sheet can show "done").
    public private(set) var didFinish = false

    /// Routes root steps to the privileged helper. nil → root steps are skipped honestly
    /// ("install the helper"). The app injects `HelperClient.shared.runFix`.
    @ObservationIgnored private let runRoot: RootRunner?

    @ObservationIgnored private var runTask: Task<Void, Never>?

    /// - Parameter runRoot: optional seam to a privileged helper. When nil (the default,
    ///   used by tests and by the app before the helper is installed), every root step is
    ///   skipped and the task ends `partial`/`skippedNeedsHelper` instead of running it.
    public init(runRoot: RootRunner? = nil) {
        self.runRoot = runRoot
    }

    /// Whether the runner currently has anything to show (used to drive the sheet).
    public var hasResults: Bool { !results.isEmpty }

    /// Starts a run for `tasks`. `bundleIDsByTask` supplies the chosen bundle id for any
    /// app-picker fix (keyed by task id). Tasks without a needed bundle id are
    /// `skippedNeedsPicker`. Idempotent while a run is in flight.
    public func run(_ tasks: [FixTask], bundleIDsByTask: [String: String] = [:]) {
        guard !isRunning else { return }
        isRunning = true
        didFinish = false
        // Seed the result list so the sheet shows every task as pending immediately.
        results = tasks.map { FixResult(taskID: $0.id, name: $0.name, needsHelper: $0.needsHelper) }

        // Snapshot the plan as Sendable value data for the detached executor. Root steps
        // are carried as their whitelist command keys (skipping any without one — they
        // can't be routed and so are treated as deferred).
        let plan: [(taskID: String, userSteps: [FixStep], rootKeys: [String], requiresPicker: Bool, bundleID: String?)] =
            tasks.map { task in
                if task.requiresAppPicker {
                    let id = bundleIDsByTask[task.id]
                    let step = id.flatMap { FixCommand.appPrefsStep(bundleID: $0) }
                    return (task.id, step.map { [$0] } ?? [], [], true, id)
                }
                return (task.id, task.userSteps, task.rootSteps.compactMap(\.rootCommandKey), false, nil)
            }

        let runRoot = self.runRoot
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            for entry in plan {
                let hasUser = !entry.userSteps.isEmpty
                let hasRoot = !entry.rootKeys.isEmpty

                // App-picker fix with no chosen bundle id → nothing to run.
                if entry.requiresPicker, !hasUser {
                    await self?.update(entry.taskID) { $0.status = .skippedNeedsPicker }
                    continue
                }
                // No user steps AND no routable root steps → fully helper-gated, nothing ran.
                if !hasUser, !hasRoot {
                    await self?.update(entry.taskID) { $0.status = .skippedNeedsHelper }
                    continue
                }
                // No helper wired AND only root steps → fully gated, nothing ran.
                if runRoot == nil, !hasUser {
                    await self?.update(entry.taskID) { $0.status = .skippedNeedsHelper }
                    continue
                }

                await self?.update(entry.taskID) { $0.status = .running }

                // 1. User steps run in-process.
                var runs: [StepRun] = []
                for step in entry.userSteps { runs.append(Self.execute(step)) }

                // 2. Root steps route to the helper when wired; otherwise they're deferred.
                var rootRuns: [RootStepRun] = []
                var skippedRoot = 0
                if let runRoot {
                    for key in entry.rootKeys {
                        let r = await runRoot(key)
                        rootRuns.append(RootStepRun(commandKey: key, ok: r.ok, output: r.output))
                    }
                } else {
                    skippedRoot = entry.rootKeys.count
                }

                let final = FixCommand.summarize(runs, rootRuns: rootRuns, skippedRootSteps: skippedRoot)
                await self?.update(entry.taskID) { $0.status = final }
            }
            await self?.finish()
        }
    }

    /// Clears the results and dismisses the sheet.
    public func reset() {
        runTask?.cancel()
        runTask = nil
        results = []
        isRunning = false
        didFinish = false
    }

    // MARK: Private

    private func update(_ taskID: String, _ mutate: (inout FixResult) -> Void) {
        guard let i = results.firstIndex(where: { $0.taskID == taskID }) else { return }
        mutate(&results[i])
    }

    private func finish() {
        isRunning = false
        didFinish = true
    }

    /// Runs one user-level step via `Process`, capturing combined stdout+stderr and the
    /// exit status. A launch failure (missing tool) is reported as status -1. NEVER used
    /// for root steps. `nonisolated static` so it runs on the detached task.
    nonisolated static func execute(_ step: FixStep) -> StepRun {
        guard FileManager.default.isExecutableFile(atPath: step.executable) else {
            return StepRun(executable: step.executable, status: -1,
                           output: "tool not found at \(step.executable)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: step.executable)
        task.arguments = step.args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return StepRun(executable: step.executable, status: -1,
                           output: error.localizedDescription)
        }
        // Read fully before waiting to avoid a deadlock if the pipe buffer fills.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return StepRun(executable: step.executable, status: task.terminationStatus, output: output)
    }
}
