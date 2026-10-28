@testable import AppBundle
import Common
import XCTest

/// Behaviour pinned to i3 semantics, driven end-to-end through the headless session harness.
@MainActor
final class I3ParityTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Headless.resetForTests()
    }

    /// Opens a new window the way discovery does: parked floating, then placed into tiling.
    @discardableResult
    private func openWindow(_ id: UInt32, on ws: Workspace? = nil) async throws -> TestWindow {
        let ws = ws ?? focus.workspace
        let w = TestWindow.new(id: id, parent: ws.floatingWindowsContainer)
        try await w.relayoutWindow(on: ws, .nonCancellable, forceTile: true)
        return w
    }

    // MARK: - Focus stack (MRU) survives structural commits

    func testFocusStackSurvivesNewWindowPlacement() async throws {
        // h[1 v[2 3]]; focus history 3, 2, 1 → the v container remembers 2 as its focused child
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        for id: UInt32 in [3, 2, 1] { _ = Window.get(byId: id)!.focusWindow() }

        try await openWindow(4) // structural commit (spine materialize)
        _ = Window.get(byId: 4)!.focusWindow()
        assertEquals(ws.i3Tree, "h[1 4* v[2 3]]")

        try await HeadlessHarness.run("focus right")
        // i3 descends into the neighbour container along its focus stack
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testCloseFocusFallsBackToPreviouslyFocusedAfterStructuralCommit() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        for id: UInt32 in [1, 3] { _ = Window.get(byId: id)!.focusWindow() }
        try await openWindow(4)
        _ = Window.get(byId: 4)!.focusWindow()

        try await HeadlessHarness.run("close")
        // focus history: 4 (closed) → 3 → 1
        assertEquals(focus.windowOrNil?.windowId, 3)
    }

    func testClosingLastFloatReturnsFocusToPreviousTile() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = Window.get(byId: 2)!.focusWindow()
        let float = TestWindow.new(id: 3, parent: ws.floatingWindowsContainer)
        _ = float.focusWindow()

        try await HeadlessHarness.run("close")
        // The empty floating container must not dead-end the focus stack (was: top-left tile 1)
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testParkingInMacosContainerIsNotAFocusEvent() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = Window.get(byId: 1)!.focusWindow()
        // e.g. a native tab parked, or a window entering native fullscreen
        w2.bind(to: ws.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        assertEquals(ws.toLiveFocus().windowOrNil?.windowId, 1)
        TestWindow.new(id: 3, parent: ws.macOsNativeFullscreenWindowsContainer)
        assertEquals(ws.toLiveFocus().windowOrNil?.windowId, 1)
    }

    // MARK: - macOS native state

    func testUnreadableNativeStateDoesNotFlapFullscreenWindow() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let video = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        video.isMacosFullscreenForTest = true
        await HeadlessHarness.heavy()
        XCTAssertTrue(video.parent is MacosFullscreenWindowsContainer)

        // App busy: the read fails. Unknown must not be treated as "exited fullscreen"
        video.nativeStateUnreadableForTest = true
        await HeadlessHarness.heavy()
        XCTAssertTrue(video.parent is MacosFullscreenWindowsContainer, "re-tiled on a failed AX read")
        assertEquals(ws.i3Tree, "h[1*]")

        // A successful read that says "not fullscreen" does re-tile
        video.nativeStateUnreadableForTest = false
        video.isMacosFullscreenForTest = false
        await HeadlessHarness.heavy()
        XCTAssertTrue(video.parent is TilingContainer)
    }

    // MARK: - resize (i3 commands.c cmd_resize_tiling_width_height)

    func testResizeRefusesToPushSiblingBelowOnePixel() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await ws.layoutWorkspace()
        let before = (w1.laidOutRect!, w2.laidOutRect!)

        let result = try await HeadlessHarness.run("resize width +5000")
        XCTAssertNotEqual(result.exitCode.rawValue, 0)
        // Nothing changed; no zero/negative spans
        assertEquals(w1.laidOutRect, before.0)
        assertEquals(w2.laidOutRect, before.1)
        XCTAssertGreaterThan(w2.getWeight(.h), 0)
    }

    func testResizePixelsBeforeFirstLayoutMeanPixels() async throws {
        // Fresh windows have weight 1; +100 px must not turn a 50/50 split into 101:1
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await ws.layoutWorkspace() // measures the parent's span
        try await HeadlessHarness.run("resize width +100")
        let d = w1.laidOutRect!.width - w2.laidOutRect!.width
        XCTAssertEqual(d, 200, accuracy: 2, "w1 grows 100px, w2 shrinks 100px")
    }

    func testResizePptOnTiledWindow() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        let r = try await HeadlessHarness.run("resize width +10%")
        assertEquals(r.stderr, [])
        let total = w1.laidOutRect!.width + w2.laidOutRect!.width
        XCTAssertEqual(w1.laidOutRect!.width / total, 0.6, accuracy: 0.01)
    }

    func testDirectionalResizeTradesWithOneNeighbourOnly() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        let w3 = TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        _ = w2.focusWindow()
        try await ws.layoutWorkspace()
        let before = (w1.laidOutRect!.width, w2.laidOutRect!.width, w3.laidOutRect!.width)
        try await HeadlessHarness.run("resize right +100") // i3: resize grow right 100 px
        XCTAssertEqual(w1.laidOutRect!.width, before.0, accuracy: 1, "the left neighbour is untouched")
        XCTAssertEqual(w2.laidOutRect!.width, before.1 + 100, accuracy: 2)
        XCTAssertEqual(w3.laidOutRect!.width, before.2 - 100, accuracy: 2)
        let r = try await HeadlessHarness.run("resize right +5000")
        XCTAssertNotEqual(r.exitCode.rawValue, 0)
    }

    func testMouseResizeClampKeepsEverySpanPositive() {
        // Siblings 100 and 50 each give up diff/2: 50 is the binding limit → diff <= (50-1)*2
        assertEquals(clampedMouseResizeDiff(500, growing: [300], shrinking: [100, 50], minimum: 1), 98)
        // Shrinking the dragged window below 1px
        assertEquals(clampedMouseResizeDiff(-500, growing: [300], shrinking: [100], minimum: 1), -299)
        assertEquals(clampedMouseResizeDiff(20, growing: [300], shrinking: [100], minimum: 1), 20)
    }

    // MARK: - heavy session hygiene / dwindle orientation

    func testHeavyNormalizesTreeBeforeLayoutAfterMinimize() async throws {
        config.enableNormalizationFlattenContainers = true
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        var w3: TestWindow!
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            w3 = TestWindow.new(id: 3, parent: $0)
        }
        w3.isMacosMinimizedForTest = true
        await HeadlessHarness.heavy()
        // The single-child v[2] wrapper must be gone BEFORE layout, not one session later
        assertEquals(ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[1 2]")
    }

    func testDwindleLayoutOrientationChangesOnlyTargetContainer() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let ws = focus.workspace
        ws.tilingPolicyOverride = .dwindle
        var c: TestWindow!
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                c = TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }
        _ = c.focusWindow()
        try await HeadlessHarness.run("layout vertical")
        assertEquals(ws.rootTilingContainer.i3Tree, "h[1 v[2 v[3* 4]]]")
    }

    // MARK: - macOS-state round trips keep the tile slot

    private func threeTiles(_ ws: Workspace) -> (TestWindow, TestWindow, TestWindow) {
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 2)
        let w3 = TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        _ = w3.focusWindow()
        return (w1, w2, w3)
    }

    func testUnminimizeReturnsToOriginalSlotAndWeight() async throws {
        let ws = focus.workspace
        let (_, w2, _) = threeTiles(ws)
        w2.isMacosMinimizedForTest = true
        await HeadlessHarness.heavy()
        assertEquals(ws.rootTilingContainer.i3Tree, "h[1 3*]")
        w2.isMacosMinimizedForTest = false
        await HeadlessHarness.heavy()
        // Middle slot and its 2:1:1 share, not appended beside the focused window
        assertEquals(ws.rootTilingContainer.i3Tree, "h[1 2 3*]")
        let widths = ws.rootTilingContainer.children.map { ($0 as! TestWindow).laidOutRect!.width }
        XCTAssertEqual(widths[1] / widths[0], 2, accuracy: 0.05)
    }

    func testExitNativeFullscreenReturnsToSlotEvenIfTreeChangedMeanwhile() async throws {
        let ws = focus.workspace
        let (_, w2, _) = threeTiles(ws)
        w2.isMacosFullscreenForTest = true
        await HeadlessHarness.heavy()
        try await openWindow(4) // beside the focused 3
        assertEquals(ws.rootTilingContainer.i3Tree, "h[1 3* 4]")
        w2.isMacosFullscreenForTest = false
        await HeadlessHarness.heavy()
        assertEquals(ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[1 2 3 4]")
    }

    func testClosingATabGroupsTileHolderHandsItsTileToTheNextTab() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let holder = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer).focusWindow()
        // Tab 4 of the same app is parked behind the holder
        let tab = TestWindow.new(id: 4, parent: ws.macOsNativeHiddenAppsWindowsContainer)
        tab.layoutReason = .macos(prevParentKind: .tilingContainer)
        holder.handOverTileToParkedTabSibling()
        holder.closeAxWindow()
        await HeadlessHarness.heavy()
        // The group keeps its tile: 4 is where 2 was, not appended beside the focused 3
        assertEquals(ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[1 4 3]")
    }

    func testAppHideUnhideReturnsToSlot() async throws {
        config.automaticallyUnhideMacosHiddenApps = false
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        _ = Window.get(byId: 1)!.focusWindow()
        TestApp.shared.isHidden = true
        defer { TestApp.shared.isHidden = false }
        await HeadlessHarness.heavy()
        TestApp.shared.isHidden = false
        await HeadlessHarness.heavy()
        assertEquals(ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[1 v[2 3]]")
    }

    // MARK: - fullscreen (i3 CF_OUTPUT)

    func testFullscreenSurvivesLayoutAndBlocksDirectionalFocus() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await HeadlessHarness.run("fullscreen on")
        try await HeadlessHarness.run("focus right") // single monitor: nowhere to go
        XCTAssertTrue(w1.isFullscreen)
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(w1.laidOutRect, ws.workspaceMonitor.visibleRectPaddedByOuterGaps)
    }

    func testFullscreenEndsWhenAnotherTileIsExplicitlyFocused() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await HeadlessHarness.run("fullscreen on")
        try await HeadlessHarness.run("focus --window-id 2")
        XCTAssertFalse(w1.isFullscreen)
    }

    func testNewWindowOpensBehindFullscreenWithoutTakingFocus() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w1.focusWindow()
        try await HeadlessHarness.run("fullscreen on")
        // The app opens a window and macOS focuses it
        let fresh = try await openWindow(3)
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = fresh
        await HeadlessHarness.heavy()
        XCTAssertTrue(w1.isFullscreen, "a new window must not end fullscreen")
        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(TestApp.shared.focusedWindow?.windowId, 1) // focus given back natively
        // ...and it is next in the focus stack after the fullscreen window
        try await HeadlessHarness.run("fullscreen off")
        assertEquals(ws.rootTilingContainer.windowsInFocusOrder.prefix(2).map(\.windowId), [1, 3])
    }

    func testOnlyOneFullscreenWindowPerWorkspace() async throws {
        let ws = focus.workspace
        let w1 = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run(["fullscreen on --window-id 1", "fullscreen on --window-id 2"])
        XCTAssertFalse(w1.isFullscreen)
        XCTAssertTrue(w2.isFullscreen)
    }

    func testFloatingFullscreenIsStickyAndRestoresFrame() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let float = TestWindow.new(id: 2, parent: ws.floatingWindowsContainer, rect: Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300))
        float.frame.adopt(Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300))
        _ = float.focusWindow()
        try await HeadlessHarness.run("fullscreen on")
        try await HeadlessHarness.run("balance-sizes") // any further layout pass
        XCTAssertTrue(float.isFullscreen, "was cleared after one layout pass")
        assertEquals(float.laidOutRect, ws.workspaceMonitor.visibleRectPaddedByOuterGaps)
        try await HeadlessHarness.run("fullscreen off")
        assertEquals(float.laidOutRect, Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300))
    }

    func testMoveToWorkspaceLandsAfterTargetsFocusedWindow() async throws {
        let ws1 = focus.workspace
        let ws2 = Workspace.get(byName: "ws2")
        TestWindow.new(id: 1, parent: ws2.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws2.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        Window.get(byId: 2)!.markAsMostRecentChild() // ws2's focused window
        TestWindow.new(id: 9, parent: ws1.rootTilingContainer).focusWindow()
        try await HeadlessHarness.run("move-node-to-workspace ws2")
        assertEquals(ws2.rootTilingContainer.i3Tree, "h[1 v[2 9 3]]")
    }
}

final class LayoutToggleCycleTest: XCTestCase {
    func testCyclesToTheEntryAfterTheCurrentOne() {
        let list: [LayoutCmdArgs.LayoutDescription] = [.h_tiles, .v_tiles, .h_accordion]
        XCTAssertEqual(nextLayoutInToggleList(list) { $0 == .h_tiles }, .v_tiles)
        XCTAssertEqual(nextLayoutInToggleList(list) { $0 == .v_tiles }, .h_accordion) // was .h_tiles
        XCTAssertEqual(nextLayoutInToggleList(list) { $0 == .h_accordion }, .h_tiles)
        XCTAssertEqual(nextLayoutInToggleList(list) { _ in false }, .h_tiles)
        XCTAssertEqual(nextLayoutInToggleList([.tiles]) { $0 == .tiles }, .tiles)
    }
}
