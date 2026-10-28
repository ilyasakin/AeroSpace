import AppKit
import Common

struct EnableCommand: Command {
    let args: EnableCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let prevState = ServerState.isEnabled
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !ServerState.isEnabled
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

        ServerState.isEnabled = newState
        if newState {
            for workspace in Workspace.allUnsorted {
                for window in workspace.allLeafWindowsRecursive where window.isFloating {
                    window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
                }
            }
            await activateMode_nonCancellable(mainModeId)
        } else {
            // Hotkeys go first: nothing may run a session against a server that is shutting off
            await activateMode_nonCancellable(nil)
            // Disabling stops layout; unpark any hide-in-corner windows so they are not left
            // as a 1px strip at the display edge while AeroSpace is "paused".
            await restoreAllWindowsFromHideCornerForDisable()
        }
        return .succ
    }
}

/// Best-effort: put every managed window on-screen when tiling is turned off.
///
/// Deliberately does NOT use the `*ForTermination` AX helpers. Those block the main thread on a
/// semaphore per window with no timeout, which is a tolerable trade only on the quit path where the
/// process is going away anyway. `enable off` is a normal runtime command, so a single unresponsive
/// app (beachballed Electron, an app mid-crash) would have frozen the whole WM indefinitely.
/// The async read + fire-and-forget write below cannot stall the main thread.
@MainActor
private func restoreAllWindowsFromHideCornerForDisable() async {
    for window in Window.all {
        window.unhideFromCorner()
        let axRect = try? await window.getAxRect(.nonCancellable)
        let monitor = window.nodeMonitor
            ?? axRect.map { $0.center.monitorApproximation }
            ?? mainMonitor
        let visible = monitor.visibleRect
        // Prefer last laid-out size, then AX, then floating size.
        let preferred = window.knownFrame?.size
            ?? axRect?.size
            ?? window.lastFloatingSize
        let size = terminationRestoreSize(preferred: preferred, visibleRect: visible)
        let point = centeredTopLeft(windowSize: size, in: visible)
        window.setAxFrame(point, size)
    }
}
