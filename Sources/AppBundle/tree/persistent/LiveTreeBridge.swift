import AppKit
import Common

// MARK: - Capture live → persistent

extension PersistentTilingNode {
    /// Capture a live tiling container (and descendants) into an immutable tree.
    @MainActor
    static func capture(_ container: TilingContainer) -> PersistentTilingNode {
        let weight = getWeightOrNil(container) ?? 1
        let children: [PersistentTilingNode] = container.children.map { child in
            switch child.nodeCases {
                case .window(let w):
                    .window(id: w.windowId, weight: getWeightOrNil(w) ?? 1)
                case .tilingContainer(let c):
                    capture(c)
                case .workspace,
                     .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: child, parent: container)
            }
        }
        return .container(
            orientation: container.orientation,
            layout: container.layout,
            weight: weight,
            children: children,
        )
    }
}

@MainActor
private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}

// MARK: - Restore persistent → live

extension PersistentTilingNode {
    /// Materialize this immutable tree under `parent`. Window leaves resolve via `Window.get(byId:)`.
    /// Returns false if a window id cannot be resolved (stops early so indices stay consistent).
    @MainActor
    @discardableResult
    func restore(parent: NonLeafTreeNodeObject, index: Int) -> Bool {
        switch self {
            case .window(let id, let weight):
                guard let window = Window.get(byId: id) else { return false }
                window.bind(to: parent, adaptiveWeight: weight, index: index)
                return true
            case .container(let orientation, let layout, let weight, let children):
                let container = TilingContainer(
                    parent: parent,
                    adaptiveWeight: weight,
                    orientation,
                    layout,
                    index: index,
                )
                for (i, child) in children.enumerated() {
                    if !child.restore(parent: container, index: i) { return false }
                }
                return true
        }
    }
}

// MARK: - Workspace / world capture

struct PersistentWorkspaceSnapshot: Equatable, Sendable {
    let name: String
    let monitorTopLeft: CGPoint
    let visibleWorkspaceName: String?
    let rootTiling: PersistentTilingNode
    let floatingWindowIds: [UInt32]
    let unconventionalWindowIds: [UInt32]
}

struct PersistentWorldSnapshot: Equatable, Sendable {
    let workspaces: [PersistentWorkspaceSnapshot]
    let monitorAssignments: [(topLeft: CGPoint, workspace: String)]
    let windowIds: Set<UInt32>

    static func == (lhs: PersistentWorldSnapshot, rhs: PersistentWorldSnapshot) -> Bool {
        lhs.workspaces == rhs.workspaces &&
            lhs.windowIds == rhs.windowIds &&
            lhs.monitorAssignments.count == rhs.monitorAssignments.count &&
            zip(lhs.monitorAssignments, rhs.monitorAssignments).allSatisfy {
                $0.topLeft == $1.topLeft && $0.workspace == $1.workspace
            }
    }
}

extension PersistentWorldSnapshot {
    /// Snapshot the live world into an immutable value (structural spine + window ids).
    @MainActor
    static func captureLive() -> PersistentWorldSnapshot {
        let allWs = Workspace.all
        let workspaces: [PersistentWorkspaceSnapshot] = allWs.map { ws in
            let floating = ws.floatingWindows.map(\.windowId)
            let unconventional =
                ws.macOsNativeHiddenAppsWindowsContainer.children.compactMap { ($0 as? Window)?.windowId } +
                ws.macOsNativeFullscreenWindowsContainer.children.compactMap { ($0 as? Window)?.windowId }
            return PersistentWorkspaceSnapshot(
                name: ws.name,
                monitorTopLeft: ws.workspaceMonitor.rect.topLeftCorner,
                visibleWorkspaceName: ws.isVisible ? ws.name : nil,
                rootTiling: PersistentTilingNode.capture(ws.rootTilingContainer),
                floatingWindowIds: floating,
                unconventionalWindowIds: unconventional,
            )
        }
        let assignments = monitors.map {
            (topLeft: $0.rect.topLeftCorner, workspace: $0.activeWorkspace.name)
        }
        let ids = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
        return PersistentWorldSnapshot(
            workspaces: workspaces,
            monitorAssignments: assignments,
            windowIds: ids,
        )
    }
}
