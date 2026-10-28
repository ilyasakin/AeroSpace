import AppKit
import Common

extension TreeNode {
    private func visit(node: TreeNode, result: inout [Window]) {
        if let node = node as? Window {
            result.append(node)
        }
        for child in node.children {
            visit(node: child, result: &result)
        }
    }
    var allLeafWindowsRecursive: [Window] {
        var result: [Window] = []
        visit(node: self, result: &result)
        return result
    }

    var ownIndex: Int? {
        guard let parent else { return nil }
        return parent.children.firstIndex(of: self).orDie()
    }

    var parents: [NonLeafTreeNodeObject] {
        var result: [NonLeafTreeNodeObject] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    var parentsWithSelf: [TreeNode] {
        var result: [TreeNode] = [self]
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    /// Also see visualWorkspace
    var nodeWorkspace: Workspace? {
        self as? Workspace ?? parent?.nodeWorkspace
    }

    /// Also see: workspace
    @MainActor
    var visualWorkspace: Workspace? { nodeWorkspace ?? nodeMonitor?.activeWorkspace }

    @MainActor
    var nodeMonitor: Monitor? {
        switch self.nodeCases {
            case .workspace(let ws): ws.workspaceMonitor
            case .window,
                 .tilingContainer,
                 .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .floatingWindowsContainer: parent?.nodeMonitor
            case .macosMinimizedWindowsContainer, .macosPopupWindowsContainer: nil
        }
    }

    /// Every window under this node, most recently focused first: a DFS that visits each
    /// container's children in its MRU order (never-focused children last, in child order). This
    /// is i3's per-container focus stack flattened; replaying it least-recent-first through
    /// `markAsMostRecentChild` rebuilds every stack along the way.
    var windowsInFocusOrder: [Window] {
        var result: [Window] = []
        func visit(_ node: TreeNode) {
            if let w = node as? Window {
                result.append(w)
                return
            }
            var seen: [ObjectIdentifier] = []
            for child in node.mruChildren {
                seen.append(ObjectIdentifier(child))
                visit(child)
            }
            // Never-focused children rank last-child-first, matching `mostRecentChild`'s
            // `children.last` fallback
            for child in node.children.reversed() where !seen.contains(ObjectIdentifier(child)) {
                visit(child)
            }
        }
        visit(self)
        return result
    }

    /// The window focus returns to inside this node (i3's focus stack): walk children in MRU order,
    /// falling through EMPTY subtrees instead of dead-ending in them (closing the last float left
    /// an empty floating container on top, and focus then fell to the top-left tile). Windows
    /// parked in macOS-owned containers (native fullscreen, hidden app, minimized, popups) are not
    /// focus targets — returning one switched native tabs or jumped Spaces on workspace switch-back.
    var mostRecentWindowRecursive: Window? {
        if let w = self as? Window { return w }
        var seen: [ObjectIdentifier] = []
        for child in mruChildren {
            seen.append(ObjectIdentifier(child))
            if child.isMacosParkingContainer { continue }
            if let w = child.mostRecentWindowRecursive { return w }
        }
        for child in children.reversed() where !seen.contains(ObjectIdentifier(child)) && !child.isMacosParkingContainer {
            if let w = child.mostRecentWindowRecursive { return w }
        }
        return nil
    }

    /// Containers whose windows macOS (not the tiling tree) currently owns
    var isMacosParkingContainer: Bool {
        switch nodeCases {
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer: true
            case .window, .workspace, .tilingContainer, .floatingWindowsContainer: false
        }
    }

    var anyLeafWindowRecursive: Window? {
        if let window = self as? Window {
            return window
        }
        for child in children {
            if let window = child.anyLeafWindowRecursive {
                return window
            }
        }
        return nil
    }

    // Doesn't contain at least one window
    var isEffectivelyEmpty: Bool {
        anyLeafWindowRecursive == nil
    }

    @MainActor
    var hWeight: CGFloat {
        get { getWeight(.h) }
        set { setWeight(.h, newValue) }
    }

    @MainActor
    var vWeight: CGFloat {
        get { getWeight(.v) }
        set { setWeight(.v, newValue) }
    }

    /// Returns closest parent that has children in the specified direction relative to `self`
    func closestParent(
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: Layout?,
    ) -> (parent: TilingContainer, ownIndex: Int)? {
        let innermostChild = parentsWithSelf.first(where: { (node: TreeNode) -> Bool in
            return switch node.parent?.cases {
                // stop searching. We didn't find it, or something went wrong
                case .workspace, nil, .macosMinimizedWindowsContainer,
                     .floatingWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosPopupWindowsContainer:
                    true
                case .tilingContainer(let parent):
                    (layout == nil || parent.layout == layout) &&
                        parent.orientation == direction.orientation &&
                        (node.ownIndex.map { parent.children.indices.contains($0 + direction.focusOffset) } ?? true)
            }
        })
        guard let innermostChild else { return nil }
        switch innermostChild.parent?.cases {
            case .tilingContainer(let parent):
                check(parent.orientation == direction.orientation)
                return innermostChild.ownIndex.map { (parent, $0) }
            case .workspace, .floatingWindowsContainer, nil, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                return nil
        }
    }
}
