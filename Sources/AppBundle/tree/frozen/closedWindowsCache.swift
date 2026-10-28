import AppKit
import Common

// The frozen world (see `WindowMemory.freezeWorldIfNeeded`): the first line of defence against
// the lock screen, where AX goes blank and every window looks closed.

struct FrozenMonitor: Sendable {
    /// Identity, not geometry. Keyed on the top-left corner this could not tell two monitors apart
    /// when their corners collided, and `singleOrNil()` below then silently declined to restore.
    let displayId: DisplayId
    let visibleWorkspace: String

    @MainActor init(_ monitor: Monitor) {
        displayId = monitor.displayId
        visibleWorkspace = monitor.activeWorkspace.name
    }
}

struct FrozenWorkspace: Sendable {
    let name: String
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        monitor = FrozenMonitor(workspace.workspaceMonitor)
        rootTilingNode = FrozenContainer(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            workspace.macOsNativeHiddenAppsWindowsContainer.children.map { FrozenWindow($0 as! Window) } +
            workspace.macOsNativeFullscreenWindowsContainer.children.map { FrozenWindow($0 as! Window) }
    }
}

/// Put every workspace and monitor back the way `world` froze them
@MainActor func restoreFrozenWorld(_ world: FrozenWorld) async throws {
    let monitors = monitors
    let monitorById = Dictionary(monitors.map { ($0.displayId, $0) }, uniquingKeysWith: { first, _ in first })

    for frozenWorkspace in world.workspaces {
        let workspace = Workspace.get(byName: frozenWorkspace.name)
        _ = monitorById[frozenWorkspace.monitor.displayId]?
            .setActiveWorkspace(workspace)
        for frozenWindow in frozenWorkspace.floatingWindows {
            Window.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        for frozenWindow in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
            Window.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        restoreTreeRecursive(frozenContainer: frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST)
        for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
        }
    }

    for monitor in world.monitors {
        _ = monitorById[monitor.displayId]?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
}

@discardableResult
@MainActor
private func restoreTreeRecursive(frozenContainer: FrozenContainer, parent: NonLeafTreeNodeObject, index: Int) -> Bool {
    // Persistent spine materializes via path-copying model (#1215)
    frozenContainer.node.restore(parent: parent, index: index)
}
