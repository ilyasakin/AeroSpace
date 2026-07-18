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
