@testable import AppBundle
import Common
import XCTest

/// A beachballing app must not stall the window manager: cancelling an awaited AX job returns
/// immediately, and discovery gives up on one slow app instead of waiting for it.
@MainActor
final class HungAppIsolationTest: XCTestCase {
    private func startRunLoopThread() -> Thread {
        let thread = Thread {
            RunLoop.current.add(Port(), forMode: .default)
            CFRunLoopRun()
        }
        thread.start()
        return thread
    }

    func testCancelledRunInLoopResumesWithoutWaitingForTheAppThread() async throws {
        let thread = startRunLoopThread()
        defer { thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) } }
        // The "app" is busy for 1.5s (e.g. an AX call waiting out the messaging timeout)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in Thread.sleep(forTimeInterval: 1.5) }

        let start = Date.now
        let task = Task.startUnstructured { @MainActor in
            try await thread.runInLoop(.cancellable) { _ in 42 }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        let elapsed = start.distance(to: .now)
        XCTAssertThrowsError(try result.get())
        XCTAssertLessThan(elapsed, 0.5, "cancellation must not wait for the busy app thread (\(elapsed)s)")
    }

    func testDeadlineFallsBackForSlowOperation() async throws {
        let start = Date.now
        let value = try await withDeadline(seconds: 0.05, fallback: [1, 2]) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [9]
        }
        XCTAssertEqual(value, [1, 2])
        XCTAssertLessThan(start.distance(to: .now), 0.5)
    }

    func testDeadlineReturnsFastOperationResult() async throws {
        let value = try await withDeadline(seconds: 1, fallback: [1]) { [7] }
        XCTAssertEqual(value, [7])
    }

    func testResumeOnceIgnoresSecondResumeAndEarlyCancel() async throws {
        let once = ResumeOnce<Int>()
        once.resume(.failure(CancellationError())) // before install
        once.resume(.success(1)) // ignored
        let value: Int? = try? await withCheckedThrowingContinuation { once.install($0) }
        XCTAssertNil(value)
    }
}

final class AxLivenessTest: XCTestCase {
    func testLiveness() {
        XCTAssertTrue(axWindowIsAlive(getWindowResult: (.success, 42), windowId: 42, listedIds: []))
        XCTAssertFalse(axWindowIsAlive(getWindowResult: (.invalidUIElement, 0), windowId: 42, listedIds: nil))
        // Busy app: GetWindow timed out AND kAXWindows didn't answer → keep
        XCTAssertTrue(axWindowIsAlive(getWindowResult: (.cannotComplete, 0), windowId: 42, listedIds: nil))
        // The app answered and the window is gone from its list → dead
        XCTAssertFalse(axWindowIsAlive(getWindowResult: (.failure, 0), windowId: 42, listedIds: [7]))
        XCTAssertTrue(axWindowIsAlive(getWindowResult: (.failure, 0), windowId: 42, listedIds: [42]))
    }
}
