@testable import AppBundle
import XCTest

@MainActor
final class StatusBarDetailTest: XCTestCase {
    func testWorldClockSpecs() throws {
        let named = try XCTUnwrap(WorldClock(spec: "San Francisco=America/Los_Angeles"))
        XCTAssertEqual(named.name, "San Francisco")
        XCTAssertEqual(named.timeZone.identifier, "America/Los_Angeles")
        XCTAssertEqual(WorldClock(spec: "America/New_York")?.name, "New York")
        XCTAssertNil(WorldClock(spec: "Not/AZone"))
    }

    func testWorldClockOffset() throws {
        let istanbul = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul")) // UTC+3, no DST
        let date = Date(timeIntervalSince1970: 1_794_000_000) // November 2026: New York on EST
        XCTAssertEqual(WorldClock(spec: "Asia/Tokyo")?.offset(from: istanbul, at: date), "+6h")
        XCTAssertEqual(WorldClock(spec: "America/New_York")?.offset(from: istanbul, at: date), "−8h")
        XCTAssertEqual(WorldClock(spec: "Asia/Kolkata")?.offset(from: istanbul, at: date), "+2h30m")
        XCTAssertEqual(WorldClock(spec: "Europe/Istanbul")?.offset(from: istanbul, at: date), "")
    }

    func testDefaultWorldClocksAreTheFourCities() {
        XCTAssertEqual(StatusBarConfig().worldClocks.compactMap(WorldClock.init(spec:)).map(\.name),
                       ["Istanbul", "New York", "San Francisco", "Tokyo"])
    }

    func testThermalSummaryGroupsSensors() {
        let t = ThermalSummary([
            .init(name: "PMU tdie1", celsius: 50), .init(name: "PMU tdie2", celsius: 60),
            .init(name: "PMU tdev1", celsius: 45), .init(name: "NAND CH0 temp", celsius: 33),
            .init(name: "gas gauge battery", celsius: 28),
        ])
        XCTAssertEqual(t.dieAverage, 55)
        XCTAssertEqual(t.dieMax, 60)
        XCTAssertEqual(t.packageMax, 45)
        XCTAssertEqual(t.ssd, 33)
        XCTAssertEqual(t.battery, 28)
        XCTAssertTrue(ThermalSummary([]).isEmpty)
    }

    func testEfficiencyCoresComeFirst() {
        let m3pro = CpuTopology(performance: 5, efficiency: 6)
        XCTAssertEqual((0 ..< 11).map(m3pro.kind(ofCore:)).joined(), "EEEEEEPPPPP")
        XCTAssertEqual(CpuTopology(performance: 8, efficiency: 0).kind(ofCore: 0), "P")
    }

    func testFormatting() {
        XCTAssertEqual(formatBytes(3 << 30), "3.0 GB")
        XCTAssertEqual(formatBytes(512 << 20), "512 MB")
        XCTAssertEqual(formatRate(2.5 * 1024 * 1024), "2.5 MB/s")
        XCTAssertEqual(formatRate(300), "300 B/s")
    }

    func testOnlyModulesWithDetailOpenAPanel() {
        XCTAssertEqual(["cpu", "gpu", "memory", "network", "clock", "battery", "workspaces"].compactMap(StatusBarDetailKind.init(module:)),
                       [.cpu, .gpu, .memory, .network, .clock])
    }

    func testThePanelNeverOpensUnderTest() {
        Headless.resetForTests()
        StatusBarDetailPanel.shared.toggle(.cpu, anchor: .zero, screen: nil)
        XCTAssertNil(StatusBarDetailPanel.shared.openKind)
        XCTAssertEqual(Headless.blockedAttempts[.onScreenPanel], 1)
    }

    func testWorldClocksConfig() {
        let parsed = parseConfig(
            """
            [bar]
            world-clocks = ['London=Europe/London', 'Asia/Tokyo']
            """,
        )
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
        XCTAssertEqual(parsed.config.statusBar.worldClocks, ["London=Europe/London", "Asia/Tokyo"])
    }
}
