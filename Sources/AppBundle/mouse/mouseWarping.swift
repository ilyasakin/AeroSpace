import AppKit
import Common

/// i3 `mouse_warping`: what the pointer does when a command moves focus.
enum MouseWarping: String, Sendable, Equatable {
    /// Never move the pointer
    case none
    /// Move it to the centre of the newly focused monitor when focus crosses monitors (i3 default)
    case output
    /// Move it to the centre of the newly focused window when it is outside that window
    case container
}

/// Pure: where to warp the pointer, or nil to leave it.
func mouseWarpTarget(
    mode: MouseWarping,
    pointer: CGPoint,
    focusedWindowRect: Rect?,
    focusedMonitorRect: Rect,
    focusedMonitorChanged: Bool,
) -> CGPoint? {
    switch mode {
        case .none:
            return nil
        case .output:
            guard focusedMonitorChanged, !focusedMonitorRect.contains(pointer) else { return nil }
            return focusedMonitorRect.center
        case .container:
            if let rect = focusedWindowRect {
                return rect.contains(pointer) ? nil : rect.center
            }
            // Empty workspace: like output
            guard focusedMonitorChanged, !focusedMonitorRect.contains(pointer) else { return nil }
            return focusedMonitorRect.center
    }
}

/// Only focus changes a COMMAND made warp the pointer (hotkey, CLI, i3 IPC, menu) — never hover,
/// clicks or macOS-originated focus changes (the pointer is already where the user wants it).
@MainActor
func applyMouseWarping(_ focus: LiveFocus, focusedMonitorChanged: Bool) {
    guard config.mouseWarping != .none, let event = refreshSessionEvent else { return }
    switch event {
        case .hotkeyBinding, .socketServer, .i3IpcRunCommand, .menuBarButton: break
        case .ax, .globalObserver, .globalObserverLeftMouseUp, .focusFollowsMouse, .startup,
             .configAutoReload, .resetManipulatedWithMouse: return
    }
    let window = focus.windowOrNil
    let rect = window.flatMap { $0.desiredRect ?? $0.knownFrame ?? $0.lastAppliedLayoutVirtualRect }
    guard let target = mouseWarpTarget(
        mode: config.mouseWarping,
        pointer: HoverFocus.pointerLocation(),
        focusedWindowRect: rect,
        focusedMonitorRect: focus.workspace.workspaceMonitor.rect,
        focusedMonitorChanged: focusedMonitorChanged,
    ) else { return }
    // A warp posts no mouse event, so it can't feed back into hover focus
    if Headless.permits(.synthesizeInput) {
        CGWarpMouseCursorPosition(target)
    }
    HoverFocusPolicy.reanchor(&HoverFocus.state, windowUnderPointer: window?.windowId)
}
