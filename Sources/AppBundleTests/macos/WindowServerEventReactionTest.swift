@testable import AppBundle
import XCTest

@MainActor
final class WindowServerEventReactionTest: XCTestCase {
    func testMovesRepaintBorders() {
        XCTAssertEqual(WindowServerEvents.reaction(event: 806, belief: .visible), .repaintBorder)
        XCTAssertEqual(WindowServerEvents.reaction(event: 807, belief: .untracked), .repaintBorder)
    }

    /// Only events that contradict the model re-run discovery: shown/hidden fire on every native
    /// tab switch, and refreshing on each ran a discovery storm
    func testOnlyContradictionsRefresh() {
        XCTAssertEqual(WindowServerEvents.reaction(event: 815, belief: .hiddenByMacos), .refresh, "unminimized behind AX's back")
        XCTAssertEqual(WindowServerEvents.reaction(event: 815, belief: .visible), .ignore)
        XCTAssertEqual(WindowServerEvents.reaction(event: 815, belief: .other), .ignore, "a background tab ordered in")
        XCTAssertEqual(WindowServerEvents.reaction(event: 816, belief: .visible), .refresh, "a visible window went away")
        XCTAssertEqual(WindowServerEvents.reaction(event: 816, belief: .hiddenByMacos), .ignore)
        XCTAssertEqual(WindowServerEvents.reaction(event: 816, belief: .other), .ignore)
        XCTAssertEqual(WindowServerEvents.reaction(event: 804, belief: .other), .refresh)
        for event: UInt32 in [804, 815, 816] {
            XCTAssertEqual(WindowServerEvents.reaction(event: event, belief: .untracked), .ignore)
        }
        XCTAssertEqual(WindowServerEvents.reaction(event: 811, belief: .visible), .ignore)
    }
}
