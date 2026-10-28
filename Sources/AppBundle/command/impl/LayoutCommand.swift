import AppKit
import Common

struct LayoutCommand: Command {
    let args: LayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let node: ConventionalWindowParentCases
        switch args.root ? nil : target.windowOrNil {
            // `focus parent`: i3 changes the layout of the focused container itself
            case let window? where window == focus.windowOrNil && focus.focusedNode is TilingContainer:
                node = .tilingContainer(focus.focusedNode as! TilingContainer)
            case let window?:
                switch window.windowParentCases {
                    case .floatingWindowsContainer(let it):
                        node = .floatingWindowsContainer(it)
                    case .tilingContainer(let it):
                        node = .tilingContainer(it)
                    case .macosFullscreenWindowsContainer,
                         .macosHiddenAppsWindowsContainer,
                         .macosMinimizedWindowsContainer:
                        let msg = "Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. " +
                            "This behavior is subject to change"
                        return .fail(io.err(msg))
                    case .unbound, .macosPopupWindowsContainer:
                        return .fail(io.err(bugPrompt()))
                }
            case nil:
                node = .tilingContainer(target.workspace.rootTilingContainer)
        }

        let targetDescription = nextLayoutInToggleList(args.toggleBetween.val) { node.matchesDescription($0) }
        if node.matchesDescription(targetDescription) {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = "Already in the requested \(targetDescription.rawValue) mode. " +
                        "Tip: use --fail-if-noop to exit with non-zero exit code"
                    return .succ(io.err(msg))
            }
        }
        switch targetDescription {
            case .h_accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: .h, node: node)
            case .v_accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: .v, node: node)
            case .h_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .h, node: node)
            case .v_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .v, node: node)
            case .h_master:
                return changeTilingLayout(io, targetLayout: .master, targetOrientation: .h, node: node)
            case .v_master:
                return changeTilingLayout(io, targetLayout: .master, targetOrientation: .v, node: node)
            case .accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: nil, node: node)
            case .tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: nil, node: node)
            case .master:
                return changeTilingLayout(io, targetLayout: .master, targetOrientation: nil, node: node)
            case .horizontal:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .h, node: node)
            case .vertical:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .v, node: node)
            case .tiling:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                switch node {
                    case .tilingContainer:
                        return .succ // Nothing to do
                    case .floatingWindowsContainer(let container):
                        window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
                        guard let workspace = container.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
                        window.isScratchpadWindow = false // i3: tiling a scratchpad window takes it out
                        // Exact spine → original neighbour slot → i3 floating_disable (see restoreTile)
                        if workspace.restoreTile(window) {
                            return .succ
                        }
                        do {
                            try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
                        } catch {
                            return .fail(io.err(bugPrompt()))
                        }
                        return .succ
                }
            case .floating:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                let workspace = target.workspace
                // Capture tiling slot + exact spine *before* unbind so unfloat can restore.
                if !window.isFloating {
                    // A fullscreen tile leaves fullscreen first (its floating frame is unknown)
                    window.exitFullscreen()
                    workspace.captureTileRestorePoint(for: window)
                }
                // Keep belief at the current tile frame so a following resize/center in the
                // same session can merge size+position (see MacWindow.setAxFrame / mergeFrameWrite).
                // Do *not* force always-on-top: that re-raises on every focus change and blocks
                // interacting with other tiles (i3 float is a layer, not always-on-top).
                window.bindAsFloatingWindow(to: workspace)
                // User explicitly floated this — the i3 float quirks (click-without-raise, settle)
                // apply only to windows marked here, not to auto-classified dialogs/popups.
                workspace.settleTileRestorePoint(for: window)
                if let size = window.lastFloatingSize {
                    window.requestFrame(topLeft: nil, size: size)
                }
                // Place the new float above the tiling stack once (i3: floats start on top).
                return .succ
        }
    }
}

@MainActor private func changeTilingLayout(
    _ io: CmdIo,
    targetLayout: Layout?,
    targetOrientation: Orientation?,
    node: ConventionalWindowParentCases,
) -> BinaryExitCode {
    switch node {
        case .floatingWindowsContainer:
            return .fail(io.err("The window is non-tiling"))
        case .tilingContainer(let parent):
            let targetOrientation = targetOrientation ?? parent.orientation
            let targetLayout = targetLayout ?? parent.layout
            parent.setLayout(targetLayout)
            parent.changeOrientation(targetOrientation)
            return .succ
    }
}

extension ConventionalWindowParentCases {
    fileprivate func matchesDescription(_ layout: LayoutCmdArgs.LayoutDescription) -> Bool {
        return switch layout {
            case .accordion:   tilingContainerOrNil?.layout == .accordion
            case .tiles:       tilingContainerOrNil?.layout == .tiles
            case .master:      tilingContainerOrNil?.layout == .master
            case .horizontal:  tilingContainerOrNil?.orientation == .h
            case .vertical:    tilingContainerOrNil?.orientation == .v
            case .h_accordion: tilingContainerOrNil.map { $0.layout == .accordion && $0.orientation == .h } == true
            case .v_accordion: tilingContainerOrNil.map { $0.layout == .accordion && $0.orientation == .v } == true
            case .h_tiles:     tilingContainerOrNil.map { $0.layout == .tiles && $0.orientation == .h } == true
            case .v_tiles:     tilingContainerOrNil.map { $0.layout == .tiles && $0.orientation == .v } == true
            case .h_master:    tilingContainerOrNil.map { $0.layout == .master && $0.orientation == .h } == true
            case .v_master:    tilingContainerOrNil.map { $0.layout == .master && $0.orientation == .v } == true
            case .tiling:      tilingContainerOrNil != nil
            case .floating:    floatingWindowsContainerOrNil != nil
        }
    }
}

/// i3 `layout toggle <list>` (commands.c): the entry AFTER the one matching the current layout,
/// wrapping; the first entry when none matches. (Was: the first entry that doesn't match, which
/// only cycles lists of two — `layout h_tiles v_tiles h_accordion` never reached the third.)
/// A single-entry list is "set", not toggle.
func nextLayoutInToggleList(
    _ list: [LayoutCmdArgs.LayoutDescription],
    matchesCurrent: (LayoutCmdArgs.LayoutDescription) -> Bool,
) -> LayoutCmdArgs.LayoutDescription {
    guard list.count > 1, let current = list.firstIndex(where: matchesCurrent) else { return list.first.orDie() }
    return list[(current + 1) % list.count]
}
