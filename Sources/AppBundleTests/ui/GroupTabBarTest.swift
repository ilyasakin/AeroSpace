@testable import AppBundle
import Common
import XCTest

@MainActor
final class GroupTabBarTest: XCTestCase {
    func testEmptyContentViewPassesClicksThrough() {
        // Policy mirrored by GroupTabBarContentView.hitTest: hit === contentView → nil
        assertTrue(groupTabBarShouldPassThrough(hitIsContentView: true))
        assertFalse(groupTabBarShouldPassThrough(hitIsContentView: false))
    }

    /// Tab strip sits on the top edge of the group rect in overlay content coords
    /// (AppKit bottom-left), using the same mainMonitor flip as WindowBorders.
    func testTabStripAtTopOfContainer() {
        setUpWorkspacesForTests()
        // Container at top-left (0,0) size 400x200 in AeroSpace coords
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 200)
        let overlayOrigin = CGPoint(x: 0, y: 0)
        let tabH: CGFloat = 22
        let frame = groupTabStripFrame(
            containerRect: rect,
            overlayOrigin: overlayOrigin,
            tabHeight: tabH,
            tabIndex: 0,
            tabCount: 2,
        )
        let ak = rect.toAppKitFrame()
        // Top of container in AppKit: ak.minY + ak.height
        assertEquals(frame.maxY, ak.minY + ak.height, additionalMsg: "tabs touch container top")
        assertEquals(frame.minY, ak.minY + ak.height - tabH, additionalMsg: "tabs hang from top edge")
        assertEquals(frame.minX, ak.minX)
        assertEquals(frame.width, 200) // half of 400 for 2 tabs
        // Must NOT be one full container height above the group
        assertFalse(frame.minY > ak.minY + ak.height)
    }

    func testTabStripWithOverlayOffset() {
        setUpWorkspacesForTests()
        let rect = Rect(topLeftX: 100, topLeftY: 50, width: 300, height: 100)
        let overlayOrigin = CGPoint(x: 10, y: 20)
        let tabH: CGFloat = 22
        let frame = groupTabStripFrame(
            containerRect: rect,
            overlayOrigin: overlayOrigin,
            tabHeight: tabH,
            tabIndex: 1,
            tabCount: 3,
        )
        let ak = rect.toAppKitFrame()
        assertEquals(frame.minY, ak.minY + ak.height - tabH - overlayOrigin.y)
        assertEquals(frame.minX, ak.minX - overlayOrigin.x + ak.width / 3)
    }
}
