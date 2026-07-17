import AppKit
import Common

struct AlwaysOnTopCommand: Command {
    let args: AlwaysOnTopCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        let newState = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isAlwaysOnTop
        }
        if newState == window.isAlwaysOnTop {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err((newState ? "Already always-on-top. " : "Already not always-on-top. ") +
                            "Tip: use --fail-if-noop to exit with non-zero exit code"))
            }
        }
        window.isAlwaysOnTop = newState
        if newState {
            if !window.isFloating {
                window.bindAsFloatingWindow(to: target.workspace)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
            }
            window.nativeRaise()
        }
        return .succ
    }
}

/// Always-on-top is emulated: there is no public macOS API to change another app's window level
/// (yabai does it via a SIP-off scripting addition). Instead, marked windows are re-raised
/// whenever the focus changes
@MainActor func raiseAlwaysOnTopWindows() {
    let focusedWindowId = focus.windowOrNil?.windowId
    for workspace in Workspace.all where workspace.isVisible {
        // allLeafWindowsRecursive rather than the floatingWindows accessor: the latter lazily
        // materializes an empty floatingWindowsContainer in every visible workspace
        for window in workspace.allLeafWindowsRecursive where window.isAlwaysOnTop && window.windowId != focusedWindowId {
            window.nativeRaise()
        }
    }
}
