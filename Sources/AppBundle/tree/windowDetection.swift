import AppKit
import Common

/// Where a (re-)registered window goes, and the `on-window-detected` / title-rule callbacks.
/// Model logic; the window's type comes from the macOS port.
extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        if forceTile {
            // Path-copy place into tiling spine (unbind via materialize)
            bindAsFloatingWindow(to: workspace)
            _ = workspace.commitTilingPlaceNewWindow(id: windowId)
            return
        }
        let windowLevel = getWindowLevel(for: windowId)
        let windowType = try await MacOS.current.windowType(windowId, level: windowLevel, cm)
        switch windowType {
            case .popup:
                bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .dialog:
                bindAsFloatingWindow(to: workspace)
            case .window:
                bindAsFloatingWindow(to: workspace)
                _ = workspace.commitTilingPlaceNewWindow(id: windowId)
        }
    }
}

@MainActor
func tryOnWindowDetected(_ window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        window.ranDetectionCallbacks.append(callback)
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

/// i3 re-runs `for_window` rules that did not match when a window's title changes (window.c):
/// browsers and terminals set the real title only after the window appears. A rule never runs
/// twice for one window.
@MainActor
func onWindowTitleChanged(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async {
    for callback in config.onWindowDetected
        where callback.dependsOnWindowTitle && !window.ranDetectionCallbacks.contains(callback)
    {
        guard await callback.matches(window) else { continue }
        window.ranDetectionCallbacks.append(callback)
        _ = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks { return }
    }
}

extension Window {
    /// Is there any title-based `on-window-detected` rule that hasn't run for this window yet?
    @MainActor var hasPendingTitleRules: Bool {
        config.onWindowDetected.contains { $0.dependsOnWindowTitle && !ranDetectionCallbacks.contains($0) }
    }
}

extension WindowDetectedCallback {
    var dependsOnWindowTitle: Bool {
        switch matcher {
            case .legacy(let m): m.windowTitleRegexSubstring != nil
            case .command: false
        }
    }

    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                // Cheap in-process checks first. The window-title check needs an AX round-trip
                // (getTitle), so it must run LAST — after appId/appName/workspace can reject
                if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
                    return false
                }
                if let appId = matcher.appId, appId != window.app.rawAppBundleId {
                    return false
                }
                if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
                    return false
                }
                if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
                    return false
                }
                if let regex = matcher.windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
                    return false
                }
                return true
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}

