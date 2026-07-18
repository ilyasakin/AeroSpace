@testable import AppBundle
import Common
import XCTest

/// T2: Hyprland dispatcher names parse to the same CmdArgs as the mapped AeroSpace commands.
@MainActor
final class HyprlandDispatcherAliasesTest: XCTestCase {
    func testPureAliases() {
        assertHyprParsesLike("killactive", "close")
        assertHyprParsesLike("fullscreenstate", "fullscreen")
        assertHyprParsesLike("pin", "sticky")
        assertHyprParsesLike("centerwindow", "center-window")
    }

    func testDivergentNoArg() {
        assertHyprParsesLike("togglefloating", "layout floating tiling")
        assertHyprParsesLike("togglesplit", "split opposite")
        assertHyprParsesLike("cyclenext", "focus dfs-next")
    }

    func testDirections() {
        assertHyprParsesLike("movefocus l", "focus left")
        assertHyprParsesLike("movefocus r", "focus right")
        assertHyprParsesLike("movefocus u", "focus up")
        assertHyprParsesLike("movefocus d", "focus down")
        assertHyprParsesLike("movewindow l", "move left")
        assertHyprParsesLike("swapwindow r", "move right")
        assertHyprParsesLike("focusmonitor l", "focus-monitor left")
        assertHyprParsesLike("movecurrentworkspacetomonitor r", "move-workspace-to-monitor right")
    }

    func testResizeActive() {
        assertHyprParsesLike("resizeactive 50 0", "resize width +50")
        assertHyprParsesLike("resizeactive 0 -30", "resize height -30")
        assertHyprParsesLike("resizeactive -10 0", "resize width -10")
        // Both non-zero is not a single CLI command (binds expand via importer)
        assertNotNil(parseCommand("resizeactive 50 30").errorOrNil)
    }

    func testWorkspaceCanonicalGrammarUnchanged() {
        // Canonical `workspace` is AeroSpace-only: next/prev/name — not Hyprland e+1 / special / previous
        assertHyprParsesLike("workspace 1", "workspace 1")
        assertHyprParsesLike("workspace next", "workspace next")
        // Hyprland tokens must NOT steal workspace names (e.g. a workspace called "special")
        assertHyprParsesLike("workspace special", "workspace special")
        // e+1 / +1 are valid *names* under AeroSpace — stay as direct targets, not remapped to next
        assertHyprParsesLike("workspace e+1", "workspace e+1")
        assertHyprParsesLike("workspace +1", "workspace +1")
        // Reserved name still fails (not remapped to workspace-back-and-forth)
        assertNotNil(parseCommand("workspace previous").errorOrNil)
    }

    func testHyprlandWorkspaceDispatchersViaNonCollidingNames() {
        // Import rewrites bind lines; CLI uses togglespecialworkspace / aerospace names
        assertHyprParsesLike("togglespecialworkspace magic", "toggle-special-workspace magic")
        assertHyprParsesLike("togglespecialworkspace special:magic", "toggle-special-workspace magic")
        assertHyprParsesLike("togglespecialworkspace", "toggle-special-workspace special") // empty → special?
    }

    func testMoveToWorkspace() {
        // `movetoworkspace` is Hyprland-only (no AeroSpace name collision)
        assertHyprParsesLike("movetoworkspace 2", "move-node-to-workspace 2")
        assertHyprParsesLike("movetoworkspacesilent 3", "move-node-to-workspace 3")
        assertHyprParsesLike("movetoworkspace special:magic", "move-node-to-workspace magic")
        assertHyprParsesLike("movetoworkspace special", "move-node-to-workspace special")
    }

    func testSubmapAndExec() {
        assertHyprParsesLike("submap resize", "mode resize")
        assertHyprParsesLike("submap reset", "mode main")
        // exec is special-cased like exec-and-forget in the string path
        testParseSingleCommandSucc("exec kitty", ExecAndForgetCmdArgs(bashScript: " kitty"))
    }

    func testParseCmdArgsDirectly() {
        // Acceptance: parseCmdArgs on each alias/divergent name
        assertCmdArgsKind(["killactive"], .close)
        assertCmdArgsKind(["movefocus", "l"], .focus)
        assertCmdArgsKind(["movewindow", "r"], .move)
        assertCmdArgsKind(["resizeactive", "50", "0"], .resize)
        assertCmdArgsKind(["workspace", "1"], .workspace)
        assertCmdArgsKind(["togglespecialworkspace", "magic"], .toggleSpecialWorkspace)
        assertCmdArgsKind(["movetoworkspace", "1"], .moveNodeToWorkspace)
        assertCmdArgsKind(["cyclenext"], .focus)
        assertCmdArgsKind(["submap", "foo"], .mode)
        assertCmdArgsKind(["togglefloating"], .layout)
        assertCmdArgsKind(["togglesplit"], .split)
        assertCmdArgsKind(["exec", "echo", "hi"], .execAndForget)
    }
}

private func assertHyprParsesLike(_ hypr: String, _ aero: String, file: StaticString = #filePath, line: UInt = #line) {
    switch (parseCommand(hypr), parseCommand(aero)) {
        case (.cmd(.cmd(let h)), .cmd(.cmd(let a))):
            if !h.args.equals(a.args) {
                failExpectedActual(a.args, h.args, additionalMsg: "\(hypr) should match \(aero)", file: file, line: line)
            }
        case (.failure(let e), _):
            failExpectedActual("Parsed successfully", "Hypr failed: \(e.msg)", file: file, line: line)
        case (_, .failure(let e)):
            failExpectedActual("Aero parsed successfully", "Aero failed: \(e.msg)", file: file, line: line)
        default:
            failExpectedActual("Both single commands", "hypr=\(parseCommand(hypr)) aero=\(parseCommand(aero))", file: file, line: line)
    }
}

private func assertCmdArgsKind(_ args: [String], _ kind: CmdKind, file: StaticString = #filePath, line: UInt = #line) {
    switch parseCmdArgs(args.slice) {
        case .cmd(let cmd):
            assertEquals(cmd.kind, kind, file: file, line: line)
        case .failure(let e):
            failExpectedActual("Parsed \(args.joined(separator: " "))", "Failed: \(e.msg)", file: file, line: line)
        case .help:
            failExpectedActual("Parsed as command", "Parsed as help", file: file, line: line)
    }
}
