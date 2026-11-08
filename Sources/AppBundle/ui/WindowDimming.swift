import Foundation

/// `dim-inactive-windows`: every window on a visible workspace except the focused one (or the
/// focused container's windows after `focus parent`) is darkened. Only changes are sent.
@MainActor
final class WindowDimming {
    static let shared = WindowDimming()
    /// What WindowServer currently has, for windows we changed
    private(set) var applied: [UInt32: Float] = [:]

    func refresh() {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        let cfg = config.dimInactiveWindows
        guard cfg.enabled, ServerState.isEnabled else {
            undimAll()
            return
        }
        let focused = Set(focus.focusedNode?.allLeafWindowsRecursive.map(\.windowId) ?? [])
            .union(focus.windowOrNil.map { [$0.windowId] } ?? [])
        var wanted: [UInt32: Float] = [:]
        for workspace in Workspace.allUnsorted where workspace.isVisible {
            for window in workspace.allLeafWindowsRecursive {
                wanted[window.windowId] = focused.contains(window.windowId) ? 0 : cfg.brightness
            }
        }
        apply(dimmingChanges(applied: applied, wanted: wanted))
    }

    /// Before quitting: nothing may stay dark
    func undimAll() {
        let dimmed = applied.filter { $0.value != 0 }.map(\.key)
        WindowServerEvents.setBrightness(dimmed, 0)
        applied = [:]
    }

    private func apply(_ changes: [Float: [UInt32]]) {
        for (value, ids) in changes {
            WindowServerEvents.setBrightness(ids, value)
            for id in ids { applied[id] = value }
        }
        // Forget windows that are gone
        for id in applied.keys where Window.get(byId: id) == nil { applied.removeValue(forKey: id) }
    }
}

/// Windows whose brightness must change, grouped by the new value. A window that left the visible
/// set is restored to 0 only if we had dimmed it.
func dimmingChanges(applied: [UInt32: Float], wanted: [UInt32: Float]) -> [Float: [UInt32]] {
    var changes: [Float: [UInt32]] = [:]
    for (id, value) in wanted where (applied[id] ?? 0) != value {
        changes[value, default: []].append(id)
    }
    for (id, value) in applied where wanted[id] == nil && value != 0 {
        changes[0, default: []].append(id)
    }
    return changes.mapValues { $0.sorted() }
}
