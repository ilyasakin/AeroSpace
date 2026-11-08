@testable import AppBundle
import XCTest

@MainActor
final class WindowDimmingTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Headless.resetForTests()
    }

    func testOnlyChangesAreSent() {
        XCTAssertEqual(dimmingChanges(applied: [:], wanted: [1: 0, 2: -0.1, 3: -0.1]), [-0.1: [2, 3]],
                       "a window never dimmed needs no 0")
        XCTAssertEqual(dimmingChanges(applied: [1: 0, 2: -0.1, 3: -0.1], wanted: [1: -0.1, 2: 0, 3: -0.1]),
                       [-0.1: [1], 0: [2]], "focus moved from 1 to 2")
        XCTAssertEqual(dimmingChanges(applied: [1: 0, 2: -0.1], wanted: [1: 0]), [0: [2]],
                       "a dimmed window that left the screen is restored")
        XCTAssertEqual(dimmingChanges(applied: [2: -0.1], wanted: [2: -0.1]), [:])
    }

    func testAmountMapsToBrightness() {
        XCTAssertEqual(DimInactiveWindows(enabled: true, amount: 10).brightness, -0.1, accuracy: 1e-6)
        XCTAssertEqual(DimInactiveWindows(enabled: true, amount: 500).brightness, -0.9, accuracy: 1e-6, "never black")
        XCTAssertEqual(DimInactiveWindows(enabled: true, amount: -5).brightness, 0)
    }

    func testTheFocusedWindowIsNotDimmedAndOthersAre() {
        config.dimInactiveWindows = DimInactiveWindows(enabled: true, amount: 20)
        defer { config.dimInactiveWindows = DimInactiveWindows() }
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = a.focusWindow()
        WindowDimming.shared.refresh()
        XCTAssertEqual(WindowDimming.shared.applied[2] ?? 99, -0.2, accuracy: 1e-6)
        XCTAssertNil(WindowDimming.shared.applied[1], "never dimmed, so never touched")
        XCTAssertGreaterThan(Headless.blockedAttempts[.skyLightWindow] ?? 0, 0, "and under test it reaches no real window")
        config.dimInactiveWindows = DimInactiveWindows()
        WindowDimming.shared.refresh()
        XCTAssertTrue(WindowDimming.shared.applied.isEmpty)
    }

    func testTheConfigSectionParses() {
        let parsed = parseConfig(
            """
            [dim-inactive-windows]
            enabled = true
            amount = 15
            """,
        )
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
        XCTAssertEqual(parsed.config.dimInactiveWindows, DimInactiveWindows(enabled: true, amount: 15))
    }
}
