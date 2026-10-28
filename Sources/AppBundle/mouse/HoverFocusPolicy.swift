import CoreGraphics
import Foundation

/// One pointer-motion sample.
struct HoverSample: Equatable {
    var point: CGPoint
    /// WindowServer's own hit test for the event (annotated event tap), 0 when unknown
    var windowIdUnderPointer: UInt32
    var isSynthetic: Bool = false
    var buttonsDown: Bool = false
}

/// Memory between samples.
struct HoverState: Equatable {
    /// The managed window the pointer is over (i3: the window that last got an EnterNotify)
    var lastHoveredId: UInt32? = nil
    /// Monotonic time before which a hover never changes focus
    var suppressUntil: TimeInterval = 0
}

enum HoverIgnoreReason: Equatable {
    case disabled, synthetic, buttonDown, dragging, unmanagedUnderPointer, nothingUnderPointer
    /// Still inside the window the pointer was already over — i3 acts on ENTER only
    case noEnter
    case suppressed, alreadyFocused
}

enum HoverDecision: Equatable {
    case ignore(HoverIgnoreReason)
    case focus(UInt32)
}

struct HoverContext {
    var enabled: Bool
    var isDragging: Bool
    var focusedWindowId: UInt32?
    var now: TimeInterval
    /// Is this id a managed window focus may go to (on a visible workspace, not parked)?
    var isFocusable: (UInt32) -> Bool
    /// The layout model's answer when WindowServer didn't report a window (id 0)
    var modelHit: (CGPoint) -> UInt32?
}

/// i3 `focus_follows_mouse` semantics, app-blind and IPC-free:
/// - focus changes only when the pointer ENTERS a different managed window. Moving inside a window
///   never refocuses it — so after a keyboard focus change the pointer resting in another window
///   does not steal focus back on the next nudge (the state is re-anchored, see `reanchor`).
/// - whatever WindowServer says is under the pointer wins, floats above tiles included; an
///   unmanaged window there (menu, Dock, desktop behind a gap, another app's popup, our own bar)
///   means "do nothing" — and leaving to it counts as leaving, like crossing i3's root window.
/// - synthetic motion (our own `move-mouse`), button-down and drags never focus.
enum HoverFocusPolicy {
    static func decide(_ sample: HoverSample, _ state: inout HoverState, _ ctx: HoverContext) -> HoverDecision {
        if !ctx.enabled { return .ignore(.disabled) }
        if sample.isSynthetic { return .ignore(.synthetic) }
        if sample.buttonsDown { return .ignore(.buttonDown) }
        if ctx.isDragging { return .ignore(.dragging) }
        let target: UInt32
        if sample.windowIdUnderPointer != 0 {
            guard ctx.isFocusable(sample.windowIdUnderPointer) else {
                state.lastHoveredId = nil
                return .ignore(.unmanagedUnderPointer)
            }
            target = sample.windowIdUnderPointer
        } else {
            guard let hit = ctx.modelHit(sample.point) else {
                state.lastHoveredId = nil
                return .ignore(.nothingUnderPointer)
            }
            target = hit
        }
        if target == state.lastHoveredId { return .ignore(.noEnter) }
        state.lastHoveredId = target
        if ctx.now < state.suppressUntil { return .ignore(.suppressed) }
        if target == ctx.focusedWindowId { return .ignore(.alreadyFocused) }
        return .focus(target)
    }

    /// After a focus change that did NOT come from hovering (keyboard, command, click) or a
    /// layout change moved windows under a resting pointer: whatever is under the pointer now is
    /// the "entered" window. i3 gets the same effect by ignoring the EnterNotify events its own
    /// map/configure requests generate.
    static func reanchor(_ state: inout HoverState, windowUnderPointer: UInt32?) {
        state.lastHoveredId = windowUnderPointer
    }
}
