import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    /// Dirty-flag protocol: layout is part of the published tiling spine. Every mutation site must
    /// call `setLayout` (or invalidate the generation itself) — a bare assignment leaves the stale
    /// spine published: the command visually no-ops and live/spine mismatch can crash weight sync.
    var layout: Layout

    @MainActor
    func setLayout(_ newLayout: Layout) {
        guard layout != newLayout else { return }
        layout = newLayout
        nodeWorkspace?.invalidateTilingStructureGeneration()
    }

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self.layout = layout
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach {
                    $0._orientation = orientation
                    orientation = orientation.opposite
                }
        } else {
            _orientation = targetOrientation
        }
        // Orientation is spine-published state — see `layout` didSet
        nodeWorkspace?.invalidateTilingStructureGeneration()
    }

    @MainActor
    func normalizeOppositeOrientationForNestedContainers() {
        var changed = false
        if orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
            changed = true
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
        }
        if changed {
            nodeWorkspace?.invalidateTilingStructureGeneration()
        }
    }
}

enum Layout: String, Sendable, Hashable, Equatable {
    case tiles
    case accordion
    /// Index-0 is master; remaining children stack in the secondary area (Hyprland master layout).
    case master
}

extension String {
    func parseLayout() -> Layout? {
        switch Layout(rawValue: self) {
            case let parsed?: parsed
            case nil where self == "list": .tiles
            case nil: nil
        }
    }
}
