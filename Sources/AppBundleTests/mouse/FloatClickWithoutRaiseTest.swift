@testable import AppBundle
import Common
import XCTest

@MainActor
final class FloatClickWithoutRaiseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPolicyPassThroughWhenNoFloats() {
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.shouldIntercept(
                topmostIsFloating: false,
                topmostIsTiling: true,
                workspaceHasFloats: false,
                isAeroSpaceWindow: false,
                dragInProgress: false,
            ),
        )
    }

    func testPolicyPassThroughWhenTopIsFloat() {
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.shouldIntercept(
                topmostIsFloating: true,
                topmostIsTiling: false,
                workspaceHasFloats: true,
                isAeroSpaceWindow: false,
                dragInProgress: false,
            ),
        )
    }

    func testPolicyInterceptExposedTileWhenFloatsExist() {
        XCTAssertTrue(
            FloatClickWithoutRaisePolicy.shouldIntercept(
                topmostIsFloating: false,
                topmostIsTiling: true,
                workspaceHasFloats: true,
                isAeroSpaceWindow: false,
                dragInProgress: false,
            ),
        )
    }

    func testPolicySkipDragAndOurWindows() {
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.shouldIntercept(
                topmostIsFloating: false,
                topmostIsTiling: true,
                workspaceHasFloats: true,
                isAeroSpaceWindow: true,
                dragInProgress: false,
            ),
        )
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.shouldIntercept(
                topmostIsFloating: false,
                topmostIsTiling: true,
                workspaceHasFloats: true,
                isAeroSpaceWindow: false,
                dragInProgress: true,
            ),
        )
    }

    func testTopmostManagedWindowUsesStackOrder() {
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

        let fake = FakeClickStackPort()
        fake.snapshot = OnScreenWindowSnapshot(
            levels: [1: .normalWindow, 2: .normalWindow],
            normalStack: [
                (id: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)),
                (id: 2, rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)),
            ],
        )
        WindowServerReads.install(fake)
        defer { WindowServerReads.install(nil) }

        XCTAssertEqual(topmostManagedWindow(at: CGPoint(x: 400, y: 300))?.windowId, 1)
    }

    func testPrivateFocusAvailable() {
        XCTAssertTrue(PrivateFocus.isAvailable)
    }

    func testFloatLayerPolicy() {
        XCTAssertTrue(FloatLayerPolicy.preferFocusWithoutRaise(isFloating: false, workspaceHasFloats: true))
        XCTAssertFalse(FloatLayerPolicy.preferFocusWithoutRaise(isFloating: true, workspaceHasFloats: true))
        XCTAssertFalse(FloatLayerPolicy.shouldRaiseOnFocus(isFloating: false, workspaceHasFloats: true))
    }

    func testFloatingConfigDefaultEnabled() {
        XCTAssertTrue(FloatingConfig().clickWithoutRaise)
    }

    func testTrackedEventsIncludeMouseMovedForDragAfterSwallow() {
        // After swallowing system mouseDown, drags often arrive as mouseMoved.
        XCTAssertTrue(FloatClickWithoutRaisePolicy.isTrackedEvent(.leftMouseDown))
        XCTAssertTrue(FloatClickWithoutRaisePolicy.isTrackedEvent(.leftMouseDragged))
        XCTAssertTrue(FloatClickWithoutRaisePolicy.isTrackedEvent(.leftMouseUp))
        XCTAssertTrue(FloatClickWithoutRaisePolicy.isTrackedEvent(.mouseMoved))
        XCTAssertFalse(FloatClickWithoutRaisePolicy.isTrackedEvent(.rightMouseDown))
        XCTAssertFalse(FloatClickWithoutRaisePolicy.isTrackedEvent(.scrollWheel))
    }

    func testDragThresholdDistinguishesClickFromDrag() {
        let origin = CGPoint(x: 100, y: 100)
        // Inside slop → still a click (postToPid down+up, no raise).
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 102, y: 101)),
        )
        // Past default 4pt threshold → HID drag handoff so the window receives real events.
        XCTAssertTrue(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 105, y: 100)),
        )
        XCTAssertTrue(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 100, y: 110)),
        )
    }
}

private final class FakeClickStackPort: WindowServerReadPort {
    var snapshot = OnScreenWindowSnapshot(levels: [:], normalStack: [])
    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? { nil }
    func onScreenSnapshot() -> OnScreenWindowSnapshot { snapshot }
}
