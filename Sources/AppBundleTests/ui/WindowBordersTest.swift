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

    func testCornerRadiusOverrideResolution() {
        var borders = WindowBorders()
        borders.cornerRadius = 10
        borders.cornerRadiusOverrides = ["com.apple.Terminal": 6]
        // App with an override gets it
        assertEquals(borders.cornerRadius(forAppId: "com.apple.Terminal"), 6)
        // App without an override falls back to the default
        assertEquals(borders.cornerRadius(forAppId: "com.google.Chrome"), 10)
        // Unknown / nil app id falls back to the default
        assertEquals(borders.cornerRadius(forAppId: nil), 10)
    }
}
