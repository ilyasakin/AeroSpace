@testable import AppBundle
import Common
import XCTest

/// Real policy + FloatLayer port path (not a reimplementation of focus logic).
@MainActor
final class FloatLayerPolicyTest: XCTestCase {
    private var port: RecordingFloatLayerPort!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        port = RecordingFloatLayerPort()
        FloatLayer.port = port
    }

    override func tearDown() {
        FloatLayer.port = nil
        super.tearDown()
    }

    func testPolicyTileWithFloatsDoesNotRaise() {
        XCTAssertFalse(FloatLayerPolicy.shouldRaiseOnFocus(isFloating: false, workspaceHasFloats: true))
        XCTAssertTrue(FloatLayerPolicy.preferFocusWithoutRaise(isFloating: false, workspaceHasFloats: true))
    }

    func testPolicyFloatMayRaise() {
        XCTAssertTrue(FloatLayerPolicy.shouldRaiseOnFocus(isFloating: true, workspaceHasFloats: true))
        XCTAssertFalse(FloatLayerPolicy.preferFocusWithoutRaise(isFloating: true, workspaceHasFloats: true))
    }

    func testPolicyTileWithoutFloatsRaises() {
        XCTAssertTrue(FloatLayerPolicy.shouldRaiseOnFocus(isFloating: false, workspaceHasFloats: false))
        XCTAssertFalse(FloatLayerPolicy.preferFocusWithoutRaise(isFloating: false, workspaceHasFloats: false))
    }

    func testNativeFocusRespectingFloatsTileUsesFocusWithoutRaise() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 101, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 102, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        port.stack = [102, 101]

        tile.nativeFocusRespectingFloats()

        XCTAssertEqual(port.focusWithoutRaiseCalls.count, 1)
        XCTAssertEqual(port.focusWithoutRaiseCalls.first?.windowId, 101)
        // Must not re-raise float after tile focus — that blocks tiling interaction.
        XCTAssertTrue(port.raiseCalls.isEmpty, "must not raise tile or re-raise floats on tile focus")
        XCTAssertEqual(tile.lastNativeFocusRaise, nil, "tile must not take nativeFocus(raise:) with raise true")
    }

    func testNativeFocusRespectingFloatsDoesNotReRaiseFloatsOnInvertedStack() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 201, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 202, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        port.stack = [201, 202]

        tile.nativeFocusRespectingFloats()

        XCTAssertFalse(port.raiseCalls.contains(202), "auto re-raise on focus is banned (blocks tiles)")
        XCTAssertFalse(port.raiseCalls.contains(201), "tile must never be raised")
        XCTAssertTrue(port.focusWithoutRaiseCalls.contains(where: { $0.windowId == 201 }))
    }

    func testNativeFocusRespectingFloatsFloatRaises() {
        let workspace = focus.workspace
        workspace.rootTilingContainer.apply {
            _ = TestWindow.new(id: 301, parent: $0, adaptiveWeight: 1)
        }
        let floating = TestWindow.new(id: 302, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)

        floating.nativeFocusRespectingFloats()

        XCTAssertEqual(floating.lastNativeFocusRaise, true)
        XCTAssertTrue(port.focusWithoutRaiseCalls.isEmpty)
    }

    func testDidBecomeFloatingRaisesOnce() {
        FloatLayer.didBecomeFloating(TestWindow.new(
            id: 401,
            parent: focus.workspace.floatingWindowsContainer,
            adaptiveWeight: WEIGHT_AUTO,
        ))
        XCTAssertEqual(port.raiseCalls, [401])
    }

    /// Explicit ensureFloatsAboveTiling (raise-floating) still raises floats once.
    func testEnsureFloatsAboveTilingExplicitRecoveryRaisesFloats() {
        let workspace = focus.workspace
        var tile: TestWindow!
        workspace.rootTilingContainer.apply {
            tile = TestWindow.new(id: 501, parent: $0, adaptiveWeight: 1)
        }
        _ = TestWindow.new(id: 502, parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO)
        port.raiseCalls = []
        port.focusWithoutRaiseCalls = []

        FloatLayer.ensureFloatsAboveTiling(focusedTile: tile)

        XCTAssertTrue(port.raiseCalls.contains(502))
        XCTAssertTrue(port.focusWithoutRaiseCalls.contains(where: { $0.windowId == 501 }))
    }

    func testPrivateFocusSymbolsResolveWithSipOn() {
        // Structural: process must resolve private focus APIs (SIP-on path).
        XCTAssertTrue(PrivateFocus.isAvailable, "PrivateFocus must load without Dock SA")
    }

    /// yabai same-app branch event layout (0x0d + 0x8a unfocus/focus).
    func testSameAppSwitchEventBytesMatchYabaiLayout() {
        let unfocus = PrivateFocus.sameAppSwitchEventBytes(
            fromWindowId: 0xAABB_CCDD,
            toWindowId: 0x1122_3344,
            phase: .unfocusPrevious,
        )
        XCTAssertEqual(unfocus[0x04], 0xf8)
        XCTAssertEqual(unfocus[0x08], 0x0d)
        XCTAssertEqual(unfocus[0x8a], 0x02)
        // little-endian window id at 0x3c
        XCTAssertEqual(unfocus[0x3c], 0xDD)
        XCTAssertEqual(unfocus[0x3d], 0xCC)
        XCTAssertEqual(unfocus[0x3e], 0xBB)
        XCTAssertEqual(unfocus[0x3f], 0xAA)

        let focusNext = PrivateFocus.sameAppSwitchEventBytes(
            fromWindowId: 0xAABB_CCDD,
            toWindowId: 0x1122_3344,
            phase: .focusNext,
        )
        XCTAssertEqual(focusNext[0x08], 0x0d)
        XCTAssertEqual(focusNext[0x8a], 0x01)
        XCTAssertEqual(focusNext[0x3c], 0x44)
        XCTAssertEqual(focusNext[0x3d], 0x33)
        XCTAssertEqual(focusNext[0x3e], 0x22)
        XCTAssertEqual(focusNext[0x3f], 0x11)
    }

    /// Second focusWithoutRaise on the same process must run the 0x0d dance + 40ms delay
    /// (required so a non-key window of the already-front app becomes key without raise).
    func testFocusWithoutRaiseSameAppPosts0xdSequenceAndDelays() {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        var slept: [useconds_t] = []
        var events: [[UInt8]] = []
        PrivateFocus.sleepMicroseconds = { slept.append($0) }
        PrivateFocus.onPostEvent = { events.append($0) }
        defer {
            PrivateFocus.sleepMicroseconds = { usleep($0) }
            PrivateFocus.onPostEvent = nil
            PrivateFocus.resetFocusTrackingForTests()
        }

        let pid = getpid()
        // First call establishes lastFocused for this process (make_key only).
        XCTAssertTrue(PrivateFocus.focusWithoutRaise(pid: pid, windowId: 9001))
        let afterFirst = events.count
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertTrue(slept.isEmpty, "first focus in app must not 40ms-delay")

        // Second window of same app — yabai same-app branch.
        XCTAssertTrue(PrivateFocus.focusWithoutRaise(pid: pid, windowId: 9002))
        XCTAssertEqual(slept, [40_000], "same-app switch must delay 40ms between 0x0d events")

        let newEvents = Array(events.dropFirst(afterFirst))
        let unfocus = newEvents.first { $0.count > 0x8a && $0[0x08] == 0x0d && $0[0x8a] == 0x02 }
        let refocus = newEvents.first { $0.count > 0x8a && $0[0x08] == 0x0d && $0[0x8a] == 0x01 }
        XCTAssertNotNil(unfocus, "must post 0x0d unfocus previous key window")
        XCTAssertNotNil(refocus, "must post 0x0d focus next key window")
        // previous id 9001 little-endian at 0x3c
        XCTAssertEqual(unfocus![0x3c], UInt8(9001 & 0xff))
        XCTAssertEqual(unfocus![0x3d], UInt8((9001 >> 8) & 0xff))
        // next id 9002
        XCTAssertEqual(refocus![0x3c], UInt8(9002 & 0xff))
        XCTAssertEqual(refocus![0x3d], UInt8((9002 >> 8) & 0xff))
    }

    /// Production path: float focused with raise:true (seeds via noteKeyWindow only — no
    /// prior focusWithoutRaise). Then tile focusWithoutRaise must still 0x0d with fromId=float.
    func testFloatRaiseTrueThenTileFocusWithoutRaiseRuns0xdWithFloatAsFromId() {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        var slept: [useconds_t] = []
        var events: [[UInt8]] = []
        PrivateFocus.sleepMicroseconds = { slept.append($0) }
        PrivateFocus.onPostEvent = { events.append($0) }
        defer {
            PrivateFocus.sleepMicroseconds = { usleep($0) }
            PrivateFocus.onPostEvent = nil
            PrivateFocus.resetFocusTrackingForTests()
        }

        let pid = getpid()
        let floatId: UInt32 = 7001
        let tileId: UInt32 = 7002

        // Simulate MacApp.nativeFocus(float, raise: true) — only noteKeyWindow, no focusWithoutRaise.
        XCTAssertTrue(PrivateFocus.noteKeyWindow(pid: pid, windowId: floatId))
        XCTAssertTrue(events.isEmpty, "noteKeyWindow must not post events")
        XCTAssertTrue(slept.isEmpty)

        // Same-app tile under float: focusWithoutRaise with tracking seeded only by noteKeyWindow.
        XCTAssertTrue(PrivateFocus.focusWithoutRaise(pid: pid, windowId: tileId))
        XCTAssertEqual(slept, [40_000])

        let unfocus = events.first { $0.count > 0x8a && $0[0x08] == 0x0d && $0[0x8a] == 0x02 }
        let refocus = events.first { $0.count > 0x8a && $0[0x08] == 0x0d && $0[0x8a] == 0x01 }
        XCTAssertNotNil(unfocus, "0x0d unfocus must run after raise:true float seed")
        XCTAssertNotNil(refocus, "0x0d focus tile must run")
        // fromId must be the float
        XCTAssertEqual(unfocus![0x3c], UInt8(floatId & 0xff))
        XCTAssertEqual(unfocus![0x3d], UInt8((floatId >> 8) & 0xff))
        XCTAssertEqual(refocus![0x3c], UInt8(tileId & 0xff))
        XCTAssertEqual(refocus![0x3d], UInt8((tileId >> 8) & 0xff))
    }

    /// After raise:true float focus, MacApp seeds noteKeyWindow then may only have
    /// lastNativeFocusedWindowId if window-id tracking were cleared. fallbackPrevious must
    /// still drive 0x0d with fromId=float (production MacApp passes lastNativeFocusedWindowId).
    func testFocusWithoutRaiseUsesFallbackPreviousWhenTrackingNil() {
        guard PrivateFocus.isAvailable else {
            XCTFail("PrivateFocus unavailable")
            return
        }
        PrivateFocus.resetFocusTrackingForTests()
        var slept: [useconds_t] = []
        var events: [[UInt8]] = []
        PrivateFocus.sleepMicroseconds = { slept.append($0) }
        PrivateFocus.onPostEvent = { events.append($0) }
        defer {
            PrivateFocus.sleepMicroseconds = { usleep($0) }
            PrivateFocus.onPostEvent = nil
            PrivateFocus.resetFocusTrackingForTests()
        }

        let pid = getpid()
        // Seed PSN like noteKeyWindow after float raise:true, then drop window id only.
        XCTAssertTrue(PrivateFocus.noteKeyWindow(pid: pid, windowId: 8001))
        PrivateFocus.clearLastFocusedWindowIdForTests()

        XCTAssertTrue(
            PrivateFocus.focusWithoutRaise(
                pid: pid,
                windowId: 8002,
                fallbackPreviousKeyWindowId: 8001,
            ),
        )
        XCTAssertEqual(slept, [40_000])
        let unfocus = events.first { $0.count > 0x8a && $0[0x08] == 0x0d && $0[0x8a] == 0x02 }
        XCTAssertNotNil(unfocus)
        XCTAssertEqual(unfocus![0x3c], UInt8(8001 & 0xff))
        XCTAssertEqual(unfocus![0x3d], UInt8((8001 >> 8) & 0xff))
    }
}

@MainActor
private final class RecordingFloatLayerPort: FloatLayerPort {
    var focusWithoutRaiseCalls: [(pid: pid_t, windowId: UInt32)] = []
    var raiseCalls: [UInt32] = []
    var stack: [UInt32]? = []

    func focusWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool {
        focusWithoutRaiseCalls.append((pid, windowId))
        return true
    }

    func raiseWindow(windowId: UInt32) {
        raiseCalls.append(windowId)
    }

    func frontToBackWindowIds() -> [UInt32]? { stack }
}
