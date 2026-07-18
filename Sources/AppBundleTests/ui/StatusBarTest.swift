@testable import AppBundle
import Common
import XCTest

final class StatusBarProtocolTest: XCTestCase {
    func testI3barParserHeaderAndBlocks() {
        let parser = I3barProtocolParser()
        let stream = """
            {"version":1,"click_events":true}
            [
            [{"full_text":"hello","name":"greet","color":"#ffffff"}],
            [{"full_text":"world","name":"greet"}]
            """
        let lines = parser.feed(stream)
        assertEquals(parser.header?.version, 1)
        assertEquals(parser.header?.clickEvents, true)
        assertEquals(lines.count, 2)
        assertEquals(lines[0][0].fullText, "hello")
        assertEquals(lines[0][0].name, "greet")
        assertEquals(lines[1][0].fullText, "world")
    }

    func testI3barParserIncremental() {
        let parser = I3barProtocolParser()
        _ = parser.feed("{\"version\":1}\n[\n")
        let a = parser.feed("[{\"full_text\":\"a\"}],\n")
        assertEquals(a.count, 1)
        assertEquals(a[0][0].fullText, "a")
        let b = parser.feed("[{\"full_text\":\"b\"}]\n")
        assertEquals(b.count, 1)
        assertEquals(b[0][0].fullText, "b")
    }

    func testClickEventJson() {
        let e = I3barClickEvent(name: "clock", instance: "0", button: 1, x: 10, y: 20)
        let s = e.jsonLine()
        let obj = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        assertEquals(obj["name"] as? String, "clock")
        assertEquals(obj["button"] as? Int, 1)
    }

    func testFirstCompleteJsonValueEnd() {
        assertEquals(firstCompleteJsonValueEnd(in: #"{"a":1}"#), 7)
        assertNil(firstCompleteJsonValueEnd(in: #"{"a":"#))
        assertEquals(firstCompleteJsonValueEnd(in: #"[{"x":1}]"#), 9)
    }
}

final class StatusBarNativeModulesTest: XCTestCase {
    func testClockFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0) // 00:00 UTC
        assertEquals(StatusBarClock.text(date: date, calendar: cal), "00:00")
    }

    func testBatteryText() {
        assertEquals(
            StatusBarBattery.text(from: .init(percent: 80, isCharging: false, isPresent: true)),
            "🔋80%",
        )
        assertEquals(
            StatusBarBattery.text(from: .init(percent: 50, isCharging: true, isPresent: true)),
            "⚡50%",
        )
        assertNil(StatusBarBattery.text(from: .init(percent: nil, isCharging: false, isPresent: false)))
    }

    func testMemoryTextUsesUsedFractionNotTotalOnly() {
        let snap = StatusBarCpuMem.MemorySnapshot(
            usedFraction: 0.42,
            usedBytes: 42,
            totalBytes: 100,
        )
        assertEquals(StatusBarCpuMem.memoryText(from: snap), "MEM 42%")
        // Live snapshot should be in 0...100% and not a constant total-RAM string.
        let live = StatusBarCpuMem.memoryText()
        assertTrue(live.hasPrefix("MEM "))
        assertTrue(live.hasSuffix("%"))
        assertFalse(live.contains("G"))
    }

    func testHexColorI3barRRGGBBAA() {
        // i3bar 8-digit: RRGGBBAA — red fully opaque
        let c = NSColor(hex: "#FF0000FF")
        assertNotNil(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c!.getRed(&r, green: &g, blue: &b, alpha: &a)
        assertTrue(abs(r - 1) < 0.01)
        assertTrue(abs(g) < 0.01)
        assertTrue(abs(b) < 0.01)
        assertTrue(abs(a - 1) < 0.01)
    }

    func testVolumeText() {
        assertEquals(StatusBarVolume.text(from: .init(percent: 40, isMuted: false)), "🔉 40%")
        assertEquals(StatusBarVolume.text(from: .init(percent: 0, isMuted: true)), "🔇 mute")
        assertEquals(StatusBarVolume.text(from: .init(percent: 80, isMuted: false)), "🔊 80%")
    }

    func testNetworkText() {
        assertEquals(
            StatusBarNetwork.text(from: .init(interface: "en0", address: "10.0.0.2", isUp: true)),
            "🌐 en0 10.0.0.2",
        )
        assertEquals(
            StatusBarNetwork.text(from: .init(interface: "—", address: nil, isUp: false)),
            "🌐 offline",
        )
    }

    @MainActor
    func testSystemModuleTextResolvesVolumeAndNetwork() {
        // Live calls are environment-dependent; ensure they return non-nil strings (never silent skip).
        assertNotNil(statusBarSystemModuleText("volume"))
        assertNotNil(statusBarSystemModuleText("network"))
        assertNotNil(statusBarSystemModuleText("clock"))
        assertNotNil(statusBarSystemModuleText("cpu"))
        assertNotNil(statusBarSystemModuleText("gpu"))
        assertNil(statusBarSystemModuleText("workspaces")) // WM-state modules are not system text
    }

    func testCpuCoreLoadsDelta() {
        let prev: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = [
            (100, 50, 50, 0), // 150 busy / 200 total
            (10, 0, 90, 0),
        ]
        let curr: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = [
            (200, 100, 100, 0), // +150 busy / +200 total → 0.75
            (20, 0, 180, 0), // +10 busy / +100 total → 0.10
        ]
        let loads = cpuCoreLoads(previous: prev, current: curr)
        assertEquals(loads.count, 2)
        assertTrue(abs(loads[0] - 0.75) < 0.001)
        assertTrue(abs(loads[1] - 0.10) < 0.001)
    }

    func testSparklineLayoutWidthIndependentOfCoreCount() {
        let layout = defaultSparklineLayout(sampleCount: 30, trailingWidth: sparklinePercentTrailingWidth())
        assertTrue(layout.totalWidth > 80)
        // Full load uses most of the track height
        let bar = layout.barFrame(sampleIndex: 0, load: 0.5, viewHeight: 28)
        assertTrue(bar.height > 5)
        assertTrue(bar.height <= 28)
        // Width does not grow with "core count" — average sparkline is fixed capacity.
        let layout2 = defaultSparklineLayout(sampleCount: 30, trailingWidth: sparklinePercentTrailingWidth())
        assertEquals(layout.totalWidth, layout2.totalWidth)
    }

    func testCpuSampleAverageAndPeak() {
        assertEquals(cpuSampleAverage([0.2, 0.4, 0.6, 0.8]), 0.5)
        assertEquals(cpuSamplePeak([0.2, 0.4, 0.6, 0.8]), 0.8)
        assertEquals(cpuSampleAverage([]), 0)
        assertEquals(cpuSamplePeak([]), 0)
    }

    func testAppendHistorySampleRingBuffer() {
        var h: [[Double]] = []
        for i in 0 ..< 5 {
            h = appendHistorySample(h, sample: [Double(i)], capacity: 3)
        }
        // Keep last 3: 2, 3, 4
        assertEquals(h.count, 3)
        assertEquals(h[0], [2])
        assertEquals(h[2], [4])
    }

    func testAppendHistoryResetsWhenCoreCountChanges() {
        var h = [[0.1, 0.2], [0.3, 0.4]]
        h = appendHistorySample(h, sample: [0.5, 0.6, 0.7], capacity: 10)
        assertEquals(h.count, 1)
        assertEquals(h[0].count, 3)
    }
}

@MainActor
final class StatusBarConfigTest: XCTestCase {
    func testParseBarSection() {
        let toml = """
            [bar]
            enabled = true
            height = 32
            modules-left = ['workspaces', 'mode']
            modules-right = ['clock', 'battery']
            hide-empty-workspaces = true
            status-command = ['/bin/echo', 'noop']
            """
        let result = parseConfig(toml)
        assertEquals(result.errors.map { $0.description(.error) }, [])
        assertTrue(result.config.statusBar.enabled)
        assertEquals(result.config.statusBar.height, 32)
        assertEquals(result.config.statusBar.modulesLeft, ["workspaces", "mode"])
        assertEquals(result.config.statusBar.modulesRight, ["clock", "battery"])
        assertTrue(result.config.statusBar.hideEmptyWorkspaces)
        assertEquals(result.config.statusBar.statusCommand, ["/bin/echo", "noop"])
    }

    func testBarDisabledByDefault() {
        let result = parseConfig("start-at-login = false\n")
        assertFalse(result.config.statusBar.enabled)
        assertFalse(result.config.statusBar.hideEmptyWorkspaces)
    }

    func testHideEmptyWorkspacesFilter() {
        // Default: show everything
        assertTrue(statusBarShouldShowWorkspace(isEmpty: true, isFocused: false, hideEmpty: false))
        assertTrue(statusBarShouldShowWorkspace(isEmpty: false, isFocused: false, hideEmpty: false))
        // Hide empty, keep focused even when empty
        assertFalse(statusBarShouldShowWorkspace(isEmpty: true, isFocused: false, hideEmpty: true))
        assertTrue(statusBarShouldShowWorkspace(isEmpty: true, isFocused: true, hideEmpty: true))
        assertTrue(statusBarShouldShowWorkspace(isEmpty: false, isFocused: false, hideEmpty: true))
        assertTrue(statusBarShouldShowWorkspace(isEmpty: false, isFocused: true, hideEmpty: true))
    }
}
