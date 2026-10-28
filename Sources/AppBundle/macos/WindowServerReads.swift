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
        // Under test the default is an empty WindowServer: a test window id must never resolve to
        // a real on-screen window of the user's session (ids are small integers that do collide).
        unsafe installed ?? (Headless.isActive ? NullWindowServerReads.shared : ProductionWindowServerReads.shared)
    }

    /// Install a test double, or `nil` to restore production.
    static func install(_ port: (any WindowServerReadPort)?) {
        unsafe installed = port
        // Drop any cached production snapshot so the next read sees the new port
        invalidateOnScreenWindowSnapshot()
    }
}

/// Test default: no windows on screen, no bounds known. Tests that need frames install a double.
final class NullWindowServerReads: WindowServerReadPort {
    nonisolated(unsafe) static let shared = NullWindowServerReads()
    private init() {}
    func windowBounds(windowId _: UInt32, forOverlay _: Bool) -> Rect? { nil }
    func onScreenSnapshot() -> OnScreenWindowSnapshot { OnScreenWindowSnapshot(levels: [:], normalStack: []) }
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

/// Merge a partial frame write into the last applied rect.
/// Command chains like `resize` then `center-window` issue size-only then position-only writes;
/// without merging, the second call cancels the first AX job and leaves the tiled size.
/// Which AX attributes a frame write must send. Each is a synchronous cross-process message.
struct AxFrameWritePlan: Equatable {
    var size: Bool
    var position: Bool
    /// Size again after the move (upstream #143/#335: the first size can be clamped by the monitor
    /// the window is still on). Only needed when the window changes monitor.
    var trailingSize: Bool

    static let full = AxFrameWritePlan(size: true, position: true, trailingSize: true)
}

/// Pure: minimal attribute set to go from `previous` belief to `target`.
/// - Unknown belief, or a previous write still in flight (the new job cancels it, so anything it
///   carried must be resent): full write.
/// - Otherwise only what changed; the trailing size only across monitors. Parking a window in the
///   hide corner (position only) used to cost size+position+size.
/// `previousOverhangsScreen`: the old frame reaches past its monitor's edge, so even a smaller size
/// doesn't fit at the old origin
func planAxFrameWrite(previous: Rect?, previousInFlight: Bool, target: Rect, crossesMonitor: Bool, previousOverhangsScreen: Bool = false) -> AxFrameWritePlan {
    // Crossing monitors, or coming back from the hide corner (whose centre is off every monitor):
    // the window may have been clamped/resized where it was — send everything
    guard let previous, !previousInFlight, !crossesMonitor else { return .full }
    let sizeChanged = abs(previous.width - target.width) > 0.5 || abs(previous.height - target.height) > 0.5
    // A window that settles a pixel off (backing-scale rounding: asked y=1089, sits at 1090) is
    // where it was put: re-sending its position on every layout changed nothing
    let positionChanged = abs(previous.topLeftX - target.topLeftX) > 1 || abs(previous.topLeftY - target.topLeftY) > 1
    // The size goes first, applied at the OLD origin, and macOS clamps it to what fits on screen
    // from there: a small bottom-right tile going fullscreen got (screen - old origin) and then moved
    // to the top-left at that size. Growing while moving re-sends the size after the move — as does
    // any resize+move of a window hanging off the screen (a float dragged half out, then resized).
    let grows = target.width > previous.width + 0.5 || target.height > previous.height + 0.5
    return AxFrameWritePlan(
        size: sizeChanged,
        // Nothing changed per belief: still send the position (cheap; re-asserts a stale belief)
        position: positionChanged || !sizeChanged,
        trailingSize: sizeChanged && positionChanged && (grows || previousOverhangsScreen),
    )
}

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
