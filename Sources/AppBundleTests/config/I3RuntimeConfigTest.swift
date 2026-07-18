@testable import AppBundle
import Common
import XCTest

@MainActor
final class I3RuntimeConfigTest: XCTestCase {
    func testDetectI3ByPath() {
        let i3 = """
            set $mod Mod4
            bindsym $mod+Return exec kitty
            """
        assertEquals(
            detectConfigFormat(text: i3, url: URL(filePath: "/Users/me/.config/i3/config")),
            .i3,
        )
        assertEquals(
            detectConfigFormat(text: i3, url: URL(filePath: "/Users/me/.i3/config")),
            .i3,
        )
    }

    func testSniffI3WhenExtensionLess() {
        let i3 = """
            set $mod Mod4
            bindsym $mod+h focus left
            bindsym $mod+1 workspace number 1
            for_window [class="Firefox"] floating enable
            """
        assertEquals(sniffConfigFormat(i3), .i3)
        assertEquals(detectConfigFormat(text: i3, url: nil), .i3)
    }

    func testParseConfigTextRoutesI3AndSurfacesDiagnostics() {
        let i3 = """
            set $mod Mod4
            bindsym $mod+Return exec open -a Terminal
            bindsym $mod+h focus left
            bindsym $mod+Shift+q kill
            bar {
                status_command i3status
            }
            """
        let result = parseConfigText(i3, sourceUrl: URL(filePath: "/tmp/i3/config"))
        assertEquals(result.errors.map { $0.description(.error) }, [])
        let mainBindings = result.config.modes["main"]?.bindings ?? [:]
        assertFalse(mainBindings.isEmpty)
        // bar block is not supported on macOS — should surface as import diagnostic/warning
        assertTrue(result.warnings.contains { $0.message.lowercased().contains("bar") || $0.message.contains("i3bar") || $0.message.contains("status") })
    }

    func testReadConfigLoadsI3File() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-i3-m1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let configUrl = tmp.appending(path: "config")
        // Path must look like i3/config for extension-less detection
        let i3Dir = tmp.appending(path: "i3")
        try FileManager.default.createDirectory(at: i3Dir, withIntermediateDirectories: true)
        let i3Path = i3Dir.appending(path: "config")
        let i3 = """
            set $mod Mod4
            bindsym $mod+h focus left
            bindsym $mod+j focus down
            bindsym $mod+1 workspace number 1
            """
        try i3.write(to: i3Path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = readConfig(forceConfigUrl: i3Path)
        let parsed = result.parseConfigResult
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
        let bindings = parsed.config.modes["main"]?.bindings ?? [:]
        assertTrue(bindings.count >= 3)
        _ = configUrl
    }

    func testTomlSidecarOverlaysLinuxPrimary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appending(path: "i3"), withIntermediateDirectories: true)
        let i3Path = tmp.appending(path: "i3/config")
        let i3 = """
            set $mod Mod4
            bindsym $mod+h focus left
            """
        try i3.write(to: i3Path, atomically: true, encoding: .utf8)

        // Simulate sidecar merge via parseConfig base (pure unit of overlay-wins)
        let primary = parseConfigText(i3, sourceUrl: i3Path)
        assertEquals(primary.errors.map { $0.description(.error) }, [])
        let beforeBorders = primary.config.windowBorders.enabled

        let sidecarToml = """
            [window-borders]
            enabled = true
            width = 3
            """
        let overlaid = parseConfig(sidecarToml, base: primary.config)
        assertEquals(overlaid.errors.map { $0.description(.error) }, [])
        assertTrue(overlaid.config.windowBorders.enabled)
        assertEquals(overlaid.config.windowBorders.width, 3)
        // Bindings from primary must survive
        assertFalse(overlaid.config.modes["main"]?.bindings.isEmpty ?? true)
        // Primary alone didn't enable borders (unless importer did)
        if !beforeBorders {
            assertTrue(overlaid.config.windowBorders.enabled)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParseConfigTextAppliesSidecarWhenPresentOnDisk() throws {
        // End-to-end: primary i3 path + real sidecar file path via findTomlSidecarUrl logic.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-sidecar-e2e-\(UUID().uuidString)")
        let i3Dir = tmp.appending(path: "i3")
        try FileManager.default.createDirectory(at: i3Dir, withIntermediateDirectories: true)
        let i3Path = i3Dir.appending(path: "config")
        try """
            set $mod Mod4
            bindsym $mod+Return exec open -a Terminal
            """.write(to: i3Path, atomically: true, encoding: .utf8)

        // applyTomlSidecar is what readConfig uses when findTomlSidecarUrl returns a path
        let primary = parseConfigText(
            try String(contentsOf: i3Path, encoding: .utf8),
            sourceUrl: i3Path,
        )
        let sidecar = tmp.appending(path: "aerospace.toml")
        try """
            [bar]
            enabled = true
            height = 30
            """.write(to: sidecar, atomically: true, encoding: .utf8)
        let merged = applyTomlSidecar(primary: primary, sidecarUrl: sidecar)
        assertEquals(merged.errors.map { $0.description(.error) }, [])
        assertTrue(merged.config.statusBar.enabled)
        assertEquals(merged.config.statusBar.height, 30)
        assertFalse(merged.config.modes["main"]?.bindings.isEmpty ?? true)
        assertTrue(merged.warnings.contains { $0.message.contains("toml sidecar") })
        try? FileManager.default.removeItem(at: tmp)
    }

    func testConfExtensionSniffsI3NotAlwaysHyprland() {
        let i3 = """
            set $mod Mod4
            bindsym $mod+h focus left
            """
        assertEquals(
            detectConfigFormat(text: i3, url: URL(filePath: "/tmp/something.conf")),
            .i3,
        )
    }

    func testLinuxCompatCandidatesOrder() {
        let home = URL(filePath: "/Users/test")
        let xdg = URL(filePath: "/Users/test/.config")
        let c = linuxCompatConfigCandidates(xdgConfigHome: xdg, home: home)
        assertEquals(c.map(\.kind), ["i3", "i3", "Hyprland"])
        assertEquals(c[0].url.path, "/Users/test/.config/i3/config")
        assertEquals(c[1].url.path, "/Users/test/.i3/config")
        assertEquals(c[2].url.path, "/Users/test/.config/hypr/hyprland.conf")
    }
}
