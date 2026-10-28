@testable import AppBundle
import Common
import XCTest

final class MouseWarpingTest: XCTestCase {
    private let left = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
    private let right = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 800)
    private let win = Rect(topLeftX: 1100, topLeftY: 100, width: 400, height: 300)

    func testOutputWarpsOnlyAcrossMonitors() {
        XCTAssertEqual(mouseWarpTarget(mode: .output, pointer: CGPoint(x: 10, y: 10), focusedWindowRect: win,
                                       focusedMonitorRect: right, focusedMonitorChanged: true), right.center)
        XCTAssertNil(mouseWarpTarget(mode: .output, pointer: CGPoint(x: 10, y: 10), focusedWindowRect: win,
                                     focusedMonitorRect: left, focusedMonitorChanged: false))
        // Already on the target monitor
        XCTAssertNil(mouseWarpTarget(mode: .output, pointer: CGPoint(x: 1500, y: 10), focusedWindowRect: win,
                                     focusedMonitorRect: right, focusedMonitorChanged: true))
    }

    func testContainerWarpsIntoTheFocusedWindowLazily() {
        XCTAssertEqual(mouseWarpTarget(mode: .container, pointer: CGPoint(x: 10, y: 10), focusedWindowRect: win,
                                       focusedMonitorRect: right, focusedMonitorChanged: false), win.center)
        XCTAssertNil(mouseWarpTarget(mode: .container, pointer: win.center, focusedWindowRect: win,
                                     focusedMonitorRect: right, focusedMonitorChanged: false))
    }

    func testNoneNeverWarps() {
        XCTAssertNil(mouseWarpTarget(mode: .none, pointer: .zero, focusedWindowRect: win,
                                     focusedMonitorRect: right, focusedMonitorChanged: true))
    }

    @MainActor
    func testCommandFocusChangeWarpsHeadlessly() async throws {
        setUpWorkspacesForTests()
        Headless.resetForTests()
        config.mouseWarping = .container
        HoverFocus.pointerLocation = { CGPoint(x: -500, y: -500) }
        defer { HoverFocus.resetForTests() }
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await ws.layoutWorkspace()
        try await HeadlessHarness.run("balance-sizes") // settle the focus change made outside a session
        Headless.resetForTests()
        try await HeadlessHarness.run("focus right")
        XCTAssertEqual(Headless.blockedAttempts[.synthesizeInput], 1, "the warp is attempted (and refused under test)")
    }
}
