import AppKit
import Common

/// i3's hidden `__i3_scratch` workspace. It is never shown on a monitor (its windows are parked in
/// the hide corner like any invisible workspace's), never listed, never cycled to.
let scratchpadWorkspaceName = "__i3_scratch"

@MainActor var scratchpadWorkspace: Workspace { Workspace.get(byName: scratchpadWorkspaceName) }

/// i3 scratchpad (src/scratchpad.c):
/// - `scratchpad move`: the window becomes floating and goes to the scratchpad.
/// - `scratchpad show`: the focused scratchpad window is hidden again; otherwise a scratchpad
///   window already visible on this workspace is focused; otherwise the most recently used hidden
///   scratchpad window is shown floating on the focused workspace (centred the first time).
///   Targeted (`--window-id`, criteria): toggles that window.
struct ScratchpadCommand: Command {
    let args: ScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        switch args.action.val {
            case .move:
                guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
                // The focused container's windows all go (i3 moves the container)
                let windows: [Window] = if let w = target.windowOrNil, w == focus.windowOrNil,
                                            let container = focus.focusedNode as? TilingContainer
                {
                    container.allLeafWindowsRecursive
                } else {
                    target.windowOrNil.map { [$0] } ?? []
                }
                if windows.isEmpty { return .fail(io.err(noWindowIsFocused)) }
                let workspace = target.workspace
                for w in windows { moveToScratchpad(w) }
                return .from(bool: workspace.focusWorkspace())
            case .show:
                let explicit = args.windowId != nil || env.windowId != nil
                if explicit {
                    guard let target = args.resolveTargetOrReportError(env, io), let w = target.windowOrNil else { return .fail }
                    guard w.isScratchpadWindow else { return .fail(io.err("Window \(w.windowId) is not a scratchpad window")) }
                    return toggle(w)
                }
                let ws = focus.workspace
                if let focused = focus.windowOrNil, focused.isScratchpadWindow, focused.nodeWorkspace === ws {
                    moveToScratchpad(focused)
                    return .from(bool: ws.focusWorkspace())
                }
                if let visible = ws.floatingWindows.first(where: \.isScratchpadWindow) {
                    return .from(bool: visible.focusWindow())
                }
                // i3: a scratchpad window showing on ANOTHER visible workspace is pulled over
                if let elsewhere = Workspace.allUnsorted.lazy
                    .filter({ $0 !== ws && $0.isVisible })
                    .flatMap(\.floatingWindows).first(where: \.isScratchpadWindow)
                {
                    return show(elsewhere, on: ws)
                }
                guard let next = scratchpadWorkspace.floatingWindowsContainer.mostRecentWindowRecursive else {
                    return .fail(io.err("The scratchpad is empty"))
                }
                return show(next, on: ws)
        }
    }

    @MainActor private func toggle(_ w: Window) -> BinaryExitCode {
        let ws = focus.workspace
        if w.nodeWorkspace === ws, w == focus.windowOrNil {
            moveToScratchpad(w)
            return .from(bool: ws.focusWorkspace())
        }
        return show(w, on: ws)
    }

    @MainActor private func show(_ w: Window, on ws: Workspace) -> BinaryExitCode {
        w.bindAsFloatingWindow(to: ws)
        if !w.scratchpadWasShown {
            // i3 centres a scratchpad window on its first show
            w.scratchpadWasShown = true
            let size = w.lastFloatingSize ?? CGSize(width: ws.workspaceMonitor.visibleRect.width / 2, height: ws.workspaceMonitor.visibleRect.height / 2)
            let area = ws.workspaceMonitor.visibleRect
            w.requestFrame(topLeft: CGPoint(x: area.topLeftX + (area.width - size.width) / 2, y: area.topLeftY + (area.height - size.height) / 2), size: size)
        }
        return .from(bool: w.focusWindow())
    }
}

@MainActor
func moveToScratchpad(_ w: Window) {
    w.isScratchpadWindow = true
    w.isSticky = false
    if w.isFullscreen { w.exitFullscreen() }
    w.bindAsFloatingWindow(to: scratchpadWorkspace)
}
