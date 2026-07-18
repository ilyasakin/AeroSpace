import AppKit

// Workspace.layoutWorkspace() — tiling from persistent spine — lives in layoutPersistent.swift.
// This file keeps floating/fullscreen helpers and LayoutContext used by both paths.

struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        // The AX read below is only needed to migrate a floating window that drifted onto another
        // monitor's active workspace. With a single monitor and a visible workspace that can't happen
        if !(monitors.count == 1 && workspace.isVisible) {
            let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
            let currentMonitor = windowRect?.center.monitorApproximation
            if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
                let windowTopLeftCorner = windowRect.topLeftCorner
                let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
                let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

                let workspaceRect = workspace.workspaceMonitor.visibleRect
                var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
                var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

                let windowWidth = windowRect.width
                let windowHeight = windowRect.height
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            }
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}
