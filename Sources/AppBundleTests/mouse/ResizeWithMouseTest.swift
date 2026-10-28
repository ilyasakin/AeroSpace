@testable import AppBundle
import Common
import XCTest

/// Mouse-resize weight diffs need a layout baseline (`desiredRect`) vs a live frame.
/// Invalidating the frame slot on every AX resized event made every drag tick a no-op.
/// Edge resize also fires AXMoved; the move path must not wipe that baseline or tile-swap.
@MainActor
final class ResizeWithMouseTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testResizeDiffRequiresLastAppliedBaseline() {
        let live = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)
        let baseline = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        XCTAssertTrue(resizeWithMouseCanApplyDiffs(believed: baseline, live: live))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(believed: nil, live: live))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(believed: baseline, live: nil))
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(believed: nil, live: nil))
    }

    func testInvalidateClearsBaselineThatResizeNeeds() {
        // Documents the bug class: invalidateAxFrameCaches drops the frame slot; resize then bails.
        let window = TestWindowHarness()
        window.believed = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        XCTAssertTrue(resizeWithMouseCanApplyDiffs(believed: window.believed, live: window.believed))
        window.believed = nil // same effect as MacWindow.invalidateAxFrameCaches()
        XCTAssertFalse(resizeWithMouseCanApplyDiffs(believed: window.believed, live: window.live))
    }

    func testResizeLikeDragWhenSizeChanges() {
        let baseline = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        // Pure translation (title-bar move): not resize-like
        let moved = Rect(topLeftX: 50, topLeftY: 20, width: 400, height: 400)
        XCTAssertFalse(isMouseResizeLikeDrag(believed: baseline, live: moved))
        // Right-edge grow
        let wider = Rect(topLeftX: 0, topLeftY: 0, width: 520, height: 400)
        XCTAssertTrue(isMouseResizeLikeDrag(believed: baseline, live: wider))
        // Left-edge grow (origin + size)
        let leftGrow = Rect(topLeftX: -40, topLeftY: 0, width: 440, height: 400)
        XCTAssertTrue(isMouseResizeLikeDrag(believed: baseline, live: leftGrow))
        // Noise within threshold
        let noise = Rect(topLeftX: 0, topLeftY: 0, width: 403, height: 400)
        XCTAssertFalse(isMouseResizeLikeDrag(believed: baseline, live: noise))
        XCTAssertFalse(isMouseResizeLikeDrag(believed: nil, live: wider))
        XCTAssertFalse(isMouseResizeLikeDrag(believed: baseline, live: nil))
    }

    func testRightEdgeResizeGrowsWeightAndShrinksSibling() async throws {
        var left: Window!
        var right: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            left = TestWindow.new(
                id: 1,
                parent: $0,
                adaptiveWeight: 500,
                rect: Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000),
            )
            right = TestWindow.new(
                id: 2,
                parent: $0,
                adaptiveWeight: 500,
                rect: Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000),
            )
        }
        // Simulate a prior layout pass: physical baseline + virtual weight dimensions.
        left.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
        left.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
        right.desiredRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
        right.lastAppliedLayoutVirtualRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
        // ...which also gives the container its span (pixels convert to weight through it)
        Workspace.get(byName: name).rootTilingContainer.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)

        // User dragged the left window's right edge +100 px (live frame only; baseline stays).
        left.setAxFrame(CGPoint(x: 0, y: 0), CGSize(width: 600, height: 1000))

        currentlyManipulatedWithMouseWindowId = left.windowId
        try await resizeWithMouse(left)

        // Weight-before is virtual width 500; +100 physical growth → 600 / 400.
        XCTAssertEqual(left.hWeight, 600, accuracy: 0.1)
        XCTAssertEqual(right.hWeight, 400, accuracy: 0.1)
        // Drag-start baseline is frozen; desiredRect may be updated by layout later.
        XCTAssertEqual(mouseResizePhysicalBaseline(for: left)?.width, 500)
    }

    func testMouseResizeBaselineStaysFixedWhenLastAppliedUpdates() {
        let w = TestWindow.new(
            id: 9,
            parent: Workspace.get(byName: name).rootTilingContainer,
            adaptiveWeight: 1,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400),
        )
        w.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)
        let b1 = mouseResizePhysicalBaseline(for: w)
        XCTAssertEqual(b1?.width, 400)
        // Layout mid-drag would update desiredRect; baseline must not follow.
        w.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 550, height: 400)
        let b2 = mouseResizePhysicalBaseline(for: w)
        XCTAssertEqual(b2?.width, 400)
        XCTAssertEqual(mouseResizePhysicalBaselineIfSet(for: w)?.width, 400)
    }

    func testNominalRefreshHzPrefersScreenMaximumFramesPerSecond() {
        var link: CVDisplayLink?
        XCTAssertEqual(CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link), kCVReturnSuccess)
        guard let link else {
            XCTFail("CVDisplayLinkCreateWithCGDisplay failed")
            return
        }
        let screen = DisplayRefresh.nsScreen(forDisplayId: CGMainDisplayID())
        let hz = DisplayRefresh.nominalRefreshHz(displayLink: link, screen: screen)
        XCTAssertGreaterThanOrEqual(hz, 30)
        XCTAssertLessThanOrEqual(hz, 500)
        if let screen, screen.maximumFramesPerSecond > 0 {
            XCTAssertEqual(hz, Double(screen.maximumFramesPerSecond), accuracy: 0.5)
        }
    }

    func testDisplayRefreshHzForWorkspaceMatchesMonitorScreen() {
        let ws = Workspace.get(byName: name)
        let hz = DisplayRefresh.hz(for: ws)
        XCTAssertGreaterThanOrEqual(hz, 30)
        XCTAssertLessThanOrEqual(hz, 500)
        let monitorHz = DisplayRefresh.hz(for: ws.workspaceMonitor)
        XCTAssertEqual(hz, monitorHz, accuracy: 0.5)
        let interval = DisplayRefresh.frameInterval(for: ws)
        XCTAssertEqual(interval, 1.0 / hz, accuracy: 0.0001)
    }

    func testResizeLikeMovedPathDoesNotClearBaselineOrSwap() async throws {
        var left: Window!
        var right: Window!
        Workspace.get(byName: name).rootTilingContainer.apply {
            left = TestWindow.new(
                id: 1,
                parent: $0,
                adaptiveWeight: 500,
                rect: Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000),
            )
            right = TestWindow.new(
                id: 2,
                parent: $0,
                adaptiveWeight: 500,
                rect: Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000),
            )
        }
        left.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
        left.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
        right.desiredRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
        right.lastAppliedLayoutVirtualRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)

        // Live size change (edge resize). If the move path ran, it would nil the frame slot.
        left.setAxFrame(CGPoint(x: 0, y: 0), CGSize(width: 650, height: 1000))
        let live = try await liveRectForMouseResize(left)
        XCTAssertTrue(isMouseResizeLikeDrag(believed: left.desiredRect, live: live))

        currentlyManipulatedWithMouseWindowId = left.windowId
        try await resizeWithMouse(left)

        XCTAssertNotNil(left.desiredRect, "resize must keep layout baseline")
        // Still left-of-right in tiling order (no accidental swap from move path).
        XCTAssertEqual(left.ownIndex, 0)
        XCTAssertEqual(right.ownIndex, 1)
        XCTAssertGreaterThan(left.hWeight, right.hWeight)
    }

    func testLiveRectPrefersWindowServerOverLastApplied() async throws {
        let fake = FakeWSPort()
        fake.boundsById[1] = Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 400)
        WindowServerReads.install(fake)
        defer { WindowServerReads.install(nil) }

        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(
            id: 1,
            parent: workspace.rootTilingContainer,
            adaptiveWeight: 1,
            // AX / test rect differs from WS — live path must prefer WS
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400),
        )
        window.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 400)

        let live = try await liveRectForMouseResize(window)
        XCTAssertEqual(live?.width, 700)
        XCTAssertNotEqual(live?.width, window.desiredRect?.width)
    }
}

/// Minimal stand-in so the pure helper tests do not need a full workspace tree.
private final class TestWindowHarness {
    var believed: Rect?
    var live: Rect? = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)
}

private final class FakeWSPort: WindowServerReadPort {
    var boundsById: [UInt32: Rect] = [:]
    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? { boundsById[windowId] }
    func onScreenSnapshot() -> OnScreenWindowSnapshot {
        OnScreenWindowSnapshot(levels: [:], normalStack: [])
    }
}
