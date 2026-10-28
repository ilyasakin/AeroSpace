import CoreGraphics
import Foundation

/// One CGWindowListCopyWindowInfo scan per refresh session, shared by window-level lookups and
/// window-border occlusion stacks. Obtained via `WindowServerReads.current.onScreenSnapshot()` so
/// tests can install a fixed list without a second full-list scan purpose in production.
struct OnScreenWindowSnapshot: Equatable {
    /// CGWindowID -> level for every on-screen window (all layers)
    let levels: [UInt32: MacOsWindowLevel]
    /// Layer-0 (normal) windows, front-to-back. Our floating overlays (tab bar, HUDs) are layer >0
    /// so the level check excludes them; our own *normal* windows (the Settings window) are kept so
    /// callers reasoning about the front window see it. Our SLS border windows ARE layer 0 and would
    /// otherwise shadow every window they surround, so they are filtered out here — see
    /// `BorderSkyLight.ownedWindowIds`.
    let normalStack: [(id: UInt32, rect: Rect)]

    static func == (lhs: OnScreenWindowSnapshot, rhs: OnScreenWindowSnapshot) -> Bool {
        guard lhs.levels == rhs.levels, lhs.normalStack.count == rhs.normalStack.count else { return false }
        for i in lhs.normalStack.indices {
            if lhs.normalStack[i].id != rhs.normalStack[i].id { return false }
            if lhs.normalStack[i].rect != rhs.normalStack[i].rect { return false }
        }
        return true
    }
}

// Guarded like monitorsCache: main-thread session cache
private nonisolated(unsafe) var snapshot: OnScreenWindowSnapshot?
private nonisolated(unsafe) var snapshotIsFresh = false

func invalidateOnScreenWindowSnapshot() {
    if Thread.isMainThread {
        unsafe snapshotIsFresh = false
    } else {
        // Off main: drop freshness conservatively on next main-thread access via install path only
        // (invalidate is only called from MainActor session begin / WindowServerReads.install)
        unsafe snapshotIsFresh = false
    }
}

/// Returns the session snapshot via the active `WindowServerReadPort` (production or test double).
func onScreenWindowSnapshot() -> OnScreenWindowSnapshot {
    WindowServerReads.current.onScreenSnapshot()
}

/// Pure parse of a CGWindowList payload. Split out from the scan so the layer/border filtering
/// is unit-testable without touching WindowServer — `excludedIds` carries our own border windows.
func parseOnScreenWindowSnapshot(
    _ arr: [[String: Any]],
    excludedIds: Set<UInt32>,
) -> OnScreenWindowSnapshot {
    var levels: [UInt32: MacOsWindowLevel] = [:]
    var normalStack: [(id: UInt32, rect: Rect)] = []
    levels.reserveCapacity(arr.count)
    normalStack.reserveCapacity(arr.count)

    for w in arr {
        guard let wid = w[kCGWindowNumber as String] as? Int else { continue }
        let id = UInt32(wid)
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        levels[id] = .new(windowLevel: layer)

        // Only layer 0 (normal windows). This already excludes our floating overlays; we do NOT
        // filter by our own pid, or the Settings window wouldn't clip the borders beneath it.
        // Our SLS border windows are the one exception: they sit at their target's level (0) and
        // are ordered directly above it, outset past its bounds, so leaving them in would make
        // EVERY bordered window's frontmost stack hit a border instead of the window itself.
        guard layer == 0, !excludedIds.contains(id),
              let b = w[kCGWindowBounds as String] as? [String: Any]
        else { continue }
        normalStack.append((id, Rect(
            topLeftX: (b["X"] as? CGFloat) ?? 0,
            topLeftY: (b["Y"] as? CGFloat) ?? 0,
            width: (b["Width"] as? CGFloat) ?? 0,
            height: (b["Height"] as? CGFloat) ?? 0,
        )))
    }
    return OnScreenWindowSnapshot(levels: levels, normalStack: normalStack)
}

/// Production scan: at most one CGWindowList per invalidate cycle (main thread).
func productionOnScreenWindowSnapshot() -> OnScreenWindowSnapshot {
    if Thread.isMainThread, unsafe snapshotIsFresh, let snapshot = unsafe snapshot {
        return snapshot
    }

    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let arr = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let built = unsafe parseOnScreenWindowSnapshot(arr, excludedIds: BorderSkyLight.ownedWindowIds)
    if Thread.isMainThread {
        unsafe snapshot = built
        unsafe snapshotIsFresh = true
    }
    return built
}
