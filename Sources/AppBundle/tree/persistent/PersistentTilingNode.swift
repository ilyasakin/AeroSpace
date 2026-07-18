import Common
import Foundation

/// Immutable, single-linked (downward) persistent tiling tree.
///
/// Parent links are not stored: navigation uses a path (zipper indices). Updates return a new
/// root and share unchanged sibling subtrees (path copying). This is the structural model
/// for issue #1215; live `TreeNode` remains the identity/AX handle layer bridged via
/// capture/restore.
///
/// Motivation (upstream #1215): stable structure without fragile dual-link bind/unbind,
/// cheap snapshots for lock-screen recovery, future multi-threaded layout, optional undo.
enum PersistentTilingNode: Equatable, Sendable, Hashable {
    case window(id: UInt32, weight: CGFloat)
    case container(orientation: Orientation, layout: Layout, weight: CGFloat, children: [PersistentTilingNode])

    var weight: CGFloat {
        switch self {
            case .window(_, let w): w
            case .container(_, _, let w, _): w
        }
    }

    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }

    var isContainer: Bool {
        if case .container = self { return true }
        return false
    }

    /// Depth-first window ids
    var windowIds: [UInt32] {
        switch self {
            case .window(let id, _): [id]
            case .container(_, _, _, let children): children.flatMap(\.windowIds)
        }
    }

    var childCount: Int {
        switch self {
            case .window: 0
            case .container(_, _, _, let children): children.count
        }
    }

    /// True if this node is a window with `id` or a container that contains it.
    func containsWindowId(_ id: UInt32) -> Bool {
        switch self {
            case .window(let wid, _): wid == id
            case .container(_, _, _, let children): children.contains { $0.containsWindowId(id) }
        }
    }

    /// Shape equality: same orientation/layout nesting and window ids in order, **ignoring weights**.
    /// Used so layout-adjusted generations are not discarded when live dual-link container weights
    /// lag (windows alone were synced before; nested container weights may still differ).
    func structureEquals(_ other: PersistentTilingNode) -> Bool {
        switch (self, other) {
            case (.window(let id1, _), .window(let id2, _)):
                id1 == id2
            case (.container(let o1, let l1, _, let c1), .container(let o2, let l2, _, let c2)):
                o1 == o2 && l1 == l2 && c1.count == c2.count &&
                    zip(c1, c2).allSatisfy { $0.structureEquals($1) }
            default:
                false
        }
    }
}

/// Path from root: each index selects a child of a container.
struct PersistentPath: Equatable, Sendable, Hashable {
    var indices: [Int]

    static let root = PersistentPath(indices: [])

    var isRoot: Bool { indices.isEmpty }

    func appending(_ index: Int) -> PersistentPath {
        PersistentPath(indices: indices + [index])
    }

    var dropLast: PersistentPath {
        PersistentPath(indices: Array(indices.dropLast()))
    }
}

// MARK: - Read

extension PersistentTilingNode {
    func node(at path: PersistentPath) -> PersistentTilingNode? {
        var current = self
        for index in path.indices {
            guard case .container(_, _, _, let children) = current,
                  children.indices.contains(index)
            else { return nil }
            current = children[index]
        }
        return current
    }
}

// MARK: - Path-copying updates

extension PersistentTilingNode {
    /// Replace the node at `path` with `newNode`. Shares all siblings not on the path.
    func updating(at path: PersistentPath, with newNode: PersistentTilingNode) -> PersistentTilingNode? {
        if path.isRoot { return newNode }
        return updating(remaining: path.indices[...], with: newNode)
    }

    private func updating(remaining: ArraySlice<Int>, with newNode: PersistentTilingNode) -> PersistentTilingNode? {
        guard let first = remaining.first else { return newNode }
        guard case .container(let orientation, let layout, let weight, var children) = self,
              children.indices.contains(first)
        else { return nil }
        guard let updatedChild = children[first].updating(remaining: remaining.dropFirst(), with: newNode) else {
            return nil
        }
        children[first] = updatedChild
        return .container(orientation: orientation, layout: layout, weight: weight, children: children)
    }

    /// Insert `child` at `index` into the container at `path`.
    func inserting(child: PersistentTilingNode, at index: Int, intoContainerAt path: PersistentPath) -> PersistentTilingNode? {
        guard let target = node(at: path),
              case .container(let orientation, let layout, let weight, var children) = target
        else { return nil }
        let i = index == INDEX_BIND_LAST ? children.count : index
        guard i >= 0, i <= children.count else { return nil }
        children.insert(child, at: i)
        let newContainer = PersistentTilingNode.container(
            orientation: orientation,
            layout: layout,
            weight: weight,
            children: children,
        )
        return updating(at: path, with: newContainer)
    }

    /// Remove the node at `path` (must not be root). Returns (newRoot, removed).
    func removing(at path: PersistentPath) -> (root: PersistentTilingNode, removed: PersistentTilingNode)? {
        guard !path.isRoot, let last = path.indices.last else { return nil }
        let parentPath = path.dropLast
        guard let parent = node(at: parentPath),
              case .container(let orientation, let layout, let weight, var children) = parent,
              children.indices.contains(last)
        else { return nil }
        let removed = children.remove(at: last)
        let newParent = PersistentTilingNode.container(
            orientation: orientation,
            layout: layout,
            weight: weight,
            children: children,
        )
        guard let root = updating(at: parentPath, with: newParent) else { return nil }
        return (root, removed)
    }

    /// Set weight of the node at `path`.
    func settingWeight(_ weight: CGFloat, at path: PersistentPath) -> PersistentTilingNode? {
        guard let node = node(at: path) else { return nil }
        let updated: PersistentTilingNode = switch node {
            case .window(let id, _): .window(id: id, weight: weight)
            case .container(let o, let l, _, let c): .container(orientation: o, layout: l, weight: weight, children: c)
        }
        return updating(at: path, with: updated)
    }

    /// Find path of window id (first match, DFS).
    func path(ofWindowId id: UInt32) -> PersistentPath? {
        path(ofWindowId: id, prefix: .root)
    }

    private func path(ofWindowId id: UInt32, prefix: PersistentPath) -> PersistentPath? {
        switch self {
            case .window(let wid, _):
                return wid == id ? prefix : nil
            case .container(_, _, _, let children):
                for (i, child) in children.enumerated() {
                    if let found = child.path(ofWindowId: id, prefix: prefix.appending(i)) {
                        return found
                    }
                }
                return nil
        }
    }
}


