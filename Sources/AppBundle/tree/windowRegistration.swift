import AppKit
import Common

/// A window macOS just reported (discovery, or the focused-window read): decide where it goes,
/// register it, run the detection callbacks. Model policy — the macOS port only reports the window
/// and constructs its node (`make`, given the parent to bind to).
@MainActor
func registerDiscoveredWindow(
    windowId: UInt32,
    appBundleId: String?,
    frame: Rect?,
    windowType: AxUiElementWindowType,
    make: (NonLeafTreeNodeObject) -> Window,
) async throws -> Window {
    // atomic synchronous section
    if let existing = Window.registry[windowId] { return existing }

    // Workspace choice, in trust order:
    // 1. Session-restore grace (window discovered AFTER restoreIfPossible — slow AX at
    //    startup). CONSUMED HERE, after every cancellable await: these sessions are cancelled
    //    by any AX notification, and consuming before the awaits burned the placement on
    //    registrations that never completed.
    // 2. Recently-departed memory (transient AX disappearance / fullscreen round-trip —
    //    the window's old workspace, not wherever the user happens to be now).
    // 3. Startup: monitor approximation. Otherwise: the focused workspace.
    // A popup (splash screen, "reopen windows?" prompt, tooltip) goes to the popup container:
    // it must not use up the placement its app's real window is about to need
    let remembered = windowType == .popup ? nil : WindowMemory.recallWorkspace(windowId: windowId, appId: appBundleId)
    let workspace = remembered
        ?? (isStartup
            ? (frame?.center.monitorApproximation ?? mainMonitor).activeWorkspace
            : focus.workspace)

    let window: Window
    switch windowType {
        case .popup:
            window = make(macosPopupWindowsContainer)
        case .dialog:
            window = make(workspace.floatingWindowsContainer)
        case .window:
            // Park floating first; path-copy place into tiling spine then materialize (dual-link rebuilt)
            window = make(workspace.floatingWindowsContainer)
            Window.registry[windowId] = window
            workspace.placeRegisteredWindow(window)
    }
    if windowType != .window {
        Window.registry[windowId] = window
    }

    try await debugWindowsIfRecording(window, .cancellable)
    window.cachedTitle = try? await window.getTitle(.cancellable)
    if try await !WindowMemory.restoreWorldIfReturning(window) {
        await tryOnWindowDetected(window)
    }
    return window
}
