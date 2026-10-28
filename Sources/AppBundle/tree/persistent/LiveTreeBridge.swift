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
            id: container.nodeId,
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
    ///
    /// Best-effort: an unresolvable window id (stale generation, closed window, foreign id) SKIPS
    /// that leaf and continues — a WM must degrade, not die, on model drift. Returns true when at
    /// least one leaf was bound (an all-dead spine returns false so callers can fall back).
    /// `reusing`: containers of the tree being replaced, by node id. A snapshot container with one
    /// of those ids gets that same object back (reshaped and refilled) rather than a new one.
    @MainActor
    @discardableResult
    func restore(parent: NonLeafTreeNodeObject, index: Int, reusing: [UInt64: TilingContainer] = [:]) -> Bool {
        switch self {
            case .window(let id, let weight):
                guard let window = Window.get(byId: id) else { return false }
                // Never yank a natively minimized/fullscreen/hidden window (or popup) into a
                // tiling tree — it would occupy a dead tile slot and receive frame writes while
                // macOS owns its presentation. It re-tiles via normalizeLayoutReason on exit.
                switch window.windowParentCases {
                    case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                         .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                        return false
                    case .tilingContainer, .floatingWindowsContainer, .unbound:
                        break
                }
                window.bind(to: parent, adaptiveWeight: weight, index: index)
                return true
            case .container(let orientation, let layout, let weight, let children, let id):
                let container: TilingContainer
                if let id, let existing = reusing[id], existing.parent == nil {
                    existing.reshape(orientation: orientation, layout: layout)
                    existing.bind(to: parent, adaptiveWeight: weight, index: index)
                    container = existing
                } else {
                    container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, layout, index: index)
                }
                var boundAny = false
                var nextIndex = 0
                for child in children {
                    // Indices stay consistent because skipped leaves don't consume a slot
                    if child.restore(parent: container, index: nextIndex, reusing: reusing) {
                        boundAny = true
                        nextIndex += 1
                    }
                }
                if !boundAny {
                    container.unbindFromParent() // drop the empty shell
                }
                return boundAny
        }
    }
}

// MARK: - Workspace / world capture

struct PersistentWorkspaceSnapshot: Equatable, Sendable {
    let name: String
    /// Reboot-stable display key (display UUID). nil in files written before it existed, which is
    /// why `monitorTopLeft` is retained as a fallback rather than replaced.
    let monitorKey: String?
    let monitorTopLeft: CGPoint
    let visibleWorkspaceName: String?
    let rootTiling: PersistentTilingNode
    let floatingWindowIds: [UInt32]
    let unconventionalWindowIds: [UInt32]
}

struct PersistentWorldSnapshot: Equatable, Sendable {
    let workspaces: [PersistentWorkspaceSnapshot]
    let monitorAssignments: [(key: String?, topLeft: CGPoint, workspace: String)]
    let windowIds: Set<UInt32>

    static func == (lhs: PersistentWorldSnapshot, rhs: PersistentWorldSnapshot) -> Bool {
        lhs.workspaces == rhs.workspaces &&
            lhs.windowIds == rhs.windowIds &&
            lhs.monitorAssignments.count == rhs.monitorAssignments.count &&
            zip(lhs.monitorAssignments, rhs.monitorAssignments).allSatisfy {
                $0.key == $1.key && $0.topLeft == $1.topLeft && $0.workspace == $1.workspace
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
                monitorKey: ws.workspaceMonitor.persistentKey,
                monitorTopLeft: ws.workspaceMonitor.rect.topLeftCorner,
                visibleWorkspaceName: ws.isVisible ? ws.name : nil,
                rootTiling: PersistentTilingNode.capture(ws.rootTilingContainer),
                floatingWindowIds: floating,
                unconventionalWindowIds: unconventional,
            )
        }
        let assignments = monitors.map {
            (key: Optional($0.persistentKey), topLeft: $0.rect.topLeftCorner, workspace: $0.activeWorkspace.name)
        }
        let ids = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
        return PersistentWorldSnapshot(
            workspaces: workspaces,
            monitorAssignments: assignments,
            windowIds: ids,
        )
    }
}
