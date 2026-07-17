import AppKit
import Common

struct StickyCommand: Command {
    let args: StickyCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        let newState = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isSticky
        }
        if newState == window.isSticky {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err((newState ? "Already sticky. " : "Already not sticky. ") +
                            "Tip: use --fail-if-noop to exit with non-zero exit code"))
            }
        }
        window.isSticky = newState
        if newState {
            if !window.isFloating {
                window.bindAsFloatingWindow(to: target.workspace)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
            }
            followActiveWorkspaceForStickyWindows()
        }
        return .succ
    }
}

/// Sticky windows follow the active workspace of their monitor: whenever the visible workspace
/// changes, they are re-bound into its floating container. Because they are always members of a
/// visible workspace, they are never parked in the hide corner - which is all it takes to be
/// "visible on every workspace" in AeroSpace's emulated-workspaces model (no SIP tricks needed,
/// unlike real macOS Spaces)
@MainActor func followActiveWorkspaceForStickyWindows() {
    for workspace in Workspace.allUnsorted {
        for window in workspace.allLeafWindowsRecursive where window.isSticky {
            guard let monitor = window.nodeMonitor else { continue }
            let activeWorkspace = monitor.activeWorkspace
            if workspace != activeWorkspace {
                window.bindAsFloatingWindow(to: activeWorkspace)
            }
        }
    }
}
