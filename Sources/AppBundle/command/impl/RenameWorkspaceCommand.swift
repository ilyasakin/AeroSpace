import AppKit
import Common

struct RenameWorkspaceCommand: Command {
    let args: RenameWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let newName = args.newName.val.raw
        if target.workspace.isScratchpad { return .fail(io.err("The scratchpad can't be renamed")) }
        return target.workspace.rename(to: newName)
            ? .succ
            : .fail(io.err("Workspace '\(newName)' already exists"))
    }
}
