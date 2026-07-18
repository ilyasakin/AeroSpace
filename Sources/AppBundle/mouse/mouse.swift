import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

/// Whether `window` is being moved/resized with the mouse (button down).
/// Fast path: once we know the manipulated id, skip AX focus checks on every drag tick.
@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    if window.isHiddenInCorner { return false } // Don't allow to resize/move windows of hidden workspaces
    if !isLeftMouseButtonDown { return false }
    if currentlyManipulatedWithMouseWindowId == window.windowId {
        return true
    }
    if currentlyManipulatedWithMouseWindowId != nil {
        return false // another window is the drag target
    }
    // First tick of a drag: confirm native focus (AX). Caller should stamp the id before light session.
    return try await getNativeFocusedWindow(.cancellable) == window
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
