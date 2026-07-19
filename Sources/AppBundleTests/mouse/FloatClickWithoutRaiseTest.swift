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

    func testTopmostManagedWindowPrefersFloatLayerOverStaleStack() {
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
        // Stale stack lists tile above float — click path must still hit the float layer.
        fake.snapshot = OnScreenWindowSnapshot(
            levels: [1: .normalWindow, 2: .normalWindow],
            normalStack: [
                (id: 1, rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600)),
                (id: 2, rect: Rect(topLeftX: 200, topLeftY: 150, width: 400, height: 300)),
            ],
        )
        WindowServerReads.install(fake)
        defer { WindowServerReads.install(nil) }

        // Over the float → float (must not intercept as tile under it).
        XCTAssertEqual(topmostManagedWindow(at: CGPoint(x: 400, y: 300))?.windowId, 2)
        // Exposed tile only → tile (intercept candidate).
        XCTAssertEqual(topmostManagedWindow(at: CGPoint(x: 50, y: 50))?.windowId, 1)
    }

    func testPolicyDoesNotInterceptWhenHitIsFloating() {
        // Mirrors topmostManagedWindow preferring float: shouldIntercept must stay false.
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

    func testMakeKeyOnlyDoesNotRequireSameAppGap() {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        var slept: [useconds_t] = []
        PrivateFocus.sleepMicroseconds = { slept.append($0) }
        defer {
            PrivateFocus.sleepMicroseconds = { usleep($0) }
            PrivateFocus.resetFocusTrackingForTests()
        }
        XCTAssertTrue(PrivateFocus.makeKeyOnly(pid: getpid(), windowId: 77))
        XCTAssertTrue(slept.isEmpty)
        XCTAssertEqual(PrivateFocus.trackedKeyWindowId, 77)
    }

    func testForcePreviousKeyWindowStillRunsSameAppDanceWhenTrackingAlreadyOnTarget() {
        // After we focus a tile, tracking points at the tile; AXRaise on a float steals key
        // back. forcePreviousKeyWindowId must still emit 0x0d from the float.
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        var events: [[UInt8]] = []
        PrivateFocus.sleepMicroseconds = { _ in }
        PrivateFocus.onPostEvent = { events.append($0) }
        defer {
            PrivateFocus.sleepMicroseconds = { usleep($0) }
            PrivateFocus.onPostEvent = nil
            PrivateFocus.resetFocusTrackingForTests()
        }
        let pid = getpid()
        XCTAssertTrue(PrivateFocus.focusWithoutRaise(pid: pid, windowId: 50, sameAppGapMicroseconds: 0))
        events.removeAll()
        // Tracking already 50; force from float 99.
        XCTAssertTrue(
            PrivateFocus.focusWithoutRaise(
                pid: pid,
                windowId: 50,
                forcePreviousKeyWindowId: 99,
                sameAppGapMicroseconds: 0,
            ),
        )
        let unfocus = events.first { $0.count > 0x8A && $0[0x08] == 0x0D && $0[0x8A] == 0x02 }
        XCTAssertNotNil(unfocus, "must unfocus forced previous (float) even when tracking says tile")
        XCTAssertEqual(unfocus![0x3C], UInt8(99 & 0xFF))
    }

    /// The settle key-transfer: same-app must 0x0d-dance from the key-stealing float to the
    /// tile (with the async gap), then make-key — strictly in that order, no setFrontProcess.
    func testTransferKeyAfterFloatRaiseSameAppDanceThenMakeKey() async {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        nonisolated(unsafe) var events: [[UInt8]] = []
        nonisolated(unsafe) var sleeps: [UInt64] = []
        PrivateFocus.onPostEvent = { events.append($0) }
        PrivateFocus.asyncSleepNanoseconds = { sleeps.append($0) }
        defer {
            PrivateFocus.onPostEvent = nil
            PrivateFocus.asyncSleepNanoseconds = { try? await Task.sleep(nanoseconds: $0) }
            PrivateFocus.resetFocusTrackingForTests()
        }

        let ok = await PrivateFocus.transferKeyAfterFloatRaise(
            pid: getpid(),
            toWindowId: 42,
            fromSameAppWindowId: 99,
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(events.count, 4, "unfocus(float), focus(tile), make-key x2")
        XCTAssertEqual(events[0][0x08], 0x0D)
        XCTAssertEqual(events[0][0x8A], 0x02)
        XCTAssertEqual(events[0][0x3C], 99)
        XCTAssertEqual(events[1][0x08], 0x0D)
        XCTAssertEqual(events[1][0x8A], 0x01)
        XCTAssertEqual(events[1][0x3C], 42)
        XCTAssertEqual(events[2][0x08], 0x01)
        XCTAssertEqual(events[3][0x08], 0x02)
        XCTAssertEqual(sleeps, [40_000_000], "same-app 0x0d needs the 40ms gap (async, not usleep)")
        XCTAssertEqual(PrivateFocus.trackedKeyWindowId, 42)
    }

    /// Cross-app floats don't steal key on AXRaise — make-key only, no dance, no gap.
    func testTransferKeyAfterFloatRaiseCrossAppMakeKeyOnly() async {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        nonisolated(unsafe) var events: [[UInt8]] = []
        nonisolated(unsafe) var sleeps: [UInt64] = []
        PrivateFocus.onPostEvent = { events.append($0) }
        PrivateFocus.asyncSleepNanoseconds = { sleeps.append($0) }
        defer {
            PrivateFocus.onPostEvent = nil
            PrivateFocus.asyncSleepNanoseconds = { try? await Task.sleep(nanoseconds: $0) }
            PrivateFocus.resetFocusTrackingForTests()
        }

        let ok = await PrivateFocus.transferKeyAfterFloatRaise(
            pid: getpid(),
            toWindowId: 42,
            fromSameAppWindowId: nil,
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(events.count, 2, "make-key events only")
        XCTAssertEqual(events[0][0x08], 0x01)
        XCTAssertEqual(events[1][0x08], 0x02)
        XCTAssertTrue(sleeps.isEmpty)
    }

    /// The settle pipeline: floats raised (awaited) **before** the key transfer, and the
    /// transfer runs from the last-raised same-app float (the key stealer) to the tile.
    func testSettleRaisesFloatsBeforeKeyTransfer() async {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        _ = tile

        nonisolated(unsafe) var journal: [String] = []
        TestWindow.onNativeRaiseAndWait = { journal.append("raise:\($0)") }
        floatClickKeyTransfer = { _, toWindowId, fromWindowId in
            journal.append("key:\(toWindowId)<-\(fromWindowId.map(String.init) ?? "nil")")
        }
        PrivateFocus.asyncSleepNanoseconds = { _ in }
        defer {
            TestWindow.onNativeRaiseAndWait = nil
            floatClickKeyTransfer = defaultFloatClickKeyTransfer
            PrivateFocus.asyncSleepNanoseconds = { try? await Task.sleep(nanoseconds: $0) }
        }

        await settleFloatLayerKeepingTileKey(tileWindowId: 1)

        XCTAssertEqual(
            journal,
            ["raise:2", "key:1<-2"],
            "raise the float first (awaited), then transfer key from the float to the tile",
        )
    }

    func testDragThresholdDistinguishesClickFromDrag() {
        let origin = CGPoint(x: 100, y: 100)
        // Small jitter while clicking A↔B must NOT start HID drag (that raises the tile over C).
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 105, y: 101)),
        )
        XCTAssertFalse(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 100, y: 108)),
        )
        // Past 12pt threshold → HID drag handoff for real drags only.
        XCTAssertTrue(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 113, y: 100)),
        )
        XCTAssertTrue(
            FloatClickWithoutRaisePolicy.isDrag(from: origin, to: CGPoint(x: 100, y: 120)),
        )
    }
}

private final class FakeClickStackPort: WindowServerReadPort {
    var snapshot = OnScreenWindowSnapshot(levels: [:], normalStack: [])
    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? { nil }
    func onScreenSnapshot() -> OnScreenWindowSnapshot { snapshot }
}
