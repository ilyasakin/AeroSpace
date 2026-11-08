@testable import AppBundle
import Foundation
import XCTest

final class PrivateFocusEventTest: XCTestCase {
    func testMakeKeyIsASingleMouseDownFarOffScreen() {
        let bytes = PrivateFocus.makeKeyWindowEventBytes(windowId: 0x1234_5678)
        XCTAssertEqual(bytes.count, 0x100, "zeroed room for WindowServer's overread")
        XCTAssertEqual(bytes[0x04], 0xF8)
        XCTAssertEqual(bytes[0x08], 0x01, "mouse down; never a down/up click")
        XCTAssertEqual(bytes[0x3A], 0x10)
        XCTAssertEqual(double(bytes, 0x20), 300_000)
        XCTAssertEqual(double(bytes, 0x28), 300_000)
        XCTAssertFalse(double(bytes, 0x20).isNaN, "NaN becomes (0, 0) in some apps and clicks real UI")
        XCTAssertEqual(Array(bytes[0x3C ..< 0x40]), [0x78, 0x56, 0x34, 0x12])
        XCTAssertTrue(bytes[0xF8...].allSatisfy { $0 == 0 })
    }

    func testSameAppSwitchRecordsUseTheZeroedBuffer() {
        let unfocus = PrivateFocus.sameAppSwitchEventBytes(windowId: 7, phase: .unfocusPrevious)
        let focus = PrivateFocus.sameAppSwitchEventBytes(windowId: 7, phase: .focusNext)
        XCTAssertEqual(unfocus.count, 0x100)
        XCTAssertEqual(unfocus[0x08], 0x0D)
        XCTAssertEqual(unfocus[0x8A], 0x02)
        XCTAssertEqual(focus[0x8A], 0x01)
        XCTAssertTrue(focus[0xF8...].allSatisfy { $0 == 0 })
    }

    private func double(_ bytes: [UInt8], _ offset: Int) -> Double {
        var bits: UInt64 = 0
        for i in 0 ..< 8 { bits |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        return Double(bitPattern: bits)
    }
}
