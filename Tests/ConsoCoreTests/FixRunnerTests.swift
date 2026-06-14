import XCTest
@testable import ConsoCore

/// Asserts the Optimize catalog carries the EXACT command + root metadata for each fix,
/// so the runner's user/root split is verified without spawning any subprocess.
final class OptimizeCommandMetadataTests: XCTestCase {
    private func task(_ id: String) -> FixTask {
        let t = OptimizeCatalog.tasks().first { $0.id == id }
        XCTAssertNotNil(t, "missing fix \(id)")
        return t!
    }

    func testFlushDNS() {
        let t = task("dns")
        XCTAssertEqual(t.steps.count, 2)
        XCTAssertEqual(t.steps[0], FixStep(executable: "/usr/bin/dscacheutil", args: ["-flushcache"], needsRoot: false))
        XCTAssertEqual(t.steps[1], FixStep(executable: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"], needsRoot: true, rootCommandKey: "dns-hup"))
        XCTAssertTrue(t.needsHelper, "the mDNSResponder HUP needs root")
        XCTAssertEqual(t.userSteps.count, 1)
        XCTAssertEqual(t.rootSteps.count, 1)
        XCTAssertFalse(t.requiresAppPicker)
    }

    func testRebuildSpotlightIsRootOnly() {
        let t = task("spotlight")
        XCTAssertEqual(t.steps, [FixStep(executable: "/usr/bin/mdutil", args: ["-E", "/"], needsRoot: true, rootCommandKey: "spotlight")])
        XCTAssertTrue(t.needsHelper)
        XCTAssertTrue(t.userSteps.isEmpty, "Spotlight reindex is fully helper-gated")
    }

    func testRebuildQuickLookIsUserOnly() {
        let t = task("quicklook")
        XCTAssertEqual(t.steps, [
            FixStep(executable: "/usr/bin/qlmanage", args: ["-r"], needsRoot: false),
            FixStep(executable: "/usr/bin/qlmanage", args: ["-r", "cache"], needsRoot: false),
        ])
        XCTAssertFalse(t.needsHelper)
        XCTAssertEqual(t.userSteps.count, 2)
    }

    func testClearFontCachesSplit() {
        let t = task("fonts")
        XCTAssertEqual(t.steps[0], FixStep(executable: "/usr/bin/atsutil", args: ["databases", "-removeUser"], needsRoot: false))
        XCTAssertTrue(t.steps[1].needsRoot, "the system font DB clear needs root")
        XCTAssertTrue(t.needsHelper)
        XCTAssertEqual(t.userSteps.count, 1)
        XCTAssertFalse(t.warning.isEmpty, "fonts must warn about the reboot")
    }

    func testResetLaunchServicesIsUserOnly() {
        let t = task("launchservices")
        XCTAssertEqual(t.steps.count, 2)
        XCTAssertTrue(t.steps[0].executable.hasSuffix("/Support/lsregister"))
        XCTAssertEqual(t.steps[0].args,
                       ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
        XCTAssertEqual(t.steps[1], FixStep(executable: "/usr/bin/killall", args: ["Finder"], needsRoot: false))
        XCTAssertFalse(t.needsHelper)
    }

    func testResetAppPrefsRequiresPicker() {
        let t = task("app-prefs")
        XCTAssertTrue(t.requiresAppPicker)
        XCTAssertTrue(t.steps.isEmpty, "the defaults-delete step is built at run time from the chosen id")
        XCTAssertFalse(t.needsHelper, "the defaults delete runs as the user")
        XCTAssertFalse(t.warning.isEmpty, "must warn prefs are wiped")
    }

    func testRestartDockAndFinderIsUserOnly() {
        let t = task("restart-dock-finder")
        XCTAssertEqual(t.steps, [
            FixStep(executable: "/usr/bin/killall", args: ["Dock"], needsRoot: false),
            FixStep(executable: "/usr/bin/killall", args: ["Finder"], needsRoot: false),
        ])
        XCTAssertFalse(t.needsHelper, "relaunching Dock & Finder runs as the user")
        XCTAssertEqual(t.userSteps.count, 2)
        XCTAssertFalse(t.isSelected, "situational fix is default-off")
        XCTAssertFalse(t.requiresAppPicker)
    }

    func testRebuildIconCacheIsUserOnly() {
        let t = task("icon-cache")
        XCTAssertEqual(t.steps.count, 2)
        // First step clears the iconservices cache store contents…
        XCTAssertEqual(t.steps[0].executable, "/bin/rm")
        XCTAssertEqual(t.steps[0].args.first, "-rf")
        XCTAssertTrue(t.steps[0].args.last?.hasSuffix("com.apple.iconservices.store") ?? false,
                      "should target the iconservices cache store: \(t.steps[0].args)")
        XCTAssertTrue(t.steps[0].args.last?.hasPrefix("/") ?? false, "must be an absolute path")
        XCTAssertFalse(t.steps[0].needsRoot)
        // …then relaunch the Dock so icons redraw.
        XCTAssertEqual(t.steps[1], FixStep(executable: "/usr/bin/killall", args: ["Dock"], needsRoot: false))
        XCTAssertFalse(t.needsHelper, "icon cache rebuild runs as the user")
        XCTAssertEqual(t.userSteps.count, 2)
        XCTAssertFalse(t.isSelected, "situational fix is default-off")
    }

    func testEveryTaskStepUsesAbsolutePath() {
        for task in OptimizeCatalog.tasks() {
            for step in task.steps {
                XCTAssertTrue(step.executable.hasPrefix("/"),
                              "\(task.id) step must use an absolute path: \(step.executable)")
            }
        }
    }
}

/// Pure command-building + summarization logic (no Process).
final class FixCommandTests: XCTestCase {
    func testAppPrefsStepBuildsDefaultsDelete() {
        let step = FixCommand.appPrefsStep(bundleID: "com.example.app")
        XCTAssertEqual(step, FixStep(executable: "/usr/bin/defaults", args: ["delete", "com.example.app"], needsRoot: false))
    }

    func testAppPrefsStepTrimsAndRejectsBlank() {
        XCTAssertEqual(FixCommand.appPrefsStep(bundleID: "  com.example.app  ")?.args,
                       ["delete", "com.example.app"])
        XCTAssertNil(FixCommand.appPrefsStep(bundleID: "   "))
        XCTAssertNil(FixCommand.appPrefsStep(bundleID: ""))
    }

    func testSummarizeAllOkIsDone() {
        let runs = [StepRun(executable: "/usr/bin/qlmanage", status: 0, output: "")]
        guard case .done(let summary) = FixCommand.summarize(runs, skippedRootSteps: 0) else {
            return XCTFail("expected .done")
        }
        XCTAssertTrue(summary.contains("qlmanage"))
    }

    func testSummarizeWithSkippedRootIsPartial() {
        let runs = [StepRun(executable: "/usr/bin/dscacheutil", status: 0, output: "")]
        guard case .partial(let summary) = FixCommand.summarize(runs, skippedRootSteps: 1) else {
            return XCTFail("expected .partial")
        }
        XCTAssertTrue(summary.contains("privileged helper"))
    }

    func testSummarizeFailedStepIsFailed() {
        let runs = [
            StepRun(executable: "/usr/bin/defaults", status: 1, output: "Domain not found"),
        ]
        guard case .failed(let message) = FixCommand.summarize(runs, skippedRootSteps: 0) else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(message.contains("defaults"))
        XCTAssertTrue(message.contains("Domain not found"))
    }

    func testSummarizeFailedTakesPrecedenceOverSkippedRoot() {
        let runs = [StepRun(executable: "/usr/bin/atsutil", status: 2, output: "boom")]
        guard case .failed = FixCommand.summarize(runs, skippedRootSteps: 1) else {
            return XCTFail("a failed user step must win over a deferred root step")
        }
    }

    // MARK: Root-step folding (helper-routed steps)

    func testSummarizeUserPlusOkRootIsDone() {
        let runs = [StepRun(executable: "/usr/bin/dscacheutil", status: 0, output: "")]
        let rootRuns = [RootStepRun(commandKey: "dns-hup", ok: true, output: "")]
        guard case .done(let summary) = FixCommand.summarize(runs, rootRuns: rootRuns, skippedRootSteps: 0) else {
            return XCTFail("user ok + root ok must be .done")
        }
        XCTAssertTrue(summary.contains("dscacheutil"))
        XCTAssertTrue(summary.contains("dns-hup"))
    }

    func testSummarizeRootOnlyOkIsDone() {
        let rootRuns = [RootStepRun(commandKey: "spotlight", ok: true, output: "indexing enabled")]
        guard case .done(let summary) = FixCommand.summarize([], rootRuns: rootRuns, skippedRootSteps: 0) else {
            return XCTFail("a root-only fix that ran via the helper must be .done")
        }
        XCTAssertTrue(summary.contains("spotlight"))
        XCTAssertTrue(summary.contains("indexing enabled"))
    }

    func testSummarizeFailedRootStepIsFailed() {
        let runs = [StepRun(executable: "/usr/bin/dscacheutil", status: 0, output: "")]
        let rootRuns = [RootStepRun(commandKey: "dns-hup", ok: false, output: "killall: not permitted")]
        guard case .failed(let message) = FixCommand.summarize(runs, rootRuns: rootRuns, skippedRootSteps: 0) else {
            return XCTFail("a failed helper root step must fail the task loudly")
        }
        XCTAssertTrue(message.contains("dns-hup"))
        XCTAssertTrue(message.contains("not permitted"))
    }

    func testSummarizeFailedUserStepBeatsOkRoot() {
        let runs = [StepRun(executable: "/usr/bin/dscacheutil", status: 1, output: "boom")]
        let rootRuns = [RootStepRun(commandKey: "dns-hup", ok: true, output: "")]
        guard case .failed(let message) = FixCommand.summarize(runs, rootRuns: rootRuns, skippedRootSteps: 0) else {
            return XCTFail("a failed user step must win over an ok root step")
        }
        XCTAssertTrue(message.contains("dscacheutil"))
    }
}

/// Exercises the runner end to end against real, harmless user-level tools so the
/// status transitions and root-deferral are verified. `@MainActor` because the runner is.
@MainActor
final class FixRunnerExecutionTests: XCTestCase {
    func testExecuteRealUserToolSucceeds() {
        // `/usr/bin/true` exits 0 with no output — a safe stand-in for a user step.
        let run = FixRunner.execute(FixStep(executable: "/usr/bin/true", args: [], needsRoot: false))
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.succeeded)
    }

    func testExecuteMissingToolReportsFailure() {
        let run = FixRunner.execute(FixStep(executable: "/usr/bin/definitely-not-real", args: [], needsRoot: false))
        XCTAssertEqual(run.status, -1)
        XCTAssertFalse(run.succeeded)
        XCTAssertTrue(run.output.contains("not found"))
    }

    func testExecuteFalseReportsNonZero() {
        let run = FixRunner.execute(FixStep(executable: "/usr/bin/false", args: [], needsRoot: false))
        XCTAssertNotEqual(run.status, 0)
        XCTAssertFalse(run.succeeded)
    }

    func testRunRootOnlyTaskIsSkippedNeedsHelperWithNoRunner() async {
        // No root-runner wired (helper not installed) → a root-only fix never runs.
        let runner = FixRunner()
        let spotlight = OptimizeCatalog.tasks().first { $0.id == "spotlight" }!
        runner.run([spotlight])
        await waitUntilFinished(runner)
        XCTAssertEqual(runner.results.count, 1)
        XCTAssertEqual(runner.results[0].status, .skippedNeedsHelper)
    }

    func testRunAppPrefsWithoutPickerIsSkipped() async {
        let runner = FixRunner()
        let appPrefs = OptimizeCatalog.tasks().first { $0.id == "app-prefs" }!
        runner.run([appPrefs])   // no bundle id provided
        await waitUntilFinished(runner)
        XCTAssertEqual(runner.results[0].status, .skippedNeedsPicker)
    }

    func testRunAppPrefsWithUnknownDomainFailsLoud() async {
        let runner = FixRunner()
        let appPrefs = OptimizeCatalog.tasks().first { $0.id == "app-prefs" }!
        // A bundle id that certainly has no defaults domain → defaults delete exits non-zero.
        runner.run([appPrefs], bundleIDsByTask: ["app-prefs": "com.conso.nonexistent.\(UUID().uuidString)"])
        await waitUntilFinished(runner)
        guard case .failed = runner.results[0].status else {
            return XCTFail("deleting a nonexistent domain must fail loud, got \(runner.results[0].status)")
        }
    }

    // MARK: Injected root-runner seam

    /// Records every command key it's asked to run and returns a canned (ok, output).
    /// `Sendable` (a final class with a lock) so it can back a `@Sendable RootRunner`.
    final class FakeRootRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private let ok: Bool
        private let output: String

        init(ok: Bool, output: String = "ok") { self.ok = ok; self.output = output }

        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

        func run(_ key: String) -> (ok: Bool, output: String) {
            lock.lock(); _calls.append(key); lock.unlock()
            return (ok, output)
        }
    }

    func testRootRunnerRoutesRootOnlyTaskAndMarksDone() async {
        let fake = FakeRootRunner(ok: true, output: "indexing enabled")
        let runner = FixRunner(runRoot: { fake.run($0) })
        let spotlight = OptimizeCatalog.tasks().first { $0.id == "spotlight" }!
        runner.run([spotlight])
        await waitUntilFinished(runner)
        XCTAssertEqual(fake.calls, ["spotlight"], "the spotlight root key must route to the helper")
        guard case .done = runner.results[0].status else {
            return XCTFail("a routed, successful root-only fix must be .done, got \(runner.results[0].status)")
        }
    }

    func testRootRunnerRoutesMixedTaskUserThenRoot() async {
        let fake = FakeRootRunner(ok: true)
        let runner = FixRunner(runRoot: { fake.run($0) })
        // A synthetic mixed fix: a guaranteed-success user step (/usr/bin/true) plus a root
        // step routed by key. Avoids depending on a real tool's environment behavior.
        let mixed = FixTask(id: "mixed", name: "Mixed", detail: "", symbol: "gear",
                            badge: "", badgeIsWarm: false,
                            steps: [
                                FixStep(executable: "/usr/bin/true", args: [], needsRoot: false),
                                FixStep(executable: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"],
                                        needsRoot: true, rootCommandKey: "dns-hup"),
                            ])
        runner.run([mixed])
        await waitUntilFinished(runner)
        XCTAssertEqual(fake.calls, ["dns-hup"], "only the root step routes through the helper")
        guard case .done = runner.results[0].status else {
            return XCTFail("user (true) + HUP (helper) both ok must be .done, got \(runner.results[0].status)")
        }
    }

    func testRootRunnerFailureFailsTheTaskLoud() async {
        let fake = FakeRootRunner(ok: false, output: "operation not permitted")
        let runner = FixRunner(runRoot: { fake.run($0) })
        let spotlight = OptimizeCatalog.tasks().first { $0.id == "spotlight" }!
        runner.run([spotlight])
        await waitUntilFinished(runner)
        XCTAssertEqual(fake.calls, ["spotlight"])
        guard case .failed(let message) = runner.results[0].status else {
            return XCTFail("a helper-reported failure must surface as .failed, got \(runner.results[0].status)")
        }
        XCTAssertTrue(message.contains("not permitted"))
    }

    func testRootRunnerNotCalledForUserOnlyTask() async {
        let fake = FakeRootRunner(ok: true)
        let runner = FixRunner(runRoot: { fake.run($0) })
        let quicklook = OptimizeCatalog.tasks().first { $0.id == "quicklook" }!   // user-only
        runner.run([quicklook])
        await waitUntilFinished(runner)
        XCTAssertTrue(fake.calls.isEmpty, "a user-only fix must never touch the helper")
        guard case .done = runner.results[0].status else {
            return XCTFail("user-only fix should be .done, got \(runner.results[0].status)")
        }
    }

    /// Spins until the runner reports it finished (the run is async/detached).
    private func waitUntilFinished(_ runner: FixRunner, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !runner.didFinish && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(runner.didFinish, "runner did not finish within \(timeout)s")
    }
}
