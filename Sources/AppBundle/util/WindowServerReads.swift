import CoreGraphics
import Foundation

/// Narrow injectable boundary for WindowServer / on-screen-list **reads**.
///
/// Production uses SkyLight (`SLSGetWindowBounds`) + one CGWindowList scan per session.
/// Tests install a double so layout/focus/border math can supply fixed bounds without
/// touching real WindowServer or AX. Writes still go through AX exclusively.
///
/// Not MainActor-isolated: `MacWindow.getAxRect`/`getAxSize` and AX threads call into this
/// the same way they called `SkyLight.windowBounds` (which is nonisolated).
protocol WindowServerReadPort: AnyObject {
    /// Live global top-left frame. `forOverlay: true` is not gated on `skylight-reads`
    /// (borders always need live frames); `false` respects the config flag.
    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect?

    /// Session on-screen list (levels + layer-0 stack). Production scans at most once per
    /// invalidate; test doubles return a fixed snapshot.
    func onScreenSnapshot() -> OnScreenWindowSnapshot
}

/// Process-wide install point. Default is production. Tests call `install` / `install(nil)` to reset.
enum WindowServerReads {
    private nonisolated(unsafe) static var installed: (any WindowServerReadPort)?

    nonisolated static var current: any WindowServerReadPort {
        unsafe installed ?? ProductionWindowServerReads.shared
    }

    /// Install a test double, or `nil` to restore production.
    static func install(_ port: (any WindowServerReadPort)?) {
        unsafe installed = port
        // Drop any cached production snapshot so the next read sees the new port
        invalidateOnScreenWindowSnapshot()
    }
}

/// Production implementation: SkyLight + CGWindowList. Allocation-light; snapshot is session-cached.
final class ProductionWindowServerReads: WindowServerReadPort {
    nonisolated(unsafe) static let shared = ProductionWindowServerReads()
    private init() {}

    func windowBounds(windowId: UInt32, forOverlay: Bool) -> Rect? {
        if forOverlay {
            return SkyLight.overlayBounds(windowId)
        }
        return SkyLight.windowBounds(windowId)
    }

    func onScreenSnapshot() -> OnScreenWindowSnapshot {
        productionOnScreenWindowSnapshot()
    }
}

// MARK: - Frame resolution (shared by MacWindow; unit-tested without MacApp)

/// How MacWindow answers getAxRect/getAxSize after checking write-lag and WindowServer.
enum FrameReadResolution: Equatable {
    /// Use layout-applied rect (instant; covers SkyLight lag after our AX write)
    case lastApplied(Rect)
    /// Use WindowServer live bounds
    case windowServer(Rect)
    /// Must go through AX (serialized after write, or WS unavailable)
    case needAx
}

/// Pure decision for frame reads. `serverBounds` is injected so tests supply fixed tables
/// without SkyLight; production passes `{ WindowServerReads.current.windowBounds(windowId: $0, forOverlay: false) }`.
func resolveFrameRead(
    windowId: UInt32,
    lastApplied: Rect?,
    mayBeStale: Bool,
    serverBounds: (UInt32) -> Rect?,
) -> FrameReadResolution {
    if mayBeStale {
        if let lastApplied { return .lastApplied(lastApplied) }
        return .needAx
    }
    if let bounds = serverBounds(windowId) { return .windowServer(bounds) }
    return .needAx
}

/// Pure decision for **border overlay** frames during `refresh()`.
///
/// Unlike layout frame reads, borders must track the live on-screen window during a user drag.
/// Preferring `lastApplied` unconditionally freezes the border on the layout tile while the
/// window moves under the mouse. Only prefer lastApplied when *we* just wrote the frame
/// (`mayBeStale`) and SkyLight may still report the pre-write bounds.
func resolveBorderRect(
    lastApplied: Rect?,
    mayBeStale: Bool,
    liveBounds: Rect?,
    stackRect: Rect?,
) -> Rect? {
    if mayBeStale, let lastApplied { return lastApplied }
    if let liveBounds { return liveBounds }
    if let stackRect { return stackRect }
    return lastApplied
}

/// Pure decision for **live** border frames on WindowServer move/resize notify.
///
/// - **Floating**: user owns the frame — always track live WS. lastApplied is only a
///   focus-follows-mouse / layout snapshot and freezes under free drag if preferred.
/// - **Tiling + mouse manipulate**: prefer lastApplied so borders match the tile grid
///   (live drag frame of the resize target ≠ sibling layout allocations → edge thrash).
/// - **After our AX write**: prefer lastApplied until SkyLight catches up.
func resolveLiveBorderRect(
    isFloating: Bool,
    mouseManipulateActive: Bool,
    mayBeStale: Bool,
    lastApplied: Rect?,
    liveBounds: Rect?,
) -> Rect? {
    if isFloating {
        if mayBeStale, let lastApplied { return lastApplied }
        return liveBounds ?? lastApplied
    }
    if mouseManipulateActive, let lastApplied { return lastApplied }
    if mayBeStale, let lastApplied { return lastApplied }
    return liveBounds
}

/// Merge a partial frame write into the last applied rect.
/// Command chains like `resize` then `center-window` issue size-only then position-only writes;
/// without merging, the second call cancels the first AX job and leaves the tiled size.
func mergeFrameWrite(
    previous: Rect?,
    topLeft: CGPoint?,
    size: CGSize?,
) -> Rect? {
    let origin = topLeft ?? previous?.topLeftCorner
    let sz = size ?? previous.map { CGSize(width: $0.width, height: $0.height) }
    guard let origin, let sz else { return previous }
    return Rect(topLeftX: origin.x, topLeftY: origin.y, width: sz.width, height: sz.height)
}
