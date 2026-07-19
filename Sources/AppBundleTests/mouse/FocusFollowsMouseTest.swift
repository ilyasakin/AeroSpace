@testable import AppBundle
import Common
import XCTest

/// Floating windows must beat tiles they cover in FFM hit testing (z-order), or hover
/// focuses the tile underneath and nativeFocus raises it over the float.
@MainActor
final class FocusFollowsMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() {
        WindowServerReads.install(nil)
        super.tearDown()
    }

    func testFloatingWindowBeatsTileUnderCursor() {
        // Put windows on the focused/active workspace (what FFM hit-tests).
        let workspace = focus.workspace
        var tile: Window!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(
                id: 1,
                parent: $0,
                adaptiveWeight: 1,
                rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600),
            )
        }
        tile.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)

        let floating = TestWindow.new(
            id: 2,
            parent: workspace.floatingWindowsContainer,
            adaptiveWeight: WEIGHT_AUTO,
            rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300),
        )
        floating.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)

        // Front-to-back: floating first
        let fake = FakeStackPort()
        fake.snapshot = OnScreenWindowSnapshot(
            levels: [1: .normalWindow, 2: .normalWindow],
            normalStack: [
                (id: 2, rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)),
                (id: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)),
            ],
        )
        WindowServerReads.install(fake)

        let overFloat = CGPoint(x: 400, y: 300)
        let hit = windowUnderMouseCheap(overFloat)
        XCTAssertEqual(hit?.windowId, 2, "float must win over the tile it covers")

        let overTileOnly = CGPoint(x: 50, y: 50)
        let hitTile = windowUnderMouseCheap(overTileOnly)
        XCTAssertEqual(hitTile?.windowId, 1, "exposed tile still receives hover")
    }

    func testFloatingUsesLiveBoundsWhenLastAppliedNil() {
        let workspace = focus.workspace
        workspace.rootTilingContainer.apply {
            TestWindow.new(
                id: 1,
                parent: $0,
                adaptiveWeight: 1,
                rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600),
            ).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        }
        let floating = TestWindow.new(
            id: 2,
            parent: workspace.floatingWindowsContainer,
            adaptiveWeight: WEIGHT_AUTO,
            rect: nil,
        )
        floating.lastAppliedLayoutPhysicalRect = nil

        let fake = FakeStackPort()
        fake.boundsById[2] = Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)
        fake.snapshot = OnScreenWindowSnapshot(
            levels: [1: .normalWindow, 2: .normalWindow],
            normalStack: [
                (id: 2, rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)),
                (id: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)),
            ],
        )
        WindowServerReads.install(fake)

        XCTAssertEqual(floatingWindowFrame(floating)?.width, 400)
        XCTAssertEqual(windowUnderMouseCheap(CGPoint(x: 400, y: 300))?.windowId, 2)
    }

    func testRaiseFloatingWindowsAboveTilingIsNoOpWithoutFloats() {
        // Smoke: no floats → must not crash
        raiseFloatingWindowsAboveTiling()
    }

    func testRaiseFloatingWindowsAboveTilingTouchesFloatsOnly() {
        let workspace = focus.workspace
        var tile: Window!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 10, parent: $0, adaptiveWeight: 1)
        }
        let floating = TestWindow.new(id: 11, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        XCTAssertTrue(floating.isFloating)
        XCTAssertFalse(tile.isFloating)
        // TestWindow.nativeRaise is a no-op; just ensure the helper enumerates without error
        raiseFloatingWindowsAboveTiling()
    }

    func testNativeFocusRespectingFloatsDoesNotRaiseTileWhenFloatsExist() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 20, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 21, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)

        let port = RecordingFloatLayerPortForFfm()
        port.stack = [21, 20]
        FloatLayer.port = port
        defer { FloatLayer.port = nil }

        tile.nativeFocusRespectingFloats()
        XCTAssertTrue(port.focusWithoutRaiseCalls.contains(where: { $0.windowId == 20 }))
        XCTAssertFalse(port.raiseCalls.contains(20), "tile must not raise when floats exist")

        let floating = workspace.floatingWindows.first as! TestWindow
        floating.nativeFocusRespectingFloats()
        XCTAssertEqual(floating.lastNativeFocusRaise, true, "float may raise")
    }

    func testNativeFocusRespectingFloatsRaisesTileWithoutFloats() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 30, parent: $0, adaptiveWeight: 1)
        }
        FloatLayer.port = RecordingFloatLayerPortForFfm()
        defer { FloatLayer.port = nil }
        tile.nativeFocusRespectingFloats()
        XCTAssertEqual(tile.lastNativeFocusRaise, true)
    }

    func testFocusFollowsMousePlanSkipsEndOfSessionNativeFocusPath() {
        // Body owns nativeFocus; pipeline must skip re-nativeFocus (would raise:true and undo).
        let plan = SessionPipeline.planLight(event: .focusFollowsMouse)
        XCTAssertTrue(plan.skipFocusAndHygiene)
    }

    func testWorkspaceHasFloatingWindowsReflectsFloatContainer() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 40, parent: $0, adaptiveWeight: 1)
        }
        XCTAssertFalse(tile.workspaceHasFloatingWindows)
        _ = TestWindow.new(id: 41, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        XCTAssertTrue(tile.workspaceHasFloatingWindows)
    }
}

private final class FakeStackPort: WindowServerReadPort {
    var boundsById: [UInt32: Rect] = [:]
    var snapshot = OnScreenWindowSnapshot(levels: [:], normalStack: [])

    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? { boundsById[windowId] }
    func onScreenSnapshot() -> OnScreenWindowSnapshot { snapshot }
}

@MainActor
private final class RecordingFloatLayerPortForFfm: FloatLayerPort {
    var focusWithoutRaiseCalls: [(pid: pid_t, windowId: UInt32)] = []
    var raiseCalls: [UInt32] = []
    var stack: [UInt32]? = []

    func focusWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool {
        focusWithoutRaiseCalls.append((pid, windowId))
        return true
    }

    func raiseWindow(windowId: UInt32) { raiseCalls.append(windowId) }
    func frontToBackWindowIds() -> [UInt32]? { stack }
}
