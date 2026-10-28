@testable import AppBundle
import Common
import XCTest

/// Hover focus end-to-end on the headless harness: event sample → policy → FFM light session →
/// OS focus (raise policy) → re-anchoring after keyboard focus changes.
@MainActor
final class HoverFocusIntegrationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.focusFollowsMouse.enabled = true
        HoverFocus.resetForTests()
    }

    override func tearDown() async throws {
        HoverFocus.resetForTests()
    }

    private func hover(_ id: UInt32) async {
        HoverFocus.handle(HoverSample(point: .zero, windowIdUnderPointer: id))
        await HoverFocus.settleForTests()
    }

    func testHoverFocusesTileWithoutRaisingIt() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        await hover(2)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(w2.lastNativeFocusRaise, false, additionalMsg: "a hovered tile must not be raised over floats")
    }

    func testHoverRaisesFloatsAndHonoursRaiseConfig() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        let float = TestWindow.new(id: 2, parent: ws.floatingWindowsContainer)
        await hover(2)
        assertEquals(float.lastNativeFocusRaise, true)

        config.focusFollowsMouse.raise = true
        let tile = TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        await hover(3)
        assertEquals(tile.lastNativeFocusRaise, true)
    }

    func testKeyboardFocusChangeIsNotStolenBackByTheRestingPointer() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await ws.layoutWorkspace()
        // The pointer rests inside window 1
        let inside1 = try XCTUnwrap(w1.laidOutRect).center
        HoverFocus.pointerLocation = { inside1 }
        await hover(1)
        try await HeadlessHarness.run("focus right")
        assertEquals(focus.windowOrNil?.windowId, 2)
        // A nudge inside window 1: no enter → focus stays on 2 (i3)
        await hover(1)
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testUnmanagedWindowUnderPointerDoesNothing() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        await hover(4242) // a menu / the Dock / another app's popup
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testHoverRunsHeadlessly() async throws {
        Headless.resetForTests()
        HoverFocus.sync(config) // would install a global event tap
        XCTAssertEqual(Headless.blockedAttempts[.inputEventTap], 1)
        XCTAssertFalse(HoverFocus.isRunning)
    }
}
