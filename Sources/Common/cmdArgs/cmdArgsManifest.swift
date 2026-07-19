public enum CmdKind: String, CaseIterable, Equatable, Sendable {
    /// Commands that only read/report state. Light sessions for these skip layout and the
    /// post-command complete refresh (window discovery / normalize), which dominated cost for
    /// polling scripts (sketchybar, etc.)
    public var isQueryOnly: Bool {
        switch self {
            case .listApps, .listExecEnvVars, .listModes, .listMonitors, .listWindows, .listWorkspaces,
                 .echo, ._true, ._false, .test, .testNot:
                true
            default:
                false
        }
    }

    // Sorted

    case alwaysOnTop = "always-on-top"
    case balanceSizes = "balance-sizes"
    case centerWindow = "center-window"
    case close
    case closeAllWindowsButCurrent = "close-all-windows-but-current"
    case config
    case debugWindows = "debug-windows"
    case echo
    case enable
    case eval
    case execAndForget = "exec-and-forget"

    case _false = "false"

    case flattenWorkspaceTree = "flatten-workspace-tree"
    case focus
    case focusBackAndForth = "focus-back-and-forth"
    case focusMonitor = "focus-monitor"
    case fullscreen
    case importConfig = "import-config"
    case joinWith = "join-with"
    case layout
    case listApps = "list-apps"
    case listExecEnvVars = "list-exec-env-vars"
    case listModes = "list-modes"
    case listMonitors = "list-monitors"
    case listWindows = "list-windows"
    case listWorkspaces = "list-workspaces"
    case macosNativeFullscreen = "macos-native-fullscreen"
    case macosNativeMinimize = "macos-native-minimize"
    case mode
    case move = "move"
    case moveMouse = "move-mouse"
    case moveNodeToMonitor = "move-node-to-monitor"
    case moveNodeToWorkspace = "move-node-to-workspace"
    case moveTo = "move-to"
    case moveWorkspaceToMonitor = "move-workspace-to-monitor"
    case raiseFloating = "raise-floating"
    case reloadConfig = "reload-config"
    case resize
    case resizeTo = "resize-to"
    case runCallback = "run-callback"
    case split
    case sticky
    case subscribe
    case summonWorkspace = "summon-workspace"
    case swap
    case test
    case testNot = "test-not"
    case tilingPolicy = "tiling-policy"
    case toggleGroup = "toggle-group"
    case toggleSpecialWorkspace = "toggle-special-workspace"
    case triggerBinding = "trigger-binding"

    case _true = "true"

    case volume
    case workspace
    case workspaceBackAndForth = "workspace-back-and-forth"
}

func initSubcommands() -> [String: any SubCommandParserProtocol] {
    var result: [String: any SubCommandParserProtocol] = [:]
    for kind in CmdKind.allCases {
        switch kind {
            case .alwaysOnTop:
                result[kind.rawValue] = SubCommandParser(parseAlwaysOnTopCmdArgs)
            case .balanceSizes:
                result[kind.rawValue] = SubCommandParser(BalanceSizesCmdArgs.init)
            case .centerWindow:
                result[kind.rawValue] = SubCommandParser(CenterWindowCmdArgs.init)
            case .close:
                result[kind.rawValue] = SubCommandParser(CloseCmdArgs.init)
            case .closeAllWindowsButCurrent:
                result[kind.rawValue] = SubCommandParser(CloseAllWindowsButCurrentCmdArgs.init)
            case .config:
                result[kind.rawValue] = SubCommandParser(parseConfigCmdArgs)
            case .debugWindows:
                result[kind.rawValue] = SubCommandParser(DebugWindowsCmdArgs.init)
            case .echo:
                result[kind.rawValue] = SubCommandParser(EchoCmdArgs.init)
            case .enable:
                result[kind.rawValue] = SubCommandParser(parseEnableCmdArgs)
            case .eval:
                result[kind.rawValue] = SubCommandParser(EvalCmdArgs.init)
            case .execAndForget:
                break // exec-and-forget is parsed separately
            case ._false:
                result[kind.rawValue] = SubCommandParser(FalseCmdArgs.init)
            case .flattenWorkspaceTree:
                result[kind.rawValue] = SubCommandParser(FlattenWorkspaceTreeCmdArgs.init)
            case .focus:
                result[kind.rawValue] = SubCommandParser(parseFocusCmdArgs)
            case .focusBackAndForth:
                result[kind.rawValue] = SubCommandParser(FocusBackAndForthCmdArgs.init)
            case .focusMonitor:
                result[kind.rawValue] = SubCommandParser(parseFocusMonitorCmdArgs)
            case .fullscreen:
                result[kind.rawValue] = SubCommandParser(parseFullscreenCmdArgs)
            case .importConfig:
                result[kind.rawValue] = SubCommandParser(parseImportConfigCmdArgs)
            case .joinWith:
                result[kind.rawValue] = SubCommandParser(JoinWithCmdArgs.init)
            case .layout:
                result[kind.rawValue] = SubCommandParser(parseLayoutCmdArgs)
            case .listApps:
                result[kind.rawValue] = SubCommandParser(parseListAppsCmdArgs)
            case .listExecEnvVars:
                result[kind.rawValue] = SubCommandParser(ListExecEnvVarsCmdArgs.init)
            case .listModes:
                result[kind.rawValue] = SubCommandParser(parseListModesCmdArgs)
            case .listMonitors:
                result[kind.rawValue] = SubCommandParser(parseListMonitorsCmdArgs)
            case .listWindows:
                result[kind.rawValue] = SubCommandParser(parseListWindowsCmdArgs)
            case .listWorkspaces:
                result[kind.rawValue] = SubCommandParser(parseListWorkspacesCmdArgs)
            case .macosNativeFullscreen:
                result[kind.rawValue] = SubCommandParser(parseMacosNativeFullscreenCmdArgs)
            case .macosNativeMinimize:
                result[kind.rawValue] = SubCommandParser(MacosNativeMinimizeCmdArgs.init)
            case .mode:
                result[kind.rawValue] = SubCommandParser(ModeCmdArgs.init)
            case .move:
                result[kind.rawValue] = SubCommandParser(parseMoveCmdArgs)
                // deprecated
                result["move-through"] = SubCommandParser(parseMoveCmdArgs)
            case .moveMouse:
                result[kind.rawValue] = SubCommandParser(parseMoveMouseCmdArgs)
            case .moveNodeToMonitor:
                result[kind.rawValue] = SubCommandParser(parseMoveNodeToMonitorCmdArgs)
            case .moveNodeToWorkspace:
                result[kind.rawValue] = SubCommandParser(parseMoveNodeToWorkspaceCmdArgs)
            case .moveTo:
                result[kind.rawValue] = SubCommandParser(parseMoveToCmdArgs)
            case .moveWorkspaceToMonitor:
                result[kind.rawValue] = SubCommandParser(parseWorkspaceToMonitorCmdArgs)
                // deprecated
                result["move-workspace-to-display"] = SubCommandParser(MoveWorkspaceToMonitorCmdArgs.init)
            case .raiseFloating:
                result[kind.rawValue] = SubCommandParser(RaiseFloatingCmdArgs.init)
            case .reloadConfig:
                result[kind.rawValue] = SubCommandParser(ReloadConfigCmdArgs.init)
            case .resize:
                result[kind.rawValue] = SubCommandParser(parseResizeCmdArgs)
            case .resizeTo:
                result[kind.rawValue] = SubCommandParser(parseResizeToCmdArgs)
            case .runCallback:
                result[kind.rawValue] = SubCommandParser(parseRunCallbackCmdArgs)
            case .split:
                result[kind.rawValue] = SubCommandParser(parseSplitCmdArgs)
            case .sticky:
                result[kind.rawValue] = SubCommandParser(parseStickyCmdArgs)
            case .subscribe:
                result[kind.rawValue] = SubCommandParser(parseSubscribeCmdArgs)
            case .summonWorkspace:
                result[kind.rawValue] = SubCommandParser(SummonWorkspaceCmdArgs.init)
            case .swap:
                result[kind.rawValue] = SubCommandParser(parseSwapCmdArgs)
            case .test:
                result[kind.rawValue] = SubCommandParser(parseTestCmdArgs)
            case .testNot:
                result[kind.rawValue] = SubCommandParser(parseTestNotCmdArgs)
            case .tilingPolicy:
                result[kind.rawValue] = SubCommandParser(parseTilingPolicyCmdArgs)
            case .toggleGroup:
                result[kind.rawValue] = SubCommandParser(ToggleGroupCmdArgs.init)
            case .toggleSpecialWorkspace:
                result[kind.rawValue] = SubCommandParser(ToggleSpecialWorkspaceCmdArgs.init)
            case .triggerBinding:
                result[kind.rawValue] = SubCommandParser(parseTriggerBindingCmdArgs)
            case ._true:
                result[kind.rawValue] = SubCommandParser(TrueCmdArgs.init)
            case .volume:
                result[kind.rawValue] = SubCommandParser(VolumeCmdArgs.init)
            case .workspace:
                // Canonical AeroSpace grammar only. Hyprland forms (e+1, previous, special:*)
                // are rewritten at import time and via togglespecialworkspace / movetoworkspace
                // aliases — do not widen `workspace` itself (would steal names like "special").
                result[kind.rawValue] = SubCommandParser(parseWorkspaceCmdArgs)
            case .workspaceBackAndForth:
                result[kind.rawValue] = SubCommandParser(WorkspaceBackAndForthCmdArgs.init)
        }
    }

    // Hyprland dispatcher-name aliases (M1). No new CmdKind — pure aliases or small rewrites.
    // Pure aliases (identical arg grammar)
    result["killactive"] = SubCommandParser(CloseCmdArgs.init)
    result["fullscreenstate"] = SubCommandParser(parseFullscreenCmdArgs)
    result["pin"] = SubCommandParser(parseStickyCmdArgs)
    result["centerwindow"] = SubCommandParser(CenterWindowCmdArgs.init)

    // Grammar-divergent (normalize Hypr args into existing CmdArgs)
    result["togglefloating"] = SubCommandParser(parseHyprlandToggleFloatingCmdArgs)
    result["togglesplit"] = SubCommandParser(parseHyprlandToggleSplitCmdArgs)
    result["movefocus"] = SubCommandParser(parseHyprlandMoveFocusCmdArgs)
    result["movewindow"] = SubCommandParser(parseHyprlandMoveWindowCmdArgs)
    result["swapwindow"] = SubCommandParser(parseHyprlandMoveWindowCmdArgs) // same as movewindow per importer
    result["focusmonitor"] = SubCommandParser(parseHyprlandFocusMonitorCmdArgs)
    result["movecurrentworkspacetomonitor"] = SubCommandParser(parseHyprlandMoveCurrentWorkspaceToMonitorCmdArgs)
    result["resizeactive"] = SubCommandParser(parseHyprlandResizeActiveCmdArgs)
    result["movetoworkspace"] = SubCommandParser(parseHyprlandMoveToWorkspaceCmdArgs)
    result["movetoworkspacesilent"] = SubCommandParser(parseHyprlandMoveToWorkspaceCmdArgs)
    result["cyclenext"] = SubCommandParser(parseHyprlandCycleNextCmdArgs)
    result["submap"] = SubCommandParser(parseHyprlandSubmapCmdArgs)
    result["exec"] = SubCommandParser(parseHyprlandExecCmdArgs)
    // Hyprland group / special workspace (M2)
    result["togglegroup"] = SubCommandParser(ToggleGroupCmdArgs.init)
    result["changegroupactive"] = SubCommandParser(parseHyprlandCycleNextCmdArgs) // cycle front of accordion
    result["togglespecialworkspace"] = SubCommandParser(parseHyprlandToggleSpecialWorkspaceCmdArgs)

    // M5 hyprctl-style query aliases
    result["clients"] = SubCommandParser(parseClientsCmdArgs)
    result["workspaces"] = SubCommandParser(parseWorkspacesAliasCmdArgs)
    result["monitors"] = SubCommandParser(parseMonitorsAliasCmdArgs)
    result["activewindow"] = SubCommandParser(parseActiveWindowCmdArgs)
    result["binds"] = SubCommandParser(parseListModesCmdArgs)

    return result
}
