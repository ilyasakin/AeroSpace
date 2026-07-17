@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WindowBordersTest: XCTestCase {
    func testTopLeftRectToAppKitFrame() {
        // Test monitor is 1920x1080 (mainMonitor in unit tests)
        // A window at top-left (100, 200), 300x400: AppKit y = 1080 - (200 + 400) = 480
        let rect = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)
        let frame = rect.toAppKitFrame()
        assertEquals(frame.origin.x, 100)
        assertEquals(frame.origin.y, 480)
        assertEquals(frame.width, 300)
        assertEquals(frame.height, 400)
    }

    func testTopEdgeWindowSitsAtScreenTop() {
        // A window flush against the top of the screen (topLeftY 0) should map to the
        // top of the AppKit space: y = screenHeight - height
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 100)
        let frame = rect.toAppKitFrame()
        assertEquals(frame.origin.y, 980) // 1080 - 100
    }
}
