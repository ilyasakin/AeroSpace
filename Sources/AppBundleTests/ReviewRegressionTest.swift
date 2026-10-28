@testable import AppBundle
import Common
import XCTest

/// Regressions found in review of the i3-parity / performance work.
@MainActor
final class ReviewRegressionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetRuntimeGapsOverrides()
    }

    override func tearDown() async throws { resetRuntimeGapsOverrides() }

    private var ws: Workspace { focus.workspace }

    func testFocusLayersSeeRealFloatsEvenWhenTheyHaveFrames() async throws {
        let tile = TestWindow.new(id: 1, parent: ws.rootTilingContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080))
        _ = tile.focusWindow()
        TestWindow.new(id: 2, parent: ws.floatingWindowsContainer, rect: Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200))
        try await ws.layoutWorkspace()
        try await HeadlessHarness.run("focus floating")
        assertEquals(focus.windowOrNil?.windowId, 2)
        try await HeadlessHarness.run("focus tiling")
        assertEquals(focus.windowOrNil?.windowId, 1)
        XCTAssertTrue(Window.get(byId: 2)?.isFloating == true, "the float stayed a float")
    }

    func testI3DirectionalFocusCyclesFloatsLeftRightOnly() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let f1 = TestWindow.new(id: 2, parent: ws.floatingWindowsContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100))
        TestWindow.new(id: 3, parent: ws.floatingWindowsContainer, rect: Rect(topLeftX: 500, topLeftY: 0, width: 100, height: 100))
        _ = f1.focusWindow()
        try await HeadlessHarness.run("focus right")
        assertEquals(focus.windowOrNil?.windowId, 3)
        try await HeadlessHarness.run("focus right") // wraps among floats
        assertEquals(focus.windowOrNil?.windowId, 2)
        try await HeadlessHarness.run("focus up") // no-op for floats
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testI3NormalizationSplitReorientsOnlyTheTarget() async throws {
        config.i3Normalization = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0).focusWindow()
        }
        try await HeadlessHarness.run("split horizontal")
        assertEquals(ws.rootTilingContainer.i3Tree.replacingOccurrences(of: "*", with: ""), "h[1 h[2]]")
    }

    func testWindowWithoutAFullscreenAttributeStillMinimizes() {
        // AXFullScreen missing (can't go fullscreen) but AXMinimized read fine → known state
        assertEquals(macosNativeState(fullscreen: nil, minimized: true), MacosNativeWindowState(isFullscreen: false, isMinimized: true))
        XCTAssertNil(macosNativeState(fullscreen: nil, minimized: nil), "the app didn't answer at all: unknown")
    }

    func testMovingAFullscreenWindowOntoAFullscreenWorkspaceYields() async throws {
        let other = Workspace.get(byName: "other")
        let x = TestWindow.new(id: 9, parent: other.rootTilingContainer)
        x.enterFullscreen(noOuterGaps: false)
        let w = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        _ = w.focusWindow()
        w.enterFullscreen(noOuterGaps: false)
        try await HeadlessHarness.run("move-node-to-workspace other")
        XCTAssertTrue(x.isFullscreen)
        XCTAssertFalse(w.isFullscreen, "one fullscreen window per workspace")
    }

    func testSwapWithAParkedMarkedWindowIsRefused() async throws {
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow()
        let parked = TestWindow.new(id: 2, parent: ws.macOsNativeHiddenAppsWindowsContainer)
        parked.marks = ["m"]
        let r = try await HeadlessHarness.run("swap --with-mark m")
        XCTAssertNotEqual(r.exitCode.rawValue, 0)
        XCTAssertTrue(parked.parent is MacosHiddenAppsWindowsContainer)
    }

    func testCriteriaWithMultiCommandMappingParsesAsSeparateCommands() {
        let mapped = i3MapCommandToAerospaceCommands(#"[class="X"] resize set 800 600"#)
        assertEquals(mapped, [#"[class="X"] resize width 800"#, #"[class="X"] resize height 600"#])
        for m in mapped { XCTAssertNil(parseCommand(m).errorOrNil, m) }
    }

    func testCriteriaCarryAcrossCommaAndResetAtSemicolon() {
        assertEquals(i3MapCommandToAerospaceCommands(#"[class="X"] move to workspace 3, focus"#),
                     [#"[class="X"] move-node-to-workspace 3"#, #"[class="X"] focus"#])
        assertEquals(i3MapCommandToAerospaceCommands(#"[class="X"] kill; focus left"#),
                     [#"[class="X"] close"#, "focus left"])
        // A quoted comma is not a separator
        assertEquals(i3MapCommandToAerospaceCommands(#"[title="a, b"] kill"#), [#"[title="a, b"] close"#])
    }

    func testCriteriaValueWithQuoteCharactersParses() {
        XCTAssertNil(parseCommand(#"[title="it's"] focus"#).errorOrNil)
    }

    func testI3CommandsKeepTheirOptionalWordsAndAreCaseInsensitive() {
        assertEquals(i3MapCommandToAerospace("move container workspace 3"), "move-node-to-workspace 3")
        assertEquals(i3MapCommandToAerospace("move workspace 3"), "move-node-to-workspace 3")
        assertEquals(i3MapCommandToAerospace("focus Left"), "focus left")
        assertEquals(i3MapCommandToAerospace("move container to workspace number 3"), "move-node-to-workspace --number 3")
        assertEquals(i3MapCommandToAerospace(#"rename workspace to "go to bed""#), "rename-workspace gotobed")
    }

    func testDiscoveryDeadlineLetsTheWorkFinish() async {
        var finished = false
        let value = await withDeadlineLettingWorkFinish(seconds: 0.02, fallback: 0) {
            try await Task.sleep(nanoseconds: 100_000_000)
            finished = true
            return 1
        }
        assertEquals(value, 0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(finished, "the slow work was not thrown away")
    }

    func testGapsPlusCountsFromConfiguredGapsUnderSmartGaps() async throws {
        config.smartGaps = true
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 5, bottom: 5, top: 5, right: 5))
        TestWindow.new(id: 1, parent: ws.rootTilingContainer).focusWindow() // single tile: smart gaps zero
        try await HeadlessHarness.run("gaps inner current plus 4")
        assertEquals(ws.configuredGaps.inner.horizontal, 14)
    }
}
