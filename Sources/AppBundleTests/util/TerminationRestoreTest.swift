@testable import AppBundle
import XCTest

final class TerminationRestoreTest: XCTestCase {
    func testCenteredTopLeftUsesMonitorOrigin() {
        // Secondary-display-like rect (not at 0,0)
        let vis = Rect(topLeftX: 1920, topLeftY: 100, width: 1600, height: 900)
        let size = CGSize(width: 800, height: 600)
        let p = centeredTopLeft(windowSize: size, in: vis)
        assertEquals(p.x, 1920 + (1600 - 800) / 2)
        assertEquals(p.y, 100 + (900 - 600) / 2)
    }

    func testCenteredTopLeftClampsOversizedWindow() {
        let vis = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
        let p = centeredTopLeft(windowSize: CGSize(width: 2000, height: 2000), in: vis)
        // Fits and sits at origin when clamped to full visible size
        assertEquals(p.x, 0)
        assertEquals(p.y, 0)
    }

    func testCenteredTopLeftOnMainMonitorOrigin() {
        let vis = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let p = centeredTopLeft(windowSize: CGSize(width: 400, height: 300), in: vis)
        assertEquals(p.x, (1920 - 400) / 2)
        assertEquals(p.y, (1080 - 300) / 2)
    }

    func testTerminationRestoreSizePrefersPreferredAndClamps() {
        let vis = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
        let s = terminationRestoreSize(preferred: CGSize(width: 500, height: 400), visibleRect: vis)
        assertEquals(s.width, 500)
        assertEquals(s.height, 400)

        let big = terminationRestoreSize(preferred: CGSize(width: 5000, height: 4000), visibleRect: vis)
        assertEquals(big.width, 1000)
        assertEquals(big.height, 800)
    }

    func testTerminationRestoreSizeFallbackWhenMissing() {
        let vis = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
        let s = terminationRestoreSize(preferred: nil, visibleRect: vis)
        assertEquals(s.width, 700)
        assertEquals(s.height, 560)
        let invalid = terminationRestoreSize(preferred: CGSize(width: 0, height: 0), visibleRect: vis)
        assertEquals(invalid.width, 700)
        assertEquals(invalid.height, 560)
    }
}
