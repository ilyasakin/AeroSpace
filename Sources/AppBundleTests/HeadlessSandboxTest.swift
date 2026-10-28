@testable import AppBundle
import Common
import HotKey
import XCTest

/// The test suite must never disturb the user's desktop or a running AeroSpace: every outward side
/// effect goes through `Headless.permits`, which refuses under XCTest. These tests drive the paths
/// that reach each effect and assert the gate saw (and refused) them.
@MainActor
final class HeadlessSandboxTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Headless.resetForTests()
    }

    func testFullSessionsRunHeadlessly() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = Window.get(byId: 2)?.focusWindow()

        try await HeadlessHarness.run("focus left")
        assertEquals(focus.windowOrNil?.windowId, 1)
        try await HeadlessHarness.run("move right")
        assertEquals(ws.i3Tree, "h[2 1*]")
        await HeadlessHarness.heavy()

        // Under test a heavy talks to the simulated desktop, never to running apps
        assertEquals(MacApp.allAppsMap.count, 0)
        assertEquals(Headless.blockedAttempts[.accessibilityClient] ?? 0, 0)
    }

    /// Defence in depth behind the port: even the production port, if a test reached it, cannot
    /// register the user's apps — or layout would write frames to their real windows
    func testProductionPortIsStillGated() async throws {
        try await SystemMacOS.shared.discoverWindows()
        assertEquals(MacApp.allAppsMap.count, 0)
        XCTAssertGreaterThan(Headless.blockedAttempts[.accessibilityClient] ?? 0, 0)
    }

    func testLayoutWritesOnlyReachTestWindows() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run("balance-sizes")
        let r1 = try XCTUnwrap(w1.laidOutRect)
        let r2 = try XCTUnwrap(w2.laidOutRect)
        XCTAssertLessThan(r1.maxX, r2.minX + 1, "two tiles side by side")
    }

    func testProcessSpawnIsRefused() async throws {
        try await HeadlessHarness.run("exec-and-forget touch /tmp/aerospace-headless-must-not-exist")
        XCTAssertEqual(Headless.blockedAttempts[.spawnProcess], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/aerospace-headless-must-not-exist"))
    }

    func testCursorIsNeverMoved() async throws {
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("move-mouse monitor-force-center")
        XCTAssertEqual(Headless.blockedAttempts[.synthesizeInput], 1)
    }

    func testGlobalHotkeysAreNeverRegistered() async throws {
        let binding = HotkeyBinding(.option, .h, .cmd(FocusCommand.new(direction: .left)))
        config.modes = [mainModeId: Mode(bindings: [binding.descriptionWithKeyCode: binding])]
        await activateMode_nonCancellable(mainModeId)
        XCTAssertEqual(Headless.blockedAttempts[.globalHotkey], 1)
        resetHotKeys()
    }

    func testSocketsAreNeverBound() {
        startUnixSocketServer()
        startI3IpcServer()
        XCTAssertEqual(Headless.blockedAttempts[.socketListener], 2)
    }

    func testDefaultWindowServerIsEmptyUnderTest() {
        // Test ids are small integers; the user's session has real windows with the same ids.
        for id in UInt32(1) ... 200 {
            XCTAssertNil(WindowServerReads.current.windowBounds(windowId: id, forOverlay: true))
        }
        XCTAssertTrue(WindowServerReads.current.onScreenSnapshot().normalStack.isEmpty)
    }
}
