import CoreGraphics
import Foundation

/// One CGWindowListCopyWindowInfo scan per refresh session, shared by window-level lookups and
/// window-border occlusion stacks. Both used to call the expensive list API independently.
@MainActor
struct OnScreenWindowSnapshot {
    /// CGWindowID -> level for every on-screen window (all layers)
    let levels: [UInt32: MacOsWindowLevel]
    /// Layer-0 windows excluding our own process, front-to-back (for border occlusion)
    let normalStack: [(id: UInt32, rect: Rect)]
}

@MainActor private var snapshot: OnScreenWindowSnapshot?
@MainActor private var snapshotIsFresh = false

@MainActor
func invalidateOnScreenWindowSnapshot() {
    snapshotIsFresh = false
}

/// Returns the session snapshot, scanning at most once until the next invalidate
@MainActor
func onScreenWindowSnapshot() -> OnScreenWindowSnapshot {
    if snapshotIsFresh, let snapshot { return snapshot }

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
    snapshot = built
    snapshotIsFresh = true
    return built
}
