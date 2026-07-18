import AppKit
import Common

/// Tiling layout driven by the immutable persistent spine (#1215 cutover).
/// Structure (parent/child geometry) comes from `PersistentTilingNode`; window identity/AX
/// still resolves through live `Window` handles. Floating windows remain on the live tree.

extension Workspace {
    /// Last tiling spine used for layout (updated each layout pass).
    @MainActor private static var _tilingSpineByName: [String: PersistentTilingNode] = [:]

    @MainActor
    var tilingStructureGeneration: PersistentTilingNode? {
        get { Self._tilingSpineByName[name] }
        set {
            if let newValue {
                Self._tilingSpineByName[name] = newValue
            } else {
                Self._tilingSpineByName.removeValue(forKey: name)
            }
        }
    }

    /// Drop cached spines (tests / workspace GC hygiene)
    @MainActor
    static func clearTilingStructureGenerations() {
        _tilingSpineByName.removeAll(keepingCapacity: true)
    }

    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        let context = LayoutContext(self)
        let physicalRect = Rect(
            topLeftX: rect.topLeftX,
            topLeftY: rect.topLeftY,
            width: rect.width,
            height: rect.height - 1,
        )
        lastAppliedLayoutPhysicalRect = physicalRect
        lastAppliedLayoutVirtualRect = rect

        let liveRoot = rootTilingContainer
        // Capture once: this generation is the structural source of truth for the pass
        let spine = PersistentTilingNode.capture(liveRoot)
        tilingStructureGeneration = spine

        try await layoutPersistentNode(
            spine,
            point: physicalRect.topLeftCorner,
            width: physicalRect.width,
            height: physicalRect.height,
            virtual: rect,
            path: .root,
            liveAnchor: liveRoot,
            context: context,
        )

        // Floating is not part of the tiling spine
        try await layoutFloatingChildren(context: context)
    }

    @MainActor
    fileprivate func layoutFloatingChildren(context: LayoutContext) async throws {
        for window in floatingWindows {
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            try await window.layoutFloatingWindow(context)
        }
    }
}

@MainActor
private func layoutPersistentNode(
    _ node: PersistentTilingNode,
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    path: PersistentPath,
    liveAnchor: TreeNode,
    context: LayoutContext,
) async throws {
    let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)

    switch node {
        case .window(let id, _):
            guard let window = Window.get(byId: id) else { return }
            if window.windowId == currentlyManipulatedWithMouseWindowId { return }
            window.lastAppliedLayoutVirtualRect = virtual
            if window.isFullscreen,
               window == context.workspace.rootTilingContainer.mostRecentWindowRecursive
            {
                window.lastAppliedLayoutPhysicalRect = nil
                window.layoutFullscreen(context)
            } else {
                let prev = window.lastAppliedLayoutPhysicalRect
                window.lastAppliedLayoutPhysicalRect = physicalRect
                window.isFullscreen = false
                if prev != physicalRect {
                    window.setAxFrame(point, CGSize(width: width, height: height))
                }
            }

        case .container(let orientation, let layout, _, let children):
            // Keep live container rects in sync for mouse/resize helpers that read lastApplied*
            liveAnchor.lastAppliedLayoutPhysicalRect = physicalRect
            liveAnchor.lastAppliedLayoutVirtualRect = virtual

            switch layout {
                case .tiles:
                    try await layoutPersistentTiles(
                        children: children,
                        orientation: orientation,
                        point: point,
                        width: width,
                        height: height,
                        virtual: virtual,
                        path: path,
                        liveAnchor: liveAnchor,
                        context: context,
                    )
                case .accordion:
                    try await layoutPersistentAccordion(
                        children: children,
                        orientation: orientation,
                        point: point,
                        width: width,
                        height: height,
                        virtual: virtual,
                        path: path,
                        liveAnchor: liveAnchor,
                        context: context,
                    )
            }
    }
}

@MainActor
private func layoutPersistentTiles(
    children: [PersistentTilingNode],
    orientation: Orientation,
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    path: PersistentPath,
    liveAnchor: TreeNode,
    context: LayoutContext,
) async throws {
    guard !children.isEmpty else { return }
    let liveChildren = liveAnchor.children
    let weightSum = CGFloat(children.sumOfDouble { Double($0.weight) })
    let span = orientation == .h ? width : height
    guard let delta = (span - weightSum).div(children.count) else { return }

    var point = point
    var virtualPoint = virtual.topLeftCorner
    let lastIndex = children.indices.last
    let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()

    for (i, child) in children.enumerated() {
        let adjustedWeight = child.weight + delta
        // Mirror weight onto live node so capture/mouse helpers stay consistent
        if liveChildren.indices.contains(i) {
            liveChildren[i].setWeight(orientation, adjustedWeight)
        }

        let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
        let childPoint = i == 0 ? point : point.addingOffset(orientation, rawGap / 2)
        let childWidth = orientation == .h ? adjustedWeight - gap : width
        let childHeight = orientation == .v ? adjustedWeight - gap : height
        let childVirtual = Rect(
            topLeftX: virtualPoint.x,
            topLeftY: virtualPoint.y,
            width: orientation == .h ? adjustedWeight : width,
            height: orientation == .v ? adjustedWeight : height,
        )
        let childLive = liveChildren.indices.contains(i) ? liveChildren[i] : liveAnchor
        try await layoutPersistentNode(
            child,
            point: childPoint,
            width: childWidth,
            height: childHeight,
            virtual: childVirtual,
            path: path.appending(i),
            liveAnchor: childLive,
            context: context,
        )
        virtualPoint = orientation == .h
            ? virtualPoint.addingXOffset(adjustedWeight)
            : virtualPoint.addingYOffset(adjustedWeight)
        point = orientation == .h
            ? point.addingXOffset(adjustedWeight)
            : point.addingYOffset(adjustedWeight)
    }
}

@MainActor
private func layoutPersistentAccordion(
    children: [PersistentTilingNode],
    orientation: Orientation,
    point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    path: PersistentPath,
    liveAnchor: TreeNode,
    context: LayoutContext,
) async throws {
    let liveChildren = liveAnchor.children
    let mruIndex = liveAnchor.mostRecentChild.flatMap { liveChildren.firstIndex(of: $0) } ?? 0
    let lastIndex = children.indices.last

    for (index, child) in children.enumerated() {
        let padding = CGFloat(config.accordionPadding)
        let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
            case 0 where children.count == 1: (0, 0)
            case 0: (0, padding)
            case lastIndex: (padding, 0)
            case mruIndex - 1: (0, 2 * padding)
            case mruIndex + 1: (2 * padding, 0)
            default: (padding, padding)
        }
        let childLive = liveChildren.indices.contains(index) ? liveChildren[index] : liveAnchor
        switch orientation {
            case .h:
                try await layoutPersistentNode(
                    child,
                    point: point + CGPoint(x: lPadding, y: 0),
                    width: width - rPadding - lPadding,
                    height: height,
                    virtual: virtual,
                    path: path.appending(index),
                    liveAnchor: childLive,
                    context: context,
                )
            case .v:
                try await layoutPersistentNode(
                    child,
                    point: point + CGPoint(x: 0, y: lPadding),
                    width: width,
                    height: height - lPadding - rPadding,
                    virtual: virtual,
                    path: path.appending(index),
                    liveAnchor: childLive,
                    context: context,
                )
        }
    }
}

// LayoutContext + floating/fullscreen helpers stay in layoutRecursive.swift (shared)
