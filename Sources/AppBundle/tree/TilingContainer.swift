import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    private(set) var layout: Layout

    @MainActor
    func setLayout(_ newLayout: Layout) {
        guard layout != newLayout else { return }
        Kernel.noteModelMutation("setLayout")
        layout = newLayout
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

    /// Take the shape a snapshot describes (reusing this container for it)
    @MainActor
    func reshape(orientation: Orientation, layout: Layout) {
        Kernel.noteModelMutation("reshape")
        _orientation = orientation
        self.layout = layout
    }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        Kernel.noteModelMutation("changeOrientation")
        if orientation == targetOrientation {
            return
        }
        // Dwindle picks every orientation by tile aspect ratio and normalizeContainers deliberately
        // skips opposite-orientation alternation for it; alternating here transposed the WHOLE
        // workspace on `layout horizontal|vertical`. i3 only ever changes the target container.
        // Nor under i3 normalization: i3 `split`/`layout splith|splitv` change only the target
        let alternate = config.enableNormalizationOppositeOrientationForNestedContainers
            && nodeWorkspace?.effectiveTilingPolicy != .dwindle
            && !config.i3Normalization
        if alternate {
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
    }

    @MainActor
    func normalizeOppositeOrientationForNestedContainers() {
        if orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
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

extension TilingContainer {
    /// Weight units per pixel along `orientation`, from the last render. Weights are proportions
    /// in no particular unit (layout no longer rewrites them as pixel spans), so a pixel amount —
    /// `resize width +50`, `resize-to`, a mouse edge drag — goes through this. A container not
    /// rendered yet (`join-with right; resize width +100` in one binding) uses the span the model
    /// projects for it — the monitor's whole span was wrong for any nested container.
    @MainActor
    func weightPerPixel(_ orientation: Orientation) -> CGFloat {
        let weightSum = CGFloat(children.sumOfDouble { $0.getWeight(orientation) })
        let span = lastAppliedLayoutVirtualRect?.getDimension(orientation)
            ?? nodeWorkspace?.projectedTileSize(of: self).map { orientation == .h ? $0.width : $0.height }
            ?? nodeWorkspace?.workspaceMonitor.visibleRect.getDimension(orientation)
            ?? weightSum
        return span > 0 && weightSum > 0 ? weightSum / span : 1
    }
}
