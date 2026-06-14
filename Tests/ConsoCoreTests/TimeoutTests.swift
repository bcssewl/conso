import XCTest
@testable import ConsoCore

final class TimeoutTests: XCTestCase {
    func testReturnsValueWhenOperationIsFast() async throws {
        let v = try await withTimeout(seconds: 1.0) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testCompletesJustBeforeDeadlineDoesNotThrow() async throws {
        let v = try await withTimeout(seconds: 2.0) {
            try await Task.sleep(for: .milliseconds(50))
            return "ok"
        }
        XCTAssertEqual(v, "ok")
    }

    func testThrowsTimeoutWhenOperationIsSlow() async {
        do {
            _ = try await withTimeout(seconds: 0.1) {
                try await Task.sleep(for: .seconds(2))
                return 7
            }
            XCTFail("expected TimeoutError to be thrown")
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    /// Mirrors a model call that ignores cancellation: even though the operation keeps looping
    /// (~1s) and swallows every `CancellationError`, `withTimeout` must return at the deadline.
    func testTimesOutEvenWhenOperationIgnoresCancellation() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withTimeout(seconds: 0.2) {
                for _ in 0..<10 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch {}
                }
                return 7
            }
            XCTFail("expected TimeoutError to be thrown")
        } catch is TimeoutError {
            let elapsed = start.duration(to: clock.now)
            XCTAssertLessThan(elapsed, .milliseconds(500),
                              "withTimeout must return at the deadline, not wait for the operation")
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }
}
