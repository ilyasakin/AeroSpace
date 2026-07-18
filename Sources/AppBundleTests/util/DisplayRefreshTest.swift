@testable import AppBundle
import AppKit
import CoreVideo
import XCTest

@MainActor
final class DisplayRefreshTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testHzForMainDisplayIsSane() {
        let id = CGMainDisplayID()
        let hz = DisplayRefresh.hz(forDisplayId: id)
        XCTAssertGreaterThanOrEqual(hz, 30)
        XCTAssertLessThanOrEqual(hz, 500)
    }

    func testFrameIntervalIsInverseOfHz() {
        let ws = Workspace.get(byName: name)
        let hz = DisplayRefresh.hz(for: ws)
        XCTAssertEqual(DisplayRefresh.frameInterval(for: ws), 1.0 / hz, accuracy: 1e-9)
    }

    func testDisplayIdForScreenRoundTrip() {
        guard let screen = NSScreen.screens.first,
              let id = DisplayRefresh.displayId(forScreen: screen)
        else {
            XCTFail("no screens")
            return
        }
        let again = DisplayRefresh.nsScreen(forDisplayId: id)
        XCTAssertEqual(DisplayRefresh.displayId(forScreen: again!), id)
    }

    func testWorkspaceDisplayLinkSubscribeUnsubscribe() {
        let id = CGMainDisplayID()
        let sub = UUID()
        var pulses = 0
        WorkspaceDisplayLink.subscribe(displayId: id, id: sub) {
            pulses += 1
        }
        XCTAssertNotNil(WorkspaceDisplayLink.activeRefreshHz(for: id))
        WorkspaceDisplayLink.unsubscribe(displayId: id, id: sub)
        XCTAssertNil(WorkspaceDisplayLink.activeRefreshHz(for: id))
        // No crash; pulse count is best-effort (may be 0 if link was slow to start)
        _ = pulses
    }
}
