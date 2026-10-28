import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        FrameTrace.log("ns-notification \(notifName) pid=\(pid.map(String.init) ?? "nil")")
        Task.startUnstructured { @MainActor in
            if !ServerState.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                // App switch (cmd-tab, a cross-app `focus`, a click): an already known app whose
                // focused window we know only needs focus sync; discovery is for apps we haven't
                // registered yet (their first activation) or windows we haven't seen
                if let pid, let app = MacApp.allAppsMap[pid], app.knowsItsFocusedWindow {
                    guard let token: RunSessionGuard = .isServerEnabled else { return }
                    try? await runLightSession(.globalObserver(notifName), token) {}
                } else {
                    scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
                }
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       (w.app as? MacApp)?.nsApp.isHidden == true,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus without sinking workspace floats under a raised tile.
                        _ = w.focusWindow()
                        w.nativeFocusRespectingFloats()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        // Display reconfiguration (resolution/arrangement change) must drop the cached monitor list
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Kernel.submit("screen parameters changed", onScreenParametersChanged) }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        // Do NOT re-raise floats here. macOS raises the clicked tile; forcing floats
                        // back on top after every click steals key focus and blocks interacting with
                        // tiles (the old band-aid). Keyboard/FFM keep floats via focus-without-raise.
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}

/// Display reconfiguration (resolution / arrangement / Dock / menu-bar): moves the hide corners
/// and the visible areas. Nothing re-parked hidden windows (a window parked at the old corner could
/// end up mid-screen) and tiles didn't reflow until an unrelated event. A kernel job: it used to
/// run synchronously from the notification, landing in the middle of a suspended layout.
@MainActor func onScreenParametersChanged() {
    invalidateMonitorsCache()
    for window in Window.all { window.forgetHideCornerParking() }
    if ServerState.isEnabled {
        scheduleCancellableCompleteRefreshSession(.globalObserver(NSApplication.didChangeScreenParametersNotification.rawValue))
    }
}
