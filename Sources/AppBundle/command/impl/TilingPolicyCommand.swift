import Common

struct TilingPolicyCommand: Command {
    let args: TilingPolicyCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        switch args.target.val {
            case .manual: workspace.tilingPolicyOverride = .manual
            case .dwindle: workspace.tilingPolicyOverride = .dwindle
            case .default: workspace.tilingPolicyOverride = nil
        }
        return .succ
    }
}
