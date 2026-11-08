@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class SingleFlightDeadlineTest: XCTestCase {
    func testAStuckKeyGetsTheFallbackWithoutWaitingOrQueueingAgain() async throws {
        let flights = SingleFlightDeadline<Int>()
        let gate = Gate()
        let runs = Counter()
        let first = await flights.run(1, seconds: 0.05, fallback: [0]) {
            runs.n += 1
            await gate.wait()
            return [1]
        }
        assertEquals(first, [0]) // past the deadline: fallback, work keeps running
        XCTAssertTrue(flights.isInFlight(1))

        let start = Date()
        let second = await flights.run(1, seconds: 5, fallback: [0]) {
            runs.n += 1
            return [2]
        }
        assertEquals(second, [0])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "no deadline wait for a stuck key")
        assertEquals(runs.n, 1, additionalMsg: "no second request queued behind the stuck one")

        // Other keys are unaffected
        assertEquals(await flights.run(2, seconds: 5, fallback: [0]) { [3] }, [3])

        // Once the stuck run finishes, the key runs normally again
        gate.open()
        for _ in 0 ..< 100 where flights.isInFlight(1) { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(flights.isInFlight(1))
        assertEquals(await flights.run(1, seconds: 5, fallback: [0]) { [4] }, [4])
    }

    func testAThrowingRunReleasesTheKey() async {
        let flights = SingleFlightDeadline<Int>()
        struct Boom: Error {}
        assertEquals(await flights.run(1, seconds: 5, fallback: 0) { throw Boom() }, 0)
        XCTAssertFalse(flights.isInFlight(1))
    }
}

@MainActor private final class Counter { var n = 0 }

@MainActor private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
