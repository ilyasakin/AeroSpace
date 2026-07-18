@testable import AppBundle
import Common
import XCTest

@MainActor
final class ParseBorderStyleTest: XCTestCase {
    func testSolidHex() {
        assertEquals(parseBorderStyleString("#7aa2f7"), .solid(RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7)))
        assertEquals(parseBorderStyleString("0xff33ccff")?.primaryColor.alpha ?? 0 > 0, true)
    }

    func testGradient() {
        let style = parseBorderStyleString("gradient(45deg, #ff0000, #0000ff)")
        guard case .gradient(let angle, let stops) = style else {
            return failExpectedActual("gradient", style as Any)
        }
        assertEquals(angle, 45)
        assertEquals(stops.count, 2)
    }

    func testGlow() {
        let style = parseBorderStyleString("glow(#33ccff, 12)")
        guard case .glow(let color, let blur) = style else {
            return failExpectedActual("glow", style as Any)
        }
        assertEquals(blur, 12)
        assertEquals(color.blue > 0, true)
    }

    func testWindowBordersConfigGradient() {
        let toml = """
            [window-borders]
            enabled = true
            active-color = 'gradient(90deg, #ff0000, #00ff00)'
            inactive-color = 'glow(#444444, 6)'
            width = 3
            """
        let result = parseConfig(toml)
        assertEquals(result.errors.map { $0.description(.error) }, [])
        assertTrue(result.config.windowBorders.enabled)
        guard case .gradient = result.config.windowBorders.resolvedActiveStyle() else {
            return failExpectedActual("active gradient", result.config.windowBorders.activeStyle as Any)
        }
        guard case .glow(_, let blur) = result.config.windowBorders.resolvedInactiveStyle() else {
            return failExpectedActual("inactive glow", result.config.windowBorders.inactiveStyle as Any)
        }
        assertEquals(blur, 6)
    }

    func testHyprBorderImport() {
        let hypr = """
            decoration {
                col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
                col.inactive_border = rgba(595959aa)
                rounding = 8
            }
            general {
                border_size = 3
            }
            """
        let result = importHyprConfig(hypr)
        assertTrue(result.toml.contains("window-borders"))
        assertTrue(result.toml.contains("active-color"))
        assertTrue(result.toml.contains("gradient") || result.toml.contains("0x"))
        let parsed = parseConfig(result.toml)
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
    }
}
