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
}
