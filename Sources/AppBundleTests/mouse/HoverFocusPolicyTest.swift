@testable import AppBundle
import Common
import XCTest

final class HoverFocusPolicyTest: XCTestCase {
    private func ctx(focused: UInt32? = nil, managed: Set<UInt32> = [1, 2, 3], model: UInt32? = nil,
                     now: TimeInterval = 100, dragging: Bool = false) -> HoverContext
    {
        HoverContext(enabled: true, isDragging: dragging, focusedWindowId: focused, now: now,
                     isFocusable: { managed.contains($0) }, modelHit: { _ in model })
    }
    private func at(_ id: UInt32) -> HoverSample { HoverSample(point: .zero, windowIdUnderPointer: id) }

    func testFocusesOnlyOnEnter() {
        var st = HoverState()
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, ctx(focused: 1)), .focus(2))
        // Moving inside window 2 again (e.g. focus went elsewhere meanwhile): no enter, no focus
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, ctx(focused: 3)), .ignore(.noEnter))
        XCTAssertEqual(HoverFocusPolicy.decide(at(3), &st, ctx(focused: 2)), .focus(3))
    }

    func testKeyboardFocusChangeIsNotUndoneByANudge() {
        var st = HoverState()
        _ = HoverFocusPolicy.decide(at(1), &st, ctx(focused: 2)) // pointer rests in 1, 1 focused
        // User presses `focus right` → 2; the pipeline re-anchors to what is under the pointer
        HoverFocusPolicy.reanchor(&st, windowUnderPointer: 1)
        XCTAssertEqual(HoverFocusPolicy.decide(at(1), &st, ctx(focused: 2)), .ignore(.noEnter))
    }

    func testLayoutMovingAWindowUnderTheRestingPointerDoesNotFocusIt() {
        var st = HoverState(lastHoveredId: 1)
        // `workspace 2`: window 3 is now under the pointer; re-anchored after the session
        HoverFocusPolicy.reanchor(&st, windowUnderPointer: 3)
        XCTAssertEqual(HoverFocusPolicy.decide(at(3), &st, ctx(focused: 2)), .ignore(.noEnter))
    }

    func testUnmanagedUnderPointerDoesNothingAndCountsAsLeaving() {
        var st = HoverState(lastHoveredId: 1)
        // A menu / the Dock / desktop behind a gap
        XCTAssertEqual(HoverFocusPolicy.decide(at(999), &st, ctx(focused: 2)), .ignore(.unmanagedUnderPointer))
        // Coming back into 1 is an enter again (like crossing i3's root window)
        XCTAssertEqual(HoverFocusPolicy.decide(at(1), &st, ctx(focused: 2)), .focus(1))
    }

    func testZeroIdFallsBackToLayoutModel() {
        var st = HoverState()
        XCTAssertEqual(HoverFocusPolicy.decide(at(0), &st, ctx(focused: 1, model: 3)), .focus(3))
        XCTAssertEqual(HoverFocusPolicy.decide(at(0), &st, ctx(focused: 1, model: nil)), .ignore(.nothingUnderPointer))
    }

    func testSyntheticButtonDownDragAndDisabledNeverFocus() {
        var st = HoverState()
        var s = at(2)
        s.isSynthetic = true
        XCTAssertEqual(HoverFocusPolicy.decide(s, &st, ctx()), .ignore(.synthetic))
        s = at(2)
        s.buttonsDown = true
        XCTAssertEqual(HoverFocusPolicy.decide(s, &st, ctx()), .ignore(.buttonDown))
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, ctx(dragging: true)), .ignore(.dragging))
        var off = ctx()
        off.enabled = false
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, off), .ignore(.disabled))
        XCTAssertNil(st.lastHoveredId, "ignored samples must not consume the enter")
    }

    func testSuppressionWindowConsumesTheEnter() {
        var st = HoverState(suppressUntil: 200)
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, ctx(focused: 1, now: 150)), .ignore(.suppressed))
        XCTAssertEqual(HoverFocusPolicy.decide(at(2), &st, ctx(focused: 1, now: 250)), .ignore(.noEnter))
    }

    func testEnteringTheFocusedWindowIsANoop() {
        var st = HoverState()
        XCTAssertEqual(HoverFocusPolicy.decide(at(1), &st, ctx(focused: 1)), .ignore(.alreadyFocused))
    }
}
