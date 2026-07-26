@testable import AppBundle
import Common
import XCTest

/// The quit path blocks the main thread on AX replies because it must finish before the process
/// exits. Unbounded, one unresponsive app meant AeroSpace could never quit — the only way out was
/// `kill -9`, which skips the window-restore sweep entirely.
@MainActor
final class TerminationBudgetTest: XCTestCase {
    override func tearDown() async throws {
        AxTerminationBudget.resetForTests()
    }

    func testBudgetIsTotalNotPerWindow() {
        AxTerminationBudget.resetForTests()

        // First claim starts the clock and offers the whole budget.
        let first = AxTerminationBudget.claim()
        XCTAssertEqual(first, AxTerminationBudget.total, accuracy: 0.001)

        // Subsequent claims draw down the SAME budget rather than each getting a fresh one —
        // otherwise N windows x per-window timeout still adds up to an arbitrarily long hang.
        let second = AxTerminationBudget.claim()
        XCTAssertLessThanOrEqual(second, first)
        XCTAssertGreaterThan(second, 0, "budget should not be exhausted immediately")
    }

    func testClaimNeverReturnsNegative() {
        AxTerminationBudget.resetForTests()
        _ = AxTerminationBudget.claim()
        // Even long after the deadline, a claim is clamped to 0 (wait returns at once) rather than
        // going negative, which DispatchTime arithmetic would turn into a wait in the past.
        for _ in 0 ..< 3 {
            XCTAssertGreaterThanOrEqual(AxTerminationBudget.claim(), 0)
        }
    }
}

final class CompletableFutureTimeoutTest: XCTestCase {
    func testBlockingGetWithTimeoutReturnsNilWhenNeverCompleted() {
        let future = CompletableFuture<Int>()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(future.blockingGet(timeout: 0.05), "an uncompleted future must time out, not hang")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 2.0, "should return promptly after the timeout, not block")
    }

    func testBlockingGetWithTimeoutReturnsValueWhenCompleted() {
        let future = CompletableFuture<Int>()
        future.complete(42)
        XCTAssertEqual(future.blockingGet(timeout: 1.0), 42)
    }

    func testZeroTimeoutOnAlreadyCompletedFutureStillReturnsValue() {
        let future = CompletableFuture<Int>()
        future.complete(7)
        // Budget-exhausted case: the wait is already satisfied, so the value is still delivered.
        XCTAssertEqual(future.blockingGet(timeout: 0), 7)
    }
}
