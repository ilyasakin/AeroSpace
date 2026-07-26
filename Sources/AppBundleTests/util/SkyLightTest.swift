@testable import AppBundle
import CoreGraphics
import XCTest

final class SkyLightTest: XCTestCase {
    func testSymbolsResolve() {
        // If this fails on a new macOS version, the AX fallback keeps the app working,
        // but we want to know about the drift
        assertTrue(SkyLight.isAvailable)
    }

    func testBoundsMatchCGWindowListGroundTruth() throws {
        unsafe SkyLight.readsEnabled = true
        defer { unsafe SkyLight.readsEnabled = false }

        // Sample real on-screen windows of the current user session
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw XCTSkip("CGWindowList unavailable")
        }
        var checked = 0
        for entry in list {
            // Layer 0 only. SkyLight bounds are consumed for NORMAL app windows; validating against
            // anything else tests a contract we don't rely on. Without the layer filter this
            // compared against `loginwindow`'s layer-2001 sentinel — a 30000x30000 window at
            // (-15000, -15000) that passes a size filter easily and disagrees with SLS by design,
            // so the test failed whenever that window happened to exist (e.g. after a lock or a
            // fast-user-switch).
            guard let windowId = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], width > 100, width < 20000,
                  let height = bounds["Height"], height > 100, height < 20000
            else { continue }
            guard let slsRect = SkyLight.windowBounds(windowId) else { continue }
            assertEquals(slsRect.topLeftX, bounds["X"]!, additionalMsg: "window \(windowId)")
            assertEquals(slsRect.topLeftY, bounds["Y"]!, additionalMsg: "window \(windowId)")
            assertEquals(slsRect.width, width, additionalMsg: "window \(windowId)")
            assertEquals(slsRect.height, height, additionalMsg: "window \(windowId)")
            checked += 1
            if checked >= 10 { break }
        }
        if checked == 0 {
            throw XCTSkip("No suitable on-screen windows to check against")
        }
    }

    func testDisabledFlagReturnsNil() {
        unsafe SkyLight.readsEnabled = false
        assertEquals(SkyLight.windowBounds(1), nil)
    }

    func testMicrobenchmark() throws {
        unsafe SkyLight.readsEnabled = true
        defer { unsafe SkyLight.readsEnabled = false }
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let windowId = list.compactMap({ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
              .first(where: { SkyLight.windowBounds($0) != nil })
        else {
            throw XCTSkip("No window to benchmark against")
        }
        let iterations = 1000
        let start = DispatchTime.now()
        for _ in 0 ..< iterations {
            _ = SkyLight.windowBounds(windowId)
        }
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let microsPerCall = Double(nanos) / Double(iterations) / 1000
        print("SkyLight.windowBounds: \(String(format: "%.1f", microsPerCall)) µs/call")
        // A WindowServer round trip should be well under a millisecond.
        // (AX reads take ~1ms on healthy apps and up to the 2s messaging timeout on busy ones)
        assertTrue(microsPerCall < 1000)
    }

    /// Costs the per-tick `Observed` snapshot the proposed architecture depends on.
    ///
    /// The design replaces 15 hand-invalidated global caches with one immutable snapshot built per
    /// tick, which removes the whole stale-read bug class — but only if building it eagerly is
    /// affordable inside a frame budget. That was flagged as a risk without a number. This measures
    /// the two real components against the LIVE machine: one CGWindowList scan plus one WindowServer
    /// bounds round trip per window.
    func testObservedSnapshotCostFitsAFrameBudget() throws {
        unsafe SkyLight.readsEnabled = true
        defer { unsafe SkyLight.readsEnabled = false }

        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw XCTSkip("No window list available")
        }
        let ids = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        guard !ids.isEmpty else { throw XCTSkip("No windows on screen") }

        // 1. The full-list scan (once per tick, regardless of window count)
        let scanIters = 200
        var scanStart = DispatchTime.now()
        for _ in 0 ..< scanIters {
            _ = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        }
        let scanUs = Double(DispatchTime.now().uptimeNanoseconds - scanStart.uptimeNanoseconds) / Double(scanIters) / 1000

        // 2. A bounds read for every window currently on screen
        let boundsIters = 50
        scanStart = DispatchTime.now()
        for _ in 0 ..< boundsIters {
            for id in ids { _ = SkyLight.windowBounds(id) }
        }
        let allBoundsUs = Double(DispatchTime.now().uptimeNanoseconds - scanStart.uptimeNanoseconds) / Double(boundsIters) / 1000

        let perWindowUs = allBoundsUs / Double(ids.count)
        let total = scanUs + allBoundsUs
        print("BENCH observed: \(ids.count) on-screen windows")
        print("BENCH observed: CGWindowList scan       \(String(format: "%.0f", scanUs)) µs")
        print("BENCH observed: all window bounds       \(String(format: "%.0f", allBoundsUs)) µs (\(String(format: "%.1f", perWindowUs)) µs/window)")
        print("BENCH observed: FULL SNAPSHOT           \(String(format: "%.0f", total)) µs  = \(String(format: "%.1f", total / 16667 * 100))% of a 60Hz frame")
        print("BENCH observed: projected @ 60 windows  \(String(format: "%.0f", scanUs + perWindowUs * 60)) µs")

        // CORRECTION to the first reading of these numbers: "479 µs is 2.9% of a frame, so build
        // Observed eagerly every tick" compares against the WRONG baseline. A frame budget is what a
        // full layout-and-effect pass gets. The drag path is not that: handleWindowMoved resolves a
        // border from ONE `windowBounds` call (14.7 µs above) and never scans the window list, so a
        // drag tick costs ~15–30 µs. Against that baseline an eager 479 µs snapshot is a 20–30×
        // regression on the hottest path in the app, at 60–120 Hz.
        //
        // What the numbers actually say is that observation must be TIERED by cost, not uniform:
        //   per-window SLS bounds   ~15 µs      cheap enough for the drag path
        //   full CGWindowList scan  ~273 µs     structural/discovery events only, never per tick
        //   AX reads                unbounded   never on a synchronous path at all (it can hang)
        // A single undifferentiated per-tick `Observed` would put the middle tier on the hot path and
        // the bottom tier's worst case into every tick's latency.
        XCTAssertLessThan(total, 16667, "a full snapshot must at least fit inside one frame")
    }
}
