import CoreGraphics
import Foundation

/// One CGWindowListCopyWindowInfo scan per refresh session, shared by window-level lookups and
/// window-border occlusion stacks. Obtained via `WindowServerReads.current.onScreenSnapshot()` so
/// tests can install a fixed list without a second full-list scan purpose in production.
struct OnScreenWindowSnapshot: Equatable {
    /// CGWindowID -> level for every on-screen window (all layers)
    let levels: [UInt32: MacOsWindowLevel]
    /// Layer-0 windows excluding our own process, front-to-back (for border occlusion)
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

/// Production scan: at most one CGWindowList per invalidate cycle (main thread).
func productionOnScreenWindowSnapshot() -> OnScreenWindowSnapshot {
    if Thread.isMainThread, unsafe snapshotIsFresh, let snapshot = unsafe snapshot {
        return snapshot
    }

    let myPid = Int(ProcessInfo.processInfo.processIdentifier)
    var levels: [UInt32: MacOsWindowLevel] = [:]
    var normalStack: [(id: UInt32, rect: Rect)] = []

    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    if let arr = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
        levels.reserveCapacity(arr.count)
        normalStack.reserveCapacity(arr.count)
        for w in arr {
            guard let wid = w[kCGWindowNumber as String] as? Int else { continue }
            let id = UInt32(wid)
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            levels[id] = .new(windowLevel: layer)

            guard layer == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != myPid,
                  let b = w[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            let rect = Rect(
                topLeftX: (b["X"] as? CGFloat) ?? 0,
                topLeftY: (b["Y"] as? CGFloat) ?? 0,
                width: (b["Width"] as? CGFloat) ?? 0,
                height: (b["Height"] as? CGFloat) ?? 0,
            )
            normalStack.append((id, rect))
        }
    }

    let built = OnScreenWindowSnapshot(levels: levels, normalStack: normalStack)
    if Thread.isMainThread {
        unsafe snapshot = built
        unsafe snapshotIsFresh = true
    }
    return built
}
