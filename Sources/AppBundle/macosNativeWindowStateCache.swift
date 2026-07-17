import Foundation

/// Cache for per-window macOS native state (native fullscreen / minimized) that
/// normalizeLayoutReason would otherwise re-query over AX for every window on every refresh.
///
/// Invalidation happens on the AX notifications that accompany every real state change:
/// moved/resized (native fullscreen transitions always change the frame) and
/// miniaturized/deminiaturized. See MacWindow.invalidateAxFrameCaches.
@MainActor private var cache: [UInt32: MacosNativeWindowState] = [:]

struct MacosNativeWindowState {
    let isFullscreen: Bool
    let isMinimized: Bool
}

@MainActor
func getMacosNativeWindowState(_ window: Window) async throws -> MacosNativeWindowState {
    let windowId = window.windowId
    if let cached = cache[windowId] { return cached }
    guard let macWindow = window as? MacWindow else {
        // Unit tests. Don't cache, the generic API can't distinguish "false" from "AX error"
        let isFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMinimized: Bool = if isFullscreen { false } else { try await window.isMacosMinimized(.cancellable) }
        return MacosNativeWindowState(isFullscreen: isFullscreen, isMinimized: isMinimized)
    }
    // Both attributes in one thread-hop onto the app's AX thread
    let read = try await macWindow.macApp.nativeFullscreenAndMinimized(windowId, .cancellable)
    let isFullscreen = read?.fullscreen
    let isMinimized = read?.minimized
    let state = MacosNativeWindowState(isFullscreen: isFullscreen == true, isMinimized: isMinimized == true)
    // nil means the AX request failed (busy app, dying window) - don't cache, retry next refresh
    if isFullscreen != nil && isMinimized != nil {
        cache[windowId] = state
    }
    return state
}

@MainActor
func invalidateMacosNativeWindowStateCache(windowId: UInt32) {
    cache.removeValue(forKey: windowId)
}
