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
            guard let windowId = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], width > 100,
                  let height = bounds["Height"], height > 100
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

        // Not a tight assertion — machine dependent. This guards the design premise: an eager
        // snapshot must be a small fraction of a frame, not a multiple of one.
        XCTAssertLessThan(total, 16667, "a per-tick snapshot must fit inside a 60Hz frame")
    }
}
