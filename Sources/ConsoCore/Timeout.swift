import Foundation

/// Thrown by `withTimeout` when the operation does not finish before the deadline.
public struct TimeoutError: Error, Equatable {
    public init() {}
}

/// Holds the in-flight continuation + the two racing child tasks behind a lock so the
/// continuation resumes exactly once and the loser task is always cancelled. `@unchecked
/// Sendable` because all mutable state is guarded by `lock`.
private final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var resumed = false

    func setContinuation(_ cont: CheckedContinuation<T, Error>) {
        lock.lock()
        continuation = cont
        lock.unlock()
    }

    func setTasks(_ op: Task<Void, Never>, _ timer: Task<Void, Never>) {
        lock.lock()
        // If we already resolved (e.g. an instantly-failing op), don't keep them running.
        if resumed {
            lock.unlock()
            op.cancel()
            timer.cancel()
            return
        }
        operationTask = op
        timerTask = timer
        lock.unlock()
    }

    /// Resumes the continuation on the FIRST call only, then best-effort-cancels both tasks.
    /// On the timeout path the operation task is abandoned (not awaited): if it ignores
    /// cancellation it keeps running, but we have already returned to the caller.
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let cont = continuation
        let op = operationTask
        let timer = timerTask
        continuation = nil
        operationTask = nil
        timerTask = nil
        lock.unlock()

        cont?.resume(with: result)
        op?.cancel()
        timer?.cancel()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

/// Runs `operation`, returning its value if it finishes within `seconds`; otherwise throws
/// `TimeoutError` and abandons the operation.
///
/// Unlike a `withThrowingTaskGroup`, this returns to the caller at the deadline REGARDLESS of
/// whether the operation honors cancellation — the slow operation task is best-effort-cancelled
/// but never awaited on the timeout path. Used to bound on-device model calls (Doctor /
/// Explainer / Ask conso) so a stalled model always resolves to the deterministic fallback
/// instead of spinning "thinking…" forever, even if `LanguageModelSession.respond` swallows
/// cancellation.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let state = TimeoutState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            state.setContinuation(cont)
            let op = Task {
                do { state.finish(.success(try await operation())) }
                catch { state.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                state.finish(.failure(TimeoutError()))
            }
            state.setTasks(op, timer)
        }
    } onCancel: {
        state.cancel()
    }
}
