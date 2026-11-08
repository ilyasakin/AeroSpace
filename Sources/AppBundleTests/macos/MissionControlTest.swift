@testable import AppBundle
import CoreGraphics
import XCTest

@MainActor
final class MissionControlTest: XCTestCase {
    override func tearDown() async throws { MissionControl.resetForTests() }

    /// Window list captured on macOS 27.2 with Mission Control open (trimmed)
    private let missionControlOpen: [[String: Any]] = [
        window("Dock", layer: 20, 2560, 1440),
        window("WindowManager", layer: 19, 2560, 1440), // ExposeShieldWindow
        window("WindowManager", layer: 17, 66, 82), // app icon
        window("WindowManager", layer: 14, 2560, 202), // Spaces bar
        window("WindowManager", layer: -2_147_483_624, 2560, 1440), // wallpaper
    ]
    private let missionControlClosed: [[String: Any]] = [
        window("WindowManager", layer: -2_147_483_622, 2560, 1440), // fullscreen backdrop
        window("WindowManager", layer: -2_147_483_624, 2560, 1440),
        window("Safari", layer: 0, 1280, 1400),
    ]

    func testTheShieldWindowMeansMissionControlIsShowing() {
        XCTAssertTrue(MissionControl.scanForShield(missionControlOpen))
        XCTAssertFalse(MissionControl.scanForShield(missionControlClosed))
    }

    func testOnlyWindowManagersDisplaySizedLayer19Counts() {
        XCTAssertFalse(MissionControl.isShield(ownerName: "Dock", layer: 19, width: 2560, height: 1440))
        XCTAssertFalse(MissionControl.isShield(ownerName: "WindowManager", layer: 17, width: 2560, height: 1440))
        XCTAssertFalse(MissionControl.isShield(ownerName: "WindowManager", layer: 19, width: 66, height: 82))
        XCTAssertTrue(MissionControl.isShield(ownerName: "WindowManager", layer: 19, width: 1512, height: 982))
    }

    func testPollReportsOnlyTransitions() {
        var open = false
        MissionControl.readOverlayForTests = { open }
        XCTAssertFalse(MissionControl.poll())
        open = true
        XCTAssertTrue(MissionControl.poll())
        XCTAssertTrue(MissionControl.isShowing)
        XCTAssertFalse(MissionControl.poll())
        open = false
        XCTAssertTrue(MissionControl.poll())
        XCTAssertFalse(MissionControl.isShowing)
    }
}

private func window(_ owner: String, layer: Int, _ w: Double, _ h: Double) -> [String: Any] {
    [
        kCGWindowOwnerName as String: owner,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": w, "Height": h],
    ]
}
