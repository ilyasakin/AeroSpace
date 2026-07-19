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
    for workspace in Workspace.allUnsorted where workspace.isVisible {
        // allLeafWindowsRecursive rather than the floatingWindows accessor: the latter lazily
        // materializes an empty floatingWindowsContainer in every visible workspace
        for window in workspace.allLeafWindowsRecursive where window.isAlwaysOnTop && window.windowId != focusedWindowId {
            window.nativeRaise()
        }
    }
}

/// Raise floating windows above the tiling stack (MRU last among floats).
///
/// Recovery only — not on every focus change. Primary path is private focus-without-raise
/// (`FloatLayer` / `nativeFocusRespectingFloats`) so tiles never sink floats. Call from
/// `raise-floating` when the stack has drifted.
///
/// - Parameter preserveTileKeyboardFocus: after raising floats, re-assert keyboard focus on
///   the focused tile without raising it (i3: float stays on top, tile may stay key).
@MainActor func raiseFloatingWindowsAboveTiling(preserveTileKeyboardFocus: Bool = true) {
    let focused = focus.windowOrNil
    var raisedAny = false
    for workspace in Workspace.allUnsorted where workspace.isVisible {
        let floats = workspace.floatingWindowsContainer.mruChildren.compactMap { $0 as? Window }
        guard !floats.isEmpty else { continue }
        // Oldest first → newest last (top of stack among floats)
        for window in floats.reversed() {
            window.nativeRaise()
            raisedAny = true
        }
    }
    if preserveTileKeyboardFocus, raisedAny, let focused, !focused.isFloating {
        FloatLayer.focus(focused, raise: false)
    }
}
