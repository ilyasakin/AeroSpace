import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let prevState = TrayMenuModel.shared.isEnabled
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !TrayMenuModel.shared.isEnabled
        }
        if newState == prevState {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already enabled. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already disabled. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }

        TrayMenuModel.shared.isEnabled = newState
        if newState {
            for workspace in Workspace.allUnsorted {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
                }
            }
            await activateMode_nonCancellable(mainModeId)
        } else {
            // Disabling stops layout; unpark any hide-in-corner windows so they are not left
            // as a 1px strip at the display edge while AeroSpace is "paused".
            restoreAllWindowsFromHideCornerForDisable()
            await activateMode_nonCancellable(nil)
        }
        return .succ
    }
}

/// Best-effort: put every managed window on-screen when tiling is turned off.
@MainActor
private func restoreAllWindowsFromHideCornerForDisable() {
    for window in MacWindow.allWindowsMap.values {
        window.unhideFromCorner()
        let axRect = window.macApp.getAxRectForTermination(window.windowId)
        let monitor = window.nodeMonitor
            ?? axRect.map { $0.center.monitorApproximation }
            ?? mainMonitor
        let visible = monitor.visibleRect
        // Prefer last laid-out size, then AX, then floating size.
        let preferred = window.lastAppliedLayoutPhysicalRect?.size
            ?? axRect?.size
            ?? window.lastFloatingSize
        let size = terminationRestoreSize(preferred: preferred, visibleRect: visible)
        let point = centeredTopLeft(windowSize: size, in: visible)
        window.macApp.setAxFrameForTermination(window.windowId, point, size)
    }
}
