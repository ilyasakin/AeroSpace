import AppKit
import Common

/// Frozen tiling snapshot storage is the immutable `PersistentTilingNode` (issue #1215).
/// These types remain as the closed-windows-cache API surface and wrap capture/restore.

enum FrozenTreeNode: Sendable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

struct FrozenContainer: Sendable {
    /// Immutable structural spine (path-copying persistent tree).
    let node: PersistentTilingNode

    var orientation: Orientation {
        if case .container(let o, _, _, _) = node { return o }
        die("FrozenContainer.node must be a container")
    }

    var layout: Layout {
        if case .container(_, let l, _, _) = node { return l }
        die("FrozenContainer.node must be a container")
    }

    var weight: CGFloat { node.weight }

    var children: [FrozenTreeNode] {
        guard case .container(_, _, _, let children) = node else {
            die("FrozenContainer.node must be a container")
        }
        return children.map { child in
            switch child {
                case .window(let id, let w): .window(FrozenWindow(id: id, weight: w))
                case .container: .container(FrozenContainer(node: child))
            }
        }
    }

    @MainActor init(_ container: TilingContainer) {
        node = PersistentTilingNode.capture(container)
    }

    init(node: PersistentTilingNode) {
        self.node = node
    }
}

struct FrozenWindow: Sendable {
    let id: UInt32
    let weight: CGFloat

    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = ((window.parent as? TilingContainer)?.orientation).map { window.getWeight($0) } ?? 1
    }

    init(id: UInt32, weight: CGFloat) {
        self.id = id
        self.weight = weight
    }
}
