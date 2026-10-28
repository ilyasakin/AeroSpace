import AppKit
import Common

struct WorkspaceBackAndForthCommand: Command {
    let args: WorkspaceBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // Was `focusWorkspace() != nil` on a Bool? — "succeeded" even when the switch was refused
        guard let prev = prevFocusedWorkspace else { return .fail(io.err("No previous workspace")) }
        return .from(bool: prev.focusWorkspace())
    }
}
