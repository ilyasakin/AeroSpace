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
        tile.believedRect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)

        let floating = TestWindow.new(
            id: 2,
            parent: workspace.floatingWindowsContainer,
            adaptiveWeight: WEIGHT_AUTO,
            rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300),
        )
        floating.believedRect = Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)

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
            ).believedRect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)
        }
        let floating = TestWindow.new(
            id: 2,
            parent: workspace.floatingWindowsContainer,
            adaptiveWeight: WEIGHT_AUTO,
            rect: nil,
        )
        floating.believedRect = nil

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

    /// Floating windows now get NATIVE macOS z-order: focusing a tile raises it, even when floats
    /// are present. The opposite used to hold — a private focus-without-raise call kept tiles from
    /// disturbing an i3-style float layer — and that machinery was removed because macOS offers no
    /// durable window level without a SIP-off scripting addition, so the layer drifted whenever
    /// anything else restacked and needed a click-interception tap and an AXRaise settle pipeline
    /// to paper over it.
    func testFocusingATileRaisesItEvenWhenFloatsExist() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 20, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 21, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        XCTAssertTrue(tile.workspaceHasFloatingWindows, "precondition: a float is present")

        tile.nativeFocusRespectingFloats()
        XCTAssertEqual(tile.lastNativeFocusRaise, true, "a focused tile raises natively")

        let floating = workspace.floatingWindows.first as! TestWindow
        floating.nativeFocusRespectingFloats()
        XCTAssertEqual(floating.lastNativeFocusRaise, true, "so does a focused float")
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

