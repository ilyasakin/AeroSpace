@testable import AppBundle
import XCTest

@MainActor
final class WindowServerEventReactionTest: XCTestCase {
    func testEventsMapToReactions() {
        XCTAssertEqual(WindowServerEvents.reaction(event: 806, isTracked: true), .repaintBorder)
        XCTAssertEqual(WindowServerEvents.reaction(event: 807, isTracked: false), .repaintBorder)
        for event: UInt32 in [804, 815, 816] {
            XCTAssertEqual(WindowServerEvents.reaction(event: event, isTracked: true), .refresh)
            XCTAssertEqual(WindowServerEvents.reaction(event: event, isTracked: false), .ignore,
                           "untracked windows must not trigger discovery")
        }
        XCTAssertEqual(WindowServerEvents.reaction(event: 811, isTracked: true), .ignore)
    }
}
