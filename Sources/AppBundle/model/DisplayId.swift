import AppKit
import Common

/// Stable identity for a monitor, independent of where that monitor currently sits.
///
/// **Geometry is not identity.** This codebase used `monitor.rect.topLeftCorner` as the key for
/// workspace→monitor association, in memory and on disk. A top-left corner changes whenever displays
/// are rearranged, a resolution changes, a lid closes, or a display sleeps — so the key for "which
/// monitor does this workspace belong to" moved under the association it was identifying.
/// `rearrangeWorkspacesOnMonitors` then reconciled old keys to new ones by *nearest Euclidean
/// distance*, silently dropping a workspace whenever two old corners mapped to one new corner, and
/// never remapping invisible workspaces at all. That is the mechanism behind workspaces losing their
/// monitor and collapsing onto the main display.
///
/// `CGDirectDisplayID` is the identity WindowServer itself uses, and it is stable for as long as a
/// display stays connected — which is exactly the lifetime of an in-memory association.
///
/// It is **not** guaranteed stable across reboots or re-plugging, so it is deliberately NOT the key
/// used for on-disk session restore; see the session-store notes.
struct DisplayId: Hashable, Comparable, CustomStringConvertible, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// For CoreGraphics / SkyLight calls that want the raw display number.
    var cg: CGDirectDisplayID { rawValue }

    /// Synthetic id for the fake monitor used under test, where no real display exists.
    /// Sits in the reserved high range so it cannot collide with a real display number.
    static let test = DisplayId(rawValue: 0xFFFF_FFFE)

    static func < (lhs: DisplayId, rhs: DisplayId) -> Bool { lhs.rawValue < rhs.rawValue }
    var description: String { "display#\(rawValue)" }
}

extension NSScreen {
    /// Raw `CGDirectDisplayID`, or nil mid-reconfiguration.
    var cgDisplayId: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Identity for this screen. Falls back to the AppKit screens index when the display number is
    /// unavailable (only observed during reconfiguration) so a monitor always HAS an identity —
    /// a nil identity would silently reintroduce geometry-keyed fallbacks at the call sites.
    func displayId(fallbackIndex: Int) -> DisplayId {
        if let id = cgDisplayId { return DisplayId(rawValue: id) }
        return DisplayId(rawValue: UInt32(0xF000_0000) | UInt32(truncatingIfNeeded: fallbackIndex))
    }
}

extension Monitor {
    /// Key for PERSISTED monitor association. See `SkyLight.displayUuid`: the display UUID survives
    /// reboots and re-plugging, where `CGDirectDisplayID` does not. Falls back to the display number
    /// so there is always a key; a restore that can't match by key still falls back to geometry.
    var persistentKey: String {
        SkyLight.displayUuid(displayId.cg) ?? "display-number:\(displayId.rawValue)"
    }
}
