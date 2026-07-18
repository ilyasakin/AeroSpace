@testable import AppBundle
import Common
import XCTest

/// Guards the bar-flicker fix: on a workspace switch that also changes the focused window,
/// i3 IPC must emit **workspace** before **window**.
@MainActor
final class I3IpcEventOrderTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        i3IpcTestEventOrderSink = nil
    }

    override func tearDown() async throws {
        i3IpcTestEventOrderSink = nil
    }

    func testWorkspaceEventEmittedBeforeWindowEventOnWorkspaceSwitch() async {
        // Two workspaces, each with a window — switch changes both workspace and window focus.
        let wsA = Workspace.get(byName: "order-a")
        let wsB = Workspace.get(byName: "order-b")
        let winA = TestWindow.new(id: 501, parent: wsA.rootTilingContainer)
        let winB = TestWindow.new(id: 502, parent: wsB.rootTilingContainer)
        assertTrue(wsA.focusWorkspace())
        assertTrue(winA.focusWindow())
        // Establish baseline last-known focus (same path as a refresh session).
        await checkOnFocusChangedCallbacks_nonCancellable()

        var order: [String] = []
        i3IpcTestEventOrderSink = { order.append($0) }

        assertTrue(wsB.focusWorkspace())
        // Focus the window on B so frozen focus differs in both workspace and window id.
        assertTrue(winB.focusWindow())
        await checkOnFocusChangedCallbacks_nonCancellable()

        i3IpcTestEventOrderSink = nil

        // Both events must fire on this transition.
        XCTAssertTrue(order.contains("workspace"), "expected workspace event, got \(order)")
        XCTAssertTrue(order.contains("window"), "expected window event, got \(order)")
        let wi = order.firstIndex(of: "workspace")!
        let wini = order.firstIndex(of: "window")!
        XCTAssertTrue(wi < wini, "workspace must precede window (bar flicker guard); order=\(order)")
    }

    func testWindowOnlyFocusChangeDoesNotRequireWorkspaceEvent() async {
        let ws = Workspace.get(byName: "order-single")
        let w1 = TestWindow.new(id: 601, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 602, parent: ws.rootTilingContainer)
        assertTrue(ws.focusWorkspace())
        assertTrue(w1.focusWindow())
        await checkOnFocusChangedCallbacks_nonCancellable()

        var order: [String] = []
        i3IpcTestEventOrderSink = { order.append($0) }
        assertTrue(w2.focusWindow())
        await checkOnFocusChangedCallbacks_nonCancellable()
        i3IpcTestEventOrderSink = nil

        assertEquals(order.filter { $0 == "workspace" }, [])
        XCTAssertTrue(order.contains("window"), "expected window event, got \(order)")
    }
}
