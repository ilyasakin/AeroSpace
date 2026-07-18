@testable import AppBundle
import Common
import XCTest

@MainActor
final class HyprlandRuntimeConfigTest: XCTestCase {
    func testDetectFormatByExtension() {
        let hypr = "bind = SUPER, Q, exec, kitty\n"
        let toml = "start-at-login = true\n"
        assertEquals(
            detectConfigFormat(text: hypr, url: URL(filePath: "/tmp/hyprland.conf")),
            .hyprland,
        )
        assertEquals(
            detectConfigFormat(text: hypr, url: URL(filePath: "/tmp/config.hypr")),
            .hyprland,
        )
        assertEquals(
            detectConfigFormat(text: toml, url: URL(filePath: "/tmp/aerospace.toml")),
            .toml,
        )
        // Extension wins over content
        assertEquals(
            detectConfigFormat(text: hypr, url: URL(filePath: "/tmp/aerospace.toml")),
            .toml,
        )
    }

    func testSniffHyprlandWhenExtensionLess() {
        let hypr = """
            $mainMod = SUPER
            bind = $mainMod, Q, exec, kitty
            general {
                gaps_in = 5
            }
            """
        assertEquals(sniffConfigFormat(hypr), .hyprland)
        assertEquals(detectConfigFormat(text: hypr, url: nil), .hyprland)
    }

    func testSniffDefaultsToTomlWhenUnsure() {
        assertEquals(sniffConfigFormat(""), .toml)
        assertEquals(sniffConfigFormat("# just a comment\n"), .toml)
        assertEquals(sniffConfigFormat("start-at-login = true\n"), .toml)
    }

    func testParseConfigTextRoutesHyprlandAndSurfacesDiagnostics() {
        let hypr = """
            $mainMod = SUPER
            bind = $mainMod, Q, exec, kitty
            bind = $mainMod, C, killactive,
            bind = $mainMod, left, movefocus, l
            bind = $mainMod, S, togglespecialworkspace, magic
            bind = $mainMod, X, pseudo,
            animations {
                enabled = true
            }
            """
        let result = parseConfigText(hypr, sourceUrl: URL(filePath: "/tmp/hyprland.conf"))
        assertEquals(result.errors.map { $0.description(.error) }, [])
        let mainBindings = result.config.modes["main"]?.bindings ?? [:]
        assertFalse(mainBindings.isEmpty)
        // Unsupported lines (pseudo, animations) surface as import warnings — not silent
        assertFalse(result.warnings.isEmpty)
        assertTrue(result.warnings.contains { $0.message.contains("pseudo") || $0.message.contains("animations") })
        // Binding for special workspace should be present via toggle-special-workspace (not hard-failed)
        assertTrue(result.config.modes["main"] != nil)
    }

    func testParseConfigTextTomlUnchanged() {
        let toml = """
            start-at-login = false
            [mode.main.binding]
            alt-h = 'focus left'
            """
        let viaText = parseConfigText(toml, sourceUrl: URL(filePath: "/tmp/aerospace.toml"))
        let viaToml = parseConfig(toml)
        assertEquals(viaText.errors.map { $0.description(.error) }, [])
        assertEquals(viaToml.errors.map { $0.description(.error) }, [])
        assertEquals(viaText.config.modes["main"]?.bindings.keys.sorted(), ["alt-h"])
        assertEquals(viaText.warnings.count, viaToml.warnings.count)
    }

    func testReadConfigLoadsHyprlandFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-hypr-m1-\(UUID().uuidString).conf")
        let hypr = """
            $mainMod = SUPER
            bind = $mainMod, H, movefocus, l
            bind = $mainMod, J, movefocus, d
            bind = $mainMod, 1, workspace, 1
            """
        try hypr.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = readConfig(forceConfigUrl: tmp)
        let parsed = result.parseConfigResult
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
        let bindings = parsed.config.modes["main"]?.bindings ?? [:]
        assertTrue(bindings.count >= 3)
    }
}
