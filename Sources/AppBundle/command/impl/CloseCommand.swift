import AppKit
import Common

struct CloseCommand: Command {
    let args: CloseCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err("Empty workspace"))
        }
        // i3 `kill` on a focused container (`focus parent`) closes every window in it
        if window == focus.windowOrNil, let container = focus.focusedNode as? TilingContainer {
            for w in container.allLeafWindowsRecursive { w.closeAxWindow() }
            return .succ
        }
        if await args.quitIfLastWindow.andAsync({ @MainActor @Sendable in await MacOS.current.windowCountOfApp(ofWindow: window.windowId) == 1 }) {
            let pid = window.app.pid
            if MacOS.current.quitApp(ofWindow: window.windowId) {
                for workspace in Workspace.allUnsorted {
                    for window in workspace.allLeafWindowsRecursive where window.app.pid == pid {
                        window.garbageCollect(skipClosedWindowsCache: true)
                    }
                }
                return .succ
            } else {
                return .fail(io.err("Failed to quit '\(window.app.name ?? "Unknown app")'"))
            }
        } else {
            window.closeAxWindow()
            return .succ
        }
    }
}
