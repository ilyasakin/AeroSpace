import AppKit
import Common
import Foundation

struct WorkspaceCommand: Command {
    let args: WorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode { // todo refactor
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let focusedWs = target.workspace
        let workspaceName: String
        switch args.target.val {
            case .relative(let nextPrev):
                let workspace = getNextPrevWorkspace(
                    current: focusedWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                    allMonitors: args.allMonitors,
                )
                guard let workspace = workspace.getOrNil(appendErrorTo: &io.stderr) else { return .fail }
                workspaceName = workspace.name
            case .backAndForth:
                return WorkspaceBackAndForthCommand(args: WorkspaceBackAndForthCmdArgs(rawArgs: [])).run(env, io)
            case .direct(let name):
                workspaceName = args.number ? workspaceNamed(number: name.raw) : name.raw
                if workspaceName == scratchpadWorkspaceName {
                    return .fail(io.err("The scratchpad isn't a workspace you can show. Use 'scratchpad show'"))
                }
                if args._autoBackAndForth ?? config.workspaceAutoBackAndForth, focusedWs.name == workspaceName,
                   prevFocusedWorkspace != nil // nothing to go back to: i3 just stays
                {
                    return WorkspaceBackAndForthCommand(args: WorkspaceBackAndForthCmdArgs(rawArgs: [])).run(env, io)
                }
        }
        if focusedWs.name == workspaceName {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err("Workspace '\(workspaceName)' is already focused. Tip: use --fail-if-noop to exit with non-zero code"))
            }
        } else {
            return .from(bool: Workspace.get(byName: workspaceName).focusWorkspace())
        }
    }
}

/// i3 `workspace number N`: the first workspace whose name's leading number is N, else "N"
@MainActor func workspaceNamed(number raw: String) -> String {
    let digits = String(raw.prefix(while: \.isNumber))
    return Workspace.userFacing.first { String($0.name.prefix(while: \.isNumber)) == digits }?.name ?? raw
}

@MainActor func getNextPrevWorkspace(current: Workspace, isNext: Bool, wrapAround: Bool, stdin: String?, target: LiveFocus, allMonitors: Bool = false) -> ResOrStr<Workspace> {
    Result { () throws(String) in
        let stdinWorkspaces: [WorkspaceName] = try stdin?.split(whereSeparator: \.isWhitespace)
            .map { String($0).trim() }
            .filter { !$0.isEmpty }
            .mapAllOrFailure(WorkspaceName.parse)
            .get()
            ?? []
        let currentMonitor = current.workspaceMonitor
        let workspaces: [Workspace] = stdin != nil
            ? stdinWorkspaces.map { Workspace.get(byName: $0.raw) }
            : Workspace.userFacing.filter { allMonitors || $0.workspaceMonitor.displayId == currentMonitor.displayId }
                .toSet()
                .union([current])
                .sorted()
        if workspaces.isEmpty { throw "The list of workspaces is empty" }
        let index = workspaces.firstIndex(where: { $0 == target.workspace })
            .map { index in isNext ? index + 1 : index - 1 }
            ?? 0
        return wrapAround
            ? try workspaces.get(wrappingIndex: index).toResult("List of workspaces is empty").get()
            : try workspaces.getOrNil(atIndex: index)
                .toResult(
                    index >= workspaces.count
                        ? "Reached the end of the supplied workspaces list"
                        : "Rached the beginning of the supplied workspaces list",
                )
                .get()
    }
}
