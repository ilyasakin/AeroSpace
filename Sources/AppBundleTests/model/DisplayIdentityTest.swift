@testable import AppBundle
import Common
import XCTest

/// Workspace→monitor association used to be keyed on `monitor.rect.topLeftCorner`, in memory and on
/// disk. A top-left corner is geometry, not identity: it moves when displays are rearranged, a
/// resolution changes, a lid closes, or a display sleeps. So the key moved out from under the
/// association it was supposed to identify, and:
///
/// - in memory, `rearrangeWorkspacesOnMonitors` guessed which old corner became which new corner by
///   nearest-Euclidean distance and silently dropped a workspace whenever two old corners collapsed
///   onto one new corner;
/// - on disk, session restore matched saved corners to live corners by EXACT `CGPoint` equality, so
///   any difference in arrangement between sessions matched nothing and every workspace fell back to
///   the main monitor — the "everything ended up in the first workspace after a restart" report.
///
/// These pin the identity contract. The multi-display scenarios themselves aren't directly
/// reachable here (`monitors` is a single fake under test), which is exactly why the decision was
/// extracted into `resolveSavedMonitor` as a pure function.
final class DisplayIdentityTest: XCTestCase {
    // MARK: - Saved-session resolution (the restore bug)

    func testStableKeyWinsOverGeometryWhenTheDisplayHasMoved() {
        // The display is the same monitor, but its origin changed since the session was saved —
        // a second display was plugged in, or a resolution changed. Geometry says "no match".
        let byKey = ["UUID-A": "external"]
        let byOrigin = [CGPoint(x: 1920, y: 0): "external"]

        let resolved = resolveSavedMonitor(
            key: "UUID-A",
            topLeft: CGPoint(x: 0, y: 0), // where it used to be
            byKey: byKey,
            byOrigin: byOrigin,
        )
        XCTAssertEqual(resolved, "external", "a moved display must still be recognised by identity")
    }

    func testGeometryIsUsedWhenTheSavedSessionHasNoKey() {
        // Backward compatibility: files written before the key existed carry only coordinates.
        let resolved = resolveSavedMonitor(
            key: nil,
            topLeft: CGPoint(x: 1920, y: 0),
            byKey: ["UUID-A": "external"],
            byOrigin: [CGPoint(x: 1920, y: 0): "external"],
        )
        XCTAssertEqual(resolved, "external", "an old session file must still restore by geometry")
    }

    func testUnknownKeyFallsBackToGeometryRatherThanGivingUp() {
        // The saved display is genuinely gone (different machine, replaced monitor) but something
        // now occupies the same origin. Falling back is better than dropping the assignment.
        let resolved = resolveSavedMonitor(
            key: "UUID-GONE",
            topLeft: CGPoint(x: 0, y: 0),
            byKey: ["UUID-A": "external"],
            byOrigin: [CGPoint(x: 0, y: 0): "builtin"],
        )
        XCTAssertEqual(resolved, "builtin")
    }

    func testNoMatchAtAllResolvesToNil() {
        let resolved = resolveSavedMonitor(
            key: "UUID-GONE",
            topLeft: CGPoint(x: 4000, y: 4000),
            byKey: ["UUID-A": "external"],
            byOrigin: [CGPoint(x: 0, y: 0): "builtin"],
        )
        XCTAssertNil(resolved, "an absent display must not be silently re-homed onto another one")
    }

    /// The case that actually produced the bug report: two displays whose saved origins both differ
    /// from their current ones. Geometry matches neither; identity matches both.
    func testTwoDisplaysThatBothMovedAreBothStillResolved() {
        let byKey = ["UUID-BUILTIN": "builtin", "UUID-EXTERNAL": "external"]
        let byOrigin = [CGPoint(x: 0, y: 0): "builtin", CGPoint(x: 2560, y: 0): "external"]

        // Saved when the external display sat to the LEFT, so both origins have since changed.
        let a = resolveSavedMonitor(key: "UUID-EXTERNAL", topLeft: CGPoint(x: -2560, y: 0), byKey: byKey, byOrigin: byOrigin)
        let b = resolveSavedMonitor(key: "UUID-BUILTIN", topLeft: CGPoint(x: 0, y: 200), byKey: byKey, byOrigin: byOrigin)
        XCTAssertEqual(a, "external")
        XCTAssertEqual(b, "builtin")

        // And the same inputs under the OLD geometry-only rule would have resolved nothing, which is
        // what sent every workspace to the main monitor.
        XCTAssertNil(byOrigin[CGPoint(x: -2560, y: 0)])
        XCTAssertNil(byOrigin[CGPoint(x: 0, y: 200)])
    }

    // MARK: - DisplayId itself

    func testTestSentinelCannotCollideWithARealDisplayNumber() {
        // Real CGDirectDisplayIDs are small; the sentinel and the reconfiguration fallbacks live in
        // the reserved high range so a fake monitor can never be mistaken for a real one.
        XCTAssertGreaterThan(DisplayId.test.rawValue, 0xF000_0000)
        XCTAssertEqual(DisplayId.test, DisplayId.test)
        XCTAssertNotEqual(DisplayId.test, DisplayId(rawValue: 1))
    }

    func testDisplayIdIsUsableAsADictionaryKeyAndIsOrdered() {
        var map: [DisplayId: String] = [:]
        map[DisplayId(rawValue: 7)] = "a"
        map[DisplayId(rawValue: 9)] = "b"
        XCTAssertEqual(map[DisplayId(rawValue: 7)], "a")
        XCTAssertEqual(map.count, 2)
        XCTAssertTrue(DisplayId(rawValue: 7) < DisplayId(rawValue: 9))
    }

    @MainActor
    func testTheFakeMonitorUnderTestHasTheSentinelIdentity() {
        // Guards the seam: if the fake monitor ever lost its identity, every association keyed on
        // identity would collapse onto one bucket in tests and hide real regressions.
        XCTAssertEqual(mainMonitor.displayId, .test)
        XCTAssertEqual(monitors.map(\.displayId), [.test])
    }
}
