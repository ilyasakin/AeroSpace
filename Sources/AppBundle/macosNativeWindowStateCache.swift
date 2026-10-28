import Foundation

/// Cache for per-window macOS native state (native fullscreen / minimized) that
/// normalizeLayoutReason would otherwise re-query over AX for every window on every refresh.
///
/// Invalidation happens on what accompanies every real state change: a frame change we didn't
/// make (native fullscreen transitions always change the frame; `judgeFrameNotification`), a
/// write macOS refused (`frameAnswered`), and miniaturized/deminiaturized (`noteNativeStateChanged`).
@MainActor private var cache: [UInt32: MacosNativeWindowState] = [:]

struct MacosNativeWindowState: Equatable {
    let isFullscreen: Bool
    let isMinimized: Bool
}

/// Sync peek for the hot path: when normalizeLayoutReason already knows a standard window is
/// normal (not fullscreen/minimized), skip the async get entirely
@MainActor
func peekMacosNativeWindowState(_ windowId: UInt32) -> MacosNativeWindowState? {
    cache[windowId]
}

/// `nil` when the state could not be READ. Callers must treat that as "unknown — change nothing":
/// reading a failure as "not fullscreen, not minimized" re-tiled a native-fullscreen video every
/// time its app was slow to answer AX, and the next good read parked it again (flapping, with the
/// siblings reflowing on every cycle).
@MainActor
func getMacosNativeWindowState(_ window: Window) async throws -> MacosNativeWindowState? {
    let windowId = window.windowId
    if let cached = cache[windowId] { return cached }
    guard let state = try await window.readMacosNativeState(.cancellable) else { return nil }
    if window is MacWindow { cache[windowId] = state } // test doubles: never cache
    return state
}

@MainActor
func invalidateMacosNativeWindowStateCache(windowId: UInt32) {
    cache.removeValue(forKey: windowId)
}

/// Pure: a window without the `AXFullScreen` attribute at all (it can't go fullscreen) answers nil
/// for it while its `AXMinimized` read succeeds — that is "not fullscreen", not "unknown". Only when
/// NEITHER attribute could be read (the app didn't answer) is the state unknown.
func macosNativeState(fullscreen: Bool?, minimized: Bool?) -> MacosNativeWindowState? {
    if fullscreen == nil && minimized == nil { return nil }
    return MacosNativeWindowState(isFullscreen: fullscreen ?? false, isMinimized: minimized ?? false)
}

/// Tests: the state AeroSpace believes, as if read earlier (test doubles are never cached)
@MainActor
func seedMacosNativeWindowStateCacheForTests(windowId: UInt32, _ state: MacosNativeWindowState) {
    cache[windowId] = state
}

@MainActor
func resetMacosNativeWindowStateCacheForTests() { cache = [:] }
