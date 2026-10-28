import AppKit
import Common

/// The one memory of windows that left the model — closed, gone from AX for a moment, taken over
/// by macOS (native fullscreen, minimized, hidden app), or open in the last session — so that a
/// window which comes back returns where it was.
///
/// This was four stores with four eviction rules and no stated precedence between them: a
/// remembered-workspace FIFO, departed tile slots with a TTL, session-restore pending placements
/// and the lock-screen "closed windows" world snapshot. Now there is one place to ask and one
/// order of trust (`recallWorkspace`), and a workspace rename updates one store.
@MainActor
enum WindowMemory {
    // MARK: - Departures

    /// The workspace and the tile slot are each consumed once (the workspace when the window
    /// registers again, the slot when it is placed); the entry goes when both are
    struct Departure {
        var workspace: String?
        /// Where the tile sat (nil: the window wasn't tiled)
        var slot: FloatingRestoreSlot?
        let at: TimeInterval
    }

    private static var departures: [UInt32: Departure] = [:]
    /// Oldest first; bounds the memory
    private static var departureOrder: [UInt32] = []
    static let capacity = 128
    /// A tile slot names its neighbours; after this long the tree around it has moved on
    static let slotLifetime: TimeInterval = 60

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `window` is leaving `workspace` (it closed, vanished, or macOS took it over)
    static func noteLeaving(_ window: Window, from workspace: String) {
        // A window leaving from a macOS container (native fullscreen, minimized) isn't tiled any
        // more; the tile it came from is its restore point
        let slot = FloatingRestoreSlot.capture(from: window) ?? window.tileRestoreSlot
        noteLeaving(windowId: window.windowId, from: workspace, slot: slot)
    }

    static func noteLeaving(windowId: UInt32, from workspace: String, slot: FloatingRestoreSlot? = nil) {
        if departures[windowId] == nil { departureOrder.append(windowId) }
        // Never trade a known slot for none (a second departure from a macOS container)
        let keptSlot = slot ?? departures[windowId]?.slot
        departures[windowId] = Departure(workspace: workspace, slot: keptSlot, at: now)
        while departureOrder.count > capacity {
            departures.removeValue(forKey: departureOrder.removeFirst())
        }
    }

    /// The workspace a window left, consumed
    static func recallDeparture(windowId: UInt32) -> Workspace? {
        guard let name = departures[windowId]?.workspace else { return nil }
        departures[windowId]?.workspace = nil
        dropIfSpent(windowId)
        return Workspace.get(byName: name)
    }

    /// The tile slot a window left on `workspace`, if still fresh, consumed
    static func takeSlot(windowId: UInt32, on workspace: String) -> FloatingRestoreSlot? {
        guard let departure = departures[windowId] else { return nil }
        departures[windowId]?.slot = nil
        dropIfSpent(windowId)
        guard let slot = departure.slot, slot.workspaceName == workspace, now - departure.at < slotLifetime else { return nil }
        return slot
    }

    private static func dropIfSpent(_ windowId: UInt32) {
        guard let departure = departures[windowId], departure.workspace == nil, departure.slot == nil else { return }
        departures.removeValue(forKey: windowId)
        departureOrder.removeAll { $0 == windowId }
    }

    // MARK: - The last session

    private struct LastSessionPlacement {
        let savedId: UInt32
        var workspace: String
    }

    private static var lastSessionById: [UInt32: LastSessionPlacement] = [:]
    /// App → placements, oldest first. Only apps whose saved windows all sat on ONE workspace:
    /// pairing by order across workspaces would shuffle multi-workspace terminals
    private static var lastSessionByApp: [String: [LastSessionPlacement]] = [:]

    /// Session restore found saved windows not (yet) alive: they may still appear (slow AX at
    /// startup, or new ids after a reboot matched by app)
    static func rememberLastSession(_ placements: [(savedId: UInt32, workspace: String, app: String?)]) {
        lastSessionById.removeAll()
        lastSessionByApp.removeAll()
        var appWorkspaces: [String: Set<String>] = [:]
        for p in placements {
            let placement = LastSessionPlacement(savedId: p.savedId, workspace: p.workspace)
            lastSessionById[p.savedId] = placement
            if let app = p.app {
                lastSessionByApp[app, default: []].append(placement)
                appWorkspaces[app, default: []].insert(p.workspace)
            }
        }
        for (app, workspaces) in appWorkspaces where workspaces.count > 1 {
            lastSessionByApp.removeValue(forKey: app)
        }
    }

    /// The startup grace is over: what didn't come back isn't coming
    static func forgetLastSession() {
        lastSessionById.removeAll()
        lastSessionByApp.removeAll()
    }

    private static func takeLastSession(windowId: UInt32, appId: String?) -> Workspace? {
        if let placement = lastSessionById.removeValue(forKey: windowId) {
            for (app, queue) in lastSessionByApp {
                let filtered = queue.filter { $0.savedId != placement.savedId }
                if filtered.count != queue.count { lastSessionByApp[app] = filtered.isEmpty ? nil : filtered }
            }
            return Workspace.get(byName: placement.workspace)
        }
        if let appId, var queue = lastSessionByApp[appId], !queue.isEmpty {
            let placement = queue.removeFirst()
            lastSessionByApp[appId] = queue.isEmpty ? nil : queue
            lastSessionById.removeValue(forKey: placement.savedId)
            return Workspace.get(byName: placement.workspace)
        }
        return nil
    }

    // MARK: - Recall

    /// Where a (re)appearing window belongs, in order of trust: its place in the last session
    /// (consumed only once it registers — these sessions can be cancelled), then the workspace it
    /// left. nil: nothing remembered.
    static func recallWorkspace(windowId: UInt32, appId: String?) -> Workspace? {
        takeLastSession(windowId: windowId, appId: appId) ?? recallDeparture(windowId: windowId)
    }

    // MARK: - The world as it was (lock screen)

    /// When the screen locks, AX goes blank and every window looks closed. So when windows start
    /// leaving, the whole world is frozen once; when one of them comes back (unlock), it is
    /// restored as it was.
    private static var world = FrozenWorld(workspaces: [], monitors: [], windowIds: [])

    static func freezeWorldIfNeeded() {
        // Only the lock screen blanks AX for every window. Freezing on any close made a later,
        // unrelated return (a VLC fullscreen round trip) restore every workspace to an old state
        guard MacOS.current.isScreenLocked else { return }
        let allWs = Workspace.all
        let allWindowIds = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
        if allWindowIds.isSubset(of: world.windowIds) { return } // already frozen
        world = FrozenWorld(
            workspaces: allWs.map { FrozenWorkspace($0) },
            monitors: monitors.map(FrozenMonitor.init),
            windowIds: allWindowIds,
        )
    }

    /// The layout changed on purpose (a command, a mouse drag): a frozen world would restore the
    /// old one after the next lock
    static func forgetWorld() {
        world = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
    }

    /// `window` came back and belongs to the frozen world: restore the world. False otherwise.
    static func restoreWorldIfReturning(_ window: Window) async throws -> Bool {
        guard world.windowIds.contains(window.windowId) else { return false }
        try await restoreFrozenWorld(world)
        // Every frozen window is back: the world served its purpose
        if world.windowIds.allSatisfy({ Window.get(byId: $0) != nil }) { forgetWorld() }
        return true
    }

    // MARK: -

    static func renameWorkspace(from old: String, to new: String) {
        for (id, departure) in departures where departure.workspace == old { departures[id]?.workspace = new }
        for (id, departure) in departures where departure.slot?.workspaceName == old { departures[id]?.slot?.workspaceName = new }
        for (id, placement) in lastSessionById where placement.workspace == old { lastSessionById[id]?.workspace = new }
        for (app, queue) in lastSessionByApp {
            lastSessionByApp[app] = queue.map { var p = $0; if p.workspace == old { p.workspace = new }; return p }
        }
    }

    static func resetForTests() {
        departures = [:]
        departureOrder = []
        forgetLastSession()
        forgetWorld()
    }
}

extension Workspace {
    /// Place a window that was just (re-)registered and parked in this workspace's floating layer:
    /// back into its remembered tile slot if it has one, otherwise as a new window.
    @MainActor
    func placeRegisteredWindow(_ window: Window) {
        if let slot = WindowMemory.takeSlot(windowId: window.windowId, on: name),
           commitTilingRestoreFloatingSlot(windowId: window.windowId, slot: slot)
        {
            return
        }
        _ = commitTilingPlaceNewWindow(id: window.windowId)
    }
}
