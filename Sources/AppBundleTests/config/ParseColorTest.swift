@testable import AppBundle
import XCTest

final class ParseColorTest: XCTestCase {
    func testJankyBordersStyleAARRGGBB() {
        // 0xAARRGGBB — alpha first (JankyBorders format)
        let c = parseHexColor("0xffe1e3e4")
        assertEquals(c, RgbaColor(r: 0xE1, g: 0xE3, b: 0xE4, a: 0xFF))
    }

    func testJankyBordersStyleRRGGBB() {
        let c = parseHexColor("0x7aa2f7")
        assertEquals(c, RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7, a: 0xFF))
    }

    func testCssStyleRRGGBB() {
        assertEquals(parseHexColor("#7aa2f7"), RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7, a: 0xFF))
    }

    func testCssStyleRRGGBBAA() {
        // #RRGGBBAA — alpha last
        assertEquals(parseHexColor("#7aa2f780"), RgbaColor(r: 0x7A, g: 0xA2, b: 0xF7, a: 0x80))
    }

    func testHalfTransparentJanky() {
        assertEquals(parseHexColor("0x80ff0000"), RgbaColor(r: 0xFF, g: 0, b: 0, a: 0x80))
    }

    func testRejectsGarbage() {
        assertEquals(parseHexColor("blue"), nil)
        assertEquals(parseHexColor("0xzzzz"), nil)
        assertEquals(parseHexColor("#12345"), nil) // 5 digits
        assertEquals(parseHexColor("7aa2f7"), nil) // no prefix
    }
}
