@testable import AppBundle
import Common
import XCTest

/// Guards the production discovery bug: when both a Linux config and
/// `~/.config/aerospace/aerospace.toml` exist, the Linux file is primary and the TOML is sidecar.
@MainActor
final class ConfigDiscoverySidecarTest: XCTestCase {
    func testLinuxPrimaryBeatsXdgAerospaceToml() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-discovery-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let xdg = home.appending(path: ".config")
        try FileManager.default.createDirectory(at: xdg.appending(path: "i3"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdg.appending(path: "aerospace"), withIntermediateDirectories: true)

        let i3Url = xdg.appending(path: "i3/config")
        let sidecarUrl = xdg.appending(path: "aerospace/aerospace.toml")
        try """
            set $mod Mod4
            bindsym $mod+h focus left
            bindsym $mod+j focus down
            """.write(to: i3Url, atomically: true, encoding: .utf8)
        try """
            [bar]
            enabled = true
            height = 33
            """.write(to: sidecarUrl, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1) Discovery precedence — the bug was returning the sidecar as primary.
        let discovered = resolveCustomConfigUrl(
            home: home,
            xdgConfigHome: xdg,
            forcedConfigLocation: nil,
        )
        guard case .file(let primary) = discovered else {
            return failExpectedActual("file(i3)", "\(discovered)")
        }
        assertEquals(primary.standardizedFileURL, i3Url.standardizedFileURL)

        // 2) Sidecar attaches only because primary is Linux.
        let side = resolveTomlSidecarUrl(
            primaryConfigUrl: primary,
            home: home,
            xdgConfigHome: xdg,
        )
        assertEquals(side?.standardizedFileURL, sidecarUrl.standardizedFileURL)

        // 3) Full load path used by runtime: primary through importer + sidecar overlay.
        let loaded = parseConfigFromDiscovery(home: home, xdgConfigHome: xdg)
        assertNotNil(loaded)
        assertEquals(loaded!.errors.map { $0.description(.error) }, [])
        // Keybindings from i3 primary
        assertFalse(loaded!.config.modes["main"]?.bindings.isEmpty ?? true)
        // macOS extras from sidecar
        assertTrue(loaded!.config.statusBar.enabled)
        assertEquals(loaded!.config.statusBar.height, 33)
        assertTrue(loaded!.warnings.contains { $0.message.contains("toml sidecar") })
    }

    func testHomeDotAerospaceTomlStillBeatsLinux() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-discovery-dot-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let xdg = home.appending(path: ".config")
        try FileManager.default.createDirectory(at: xdg.appending(path: "i3"), withIntermediateDirectories: true)
        let homeDot = home.appending(path: ".aerospace.toml")
        let i3Url = xdg.appending(path: "i3/config")
        try "start-at-login = false\n".write(to: homeDot, atomically: true, encoding: .utf8)
        try "set $mod Mod4\nbindsym $mod+h focus left\n".write(to: i3Url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let discovered = resolveCustomConfigUrl(
            home: home,
            xdgConfigHome: xdg,
            forcedConfigLocation: nil,
        )
        guard case .file(let primary) = discovered else {
            return failExpectedActual("file(homeDot)", "\(discovered)")
        }
        assertEquals(primary.standardizedFileURL, homeDot.standardizedFileURL)
        // Native TOML primary → no sidecar overlay of the same role
        assertNil(resolveTomlSidecarUrl(primaryConfigUrl: primary, home: home, xdgConfigHome: xdg))
    }

    func testXdgTomlIsPrimaryWhenNoLinuxConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aerospace-discovery-xdg-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        let xdg = home.appending(path: ".config")
        try FileManager.default.createDirectory(at: xdg.appending(path: "aerospace"), withIntermediateDirectories: true)
        let xdgToml = xdg.appending(path: "aerospace/aerospace.toml")
        try "start-at-login = true\n".write(to: xdgToml, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let discovered = resolveCustomConfigUrl(
            home: home,
            xdgConfigHome: xdg,
            forcedConfigLocation: nil,
        )
        guard case .file(let primary) = discovered else {
            return failExpectedActual("file(xdgToml)", "\(discovered)")
        }
        assertEquals(primary.standardizedFileURL, xdgToml.standardizedFileURL)
    }
}
