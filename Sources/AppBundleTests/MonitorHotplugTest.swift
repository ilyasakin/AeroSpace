@testable import AppBundle
import Common
import XCTest

/// Monitor hotplug / sleep with a simulated monitor set (pure values — no real screens touched).
@MainActor
final class MonitorHotplugTest: XCTestCase {
    private let left = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
    private let right = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)

    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        unsafe testMonitorsOverride = nil
        gcMonitors()
    }

    private func plug(_ monitors: [Monitor]) {
        unsafe testMonitorsOverride = monitors
        invalidateMonitorsCache()
        gcMonitors()
    }

    func testUnpluggingTheFocusedMonitorKeepsFocusOnAVisibleWorkspace() async throws {
        let main = makeTestMonitor(id: 1, rect: left, isMain: true)
        let external = makeTestMonitor(id: 2, rect: right, isMain: false)
        plug([main, external])
        let ext = Workspace.get(byName: "ext")
        XCTAssertTrue(external.setActiveWorkspace(ext))
        TestWindow.new(id: 1, parent: ext.rootTilingContainer).focusWindow()
        XCTAssertTrue(focus.workspace === ext)

        plug([main]) // external unplugged
        XCTAssertTrue(focus.workspace.isVisible, "focus must not stay on a workspace no monitor shows")
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testReplugRestoresTheWorkspaceTheMonitorShowed() async throws {
        let main = makeTestMonitor(id: 1, rect: left, isMain: true)
        let external = makeTestMonitor(id: 2, rect: right, isMain: false)
        plug([main, external])
        let mainWs = Workspace.get(byName: "main-ws")
        TestWindow.new(id: 1, parent: mainWs.rootTilingContainer).focusWindow()
        XCTAssertTrue(main.setActiveWorkspace(mainWs))
        let ext = Workspace.get(byName: "ext")
        TestWindow.new(id: 2, parent: ext.rootTilingContainer)
        XCTAssertTrue(external.setActiveWorkspace(ext))

        plug([main])
        plug([main, external])
        XCTAssertTrue(external.activeWorkspace === ext, "re-plugged display shows what it showed before")
    }

    func testNoMonitorsDoesNotRecurseForever() {
        let ghost = makeTestMonitor(id: 7, rect: left, isMain: true)
        unsafe testMonitorsOverride = []
        invalidateMonitorsCache()
        _ = ghost.activeWorkspace // used to recurse without end when `monitors` was empty
    }
}

@MainActor
final class MonitorSwapTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws {
        unsafe testMonitorsOverride = nil
        gcMonitors()
    }

    func testSwappingOneDisplayForAnotherRearranges() {
        let r = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        unsafe testMonitorsOverride = [makeTestMonitor(id: 1, rect: r, isMain: true)]
        invalidateMonitorsCache()
        gcMonitors()
        // Same count, different display (dock A → dock B)
        let b = makeTestMonitor(id: 2, rect: r, isMain: true)
        unsafe testMonitorsOverride = [b]
        invalidateMonitorsCache()
        gcMonitors()
        XCTAssertTrue(b.activeWorkspace.isVisible)
        XCTAssertTrue(focus.workspace.isVisible)
    }
}
