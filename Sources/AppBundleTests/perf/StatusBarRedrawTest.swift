@testable import AppBundle
import Common
import XCTest

@MainActor
final class StatusBarRedrawTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        StatusBarSystemSampler.shared.resetForTests()
    }

    private func fingerprint(_ cfg: StatusBarConfig) -> StatusBarRenderFingerprint {
        statusBarRenderFingerprint(config: cfg, monitor: mainMonitor, externalBlocks: [], frame: .zero)
    }

    func testFingerprintIsStableWhenNothingShownChanges() {
        var cfg = StatusBarConfig()
        cfg.modulesLeft = ["workspaces"]
        cfg.modulesRight = []
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: focus.workspace.rootTilingContainer)
        _ = Window.get(byId: 1)!.focusWindow()
        let a = fingerprint(cfg)
        // Focus moves between windows of the same workspace: the workspaces module looks the same
        _ = Window.get(byId: 2)!.focusWindow()
        assertEquals(fingerprint(cfg), a)
    }

    func testFingerprintChangesWithFocusedWorkspace() {
        var cfg = StatusBarConfig()
        cfg.modulesLeft = ["workspaces"]
        cfg.modulesRight = []
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let a = fingerprint(cfg)
        _ = Workspace.get(byName: "other").focusWorkspace()
        XCTAssertNotEqual(fingerprint(cfg), a)
    }

    func testSamplerReadsOnlyConfiguredModulesOffMain() async {
        let done = expectation(description: "sampled")
        StatusBarSystemSampler.shared.sampleAsync(modules: ["battery"]) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        let latest = StatusBarSystemSampler.shared.latest
        XCTAssertNotNil(latest?.battery)
        XCTAssertNil(latest?.volume, "unconfigured module must not be read")
        XCTAssertNil(latest?.netTotals, "network flow sampling must not start unless configured")
        assertEquals(StatusBarSystemSampler.shared.version, 1)
    }
}
