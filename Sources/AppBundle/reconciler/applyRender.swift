import AppKit
import Common

extension Workspace {
    /// Bring the workspace's tiles in line with a render: record each window's intended frame and
    /// write the ones that changed. The mouse-drag target is the user's to place: its intent is
    /// recorded, its frame is not written.
    @MainActor
    func applyRender(_ render: WorkspaceRender) {
        desiredRect = render.physical
        lastAppliedLayoutVirtualRect = render.virtual
        let context = LayoutContext(self)
        for tile in render.tiles {
            guard let window = Window.get(byId: tile.windowId) else { continue }
            window.lastAppliedLayoutVirtualRect = tile.virtual
            if window.isFullscreen {
                window.layoutFullscreen(context)
                continue
            }
            let mouseTarget = window.windowId == currentlyManipulatedWithMouseWindowId
            if !mouseTarget { unlearnMaxSizeIfExceeded(window) }
            let previous = window.desiredRect
            window.desiredRect = tile.physical
            if !mouseTarget, previous != tile.physical {
                window.setAxFrame(tile.physical.topLeftCorner, CGSize(width: tile.physical.width, height: tile.physical.height))
            }
        }
        // Containers get the bounding rect of their windows (hit-testing, drag-to-swap)
        assignContainerRects(rootTilingContainer)
    }
}
