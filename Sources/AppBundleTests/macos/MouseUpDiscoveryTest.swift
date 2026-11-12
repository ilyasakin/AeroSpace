@testable import AppBundle
import Common
import XCTest

@MainActor
final class MouseUpDiscoveryTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        WindowServerReads.install(SimulatedWindowServer())
    }
    override func tearDown() async throws { WindowServerReads.install(nil) }

    private func onScreen(_ id: UInt32) {
        SimulatedMacOS.shared.frames[id] = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 500)
    }

    func testAPlainClickNeedsNoDiscovery() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        onScreen(1)
        onScreen(2)
        XCTAssertFalse(mouseUpNeedsDiscovery())
    }

    /// The close button of an unfocused window: AX may never say so, WindowServer does
    func testAWindowGoneFromWindowServerNeedsDiscovery() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        onScreen(1)
        XCTAssertTrue(mouseUpNeedsDiscovery())
    }

    /// Clicking a native tab changes which tab holds the group's tile
    func testAParkedTabOnAVisibleWorkspaceNeedsDiscovery() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let tab = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        onScreen(1)
        onScreen(2)
        tab.isParkedAsNativeTab = true
        tab.bind(to: ws.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        XCTAssertTrue(mouseUpNeedsDiscovery())

        let away = Workspace.get(byName: "away")
        tab.bind(to: away.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        XCTAssertFalse(mouseUpNeedsDiscovery(), "a tab group on an invisible workspace can't be clicked")
    }
}
