import AppKit
import Common

/// PaperWM/Rift-style recovery: put floating windows back above the tiling stack.
///
/// i3 keeps floats on a permanent upper layer. On macOS without SIP we cannot set window
/// levels for other apps, so we avoid raising tiles when floats exist and offer this
/// explicit command when the stack has drifted (app activation, Mission Control, etc.).
struct RaiseFloatingCommand: Command {
    let args: RaiseFloatingCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let before = countVisibleFloatingWindows()
        if before == 0 {
            return .succ(io.err("No floating windows on visible workspaces"))
        }
        // Explicit user recovery only — not automatic after click/focus.
        raiseFloatingWindowsAboveTiling(preserveTileKeyboardFocus: true)
        return .succ
    }
}

@MainActor
private func countVisibleFloatingWindows() -> Int {
    var count = 0
    for workspace in Workspace.allUnsorted where workspace.isVisible {
        count += workspace.floatingWindowsContainer.mruChildren.compactMap { $0 as? Window }.count
    }
    return count
}
