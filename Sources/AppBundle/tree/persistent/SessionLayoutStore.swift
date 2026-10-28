import AppKit
import Common
import Foundation

/// Bump when the on-disk session shape changes in a way older builds cannot read. Adding OPTIONAL
/// fields (as the stable monitor key did) is backward compatible and does NOT need a bump.
///
/// Not inside `SessionLayoutStore` because the DTO is nonisolated and cannot read a `@MainActor`
/// static as a property default.
let sessionLayoutFormatVersion = 1

/// Disk-backed session layout so tiling structure + workspace placement survive AeroSpace restarts
/// (while apps stay open — CGWindowIDs remain valid for the WindowServer lifetime of each window).
///
/// Format is a versioned JSON of the persistent spine already used for in-memory TreeHistory.
@MainActor
enum SessionLayoutStore {
    private static let fileName = "session-layout.json"
    /// Set when we declined to read a file written by a newer build. Preserves it, so downgrading and
    /// re-upgrading does not lose a session. Sticky for the process: once we know the file on disk is
    /// newer than us, nothing this process does should touch it.
    private static var refuseToOverwrite = false

    static func resetFormatGuardForTests() { refuseToOverwrite = false }
    /// Tests: a fresh process's store (a restore in one test armed the grace for the next)
    static func resetForTests() {
        refuseToOverwrite = false
        pendingSave?.cancel()
        pendingSave = nil
        lastSavedStructural = nil
        startupGraceActive = false
        graceStartedAt = 0
        retryPending = false
        lastSavedWindowCount = 0
    }
    private static var pendingSave: DispatchWorkItem?
    private static var pendingExpiry: DispatchWorkItem?
    private static var lastSavedStructural: PersistentWorldSnapshot?

    /// Saved windows not claimed by a live one at restore time go to `WindowMemory`: discovery can
    /// race restore (slow AX at startup), and after a reboot the ids are all new (matched by app)
    private static func armPendingPlacements(_ snap: PersistentWorldSnapshot, savedApps: [UInt32: String], liveIds: Set<UInt32>) {
        var placements: [(savedId: UInt32, workspace: String, app: String?)] = []
        for ws in snap.workspaces {
            let ids = collectWindowIds(ws.rootTiling) + ws.floatingWindowIds + ws.unconventionalWindowIds
            for id in ids where !liveIds.contains(id) {
                placements.append((id, ws.name, savedApps[id]))
            }
        }
        WindowMemory.rememberLastSession(placements)
        armStartupGrace()
    }

    /// Arm the no-save window + expiry. Called for BOTH restore outcomes — a failed restore
    /// (AeroSpace launched before the apps; zero id overlap) must not let the first discovery
    /// save overwrite the good session file with "everything on the focused workspace".
    private static func armStartupGrace(restarting: Bool = false) {
        startupGraceActive = true
        if !restarting { graceStartedAt = ProcessInfo.processInfo.systemUptime }
        pendingExpiry?.cancel()
        let work = DispatchWorkItem {
            Kernel.submit("session store grace expired") {
                // While the screen is locked or a native-fullscreen Space is showing, macOS lists
                // (almost) no other windows over AX: the saved ones can't have come back yet.
                // Giving up then dumped every window on the focused workspace once they did.
                if MacOS.current.isScreenLocked || MacOS.current.isOnFullscreenSpace {
                    armStartupGrace(restarting: true)
                    return
                }
                WindowMemory.forgetLastSession()
                retryPending = false
                startupGraceActive = false
                saveNow() // first trusted save: the settled post-grace state
            }
        }
        pendingExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private static func collectWindowIds(_ node: PersistentTilingNode) -> [UInt32] {
        switch node {
            case .window(let id, _): [id]
            case .container(_, _, _, let children, _): children.flatMap { collectWindowIds($0) }
        }
    }

    /// Via AppSupportDir so a test can never resolve to the developer's live session file.
    static var fileUrl: URL { AppSupportDir.file(fileName) }

    /// True while startup discovery may still be racing restore. Saving during this window can
    /// capture a half-restored state and overwrite a good session file — the oscillating
    /// "windows dumped on first workspace" loop. Cleared with the pending-placement grace.
    private static var startupGraceActive = false
    private static var graceStartedAt: Double = 0
    /// Restore found zero overlap (apps slower than AeroSpace at login) — retry on later
    /// discoveries during the grace window instead of giving up for the whole session.
    private static var retryPending = false

    /// Called from the session pipeline after discovery heavies. Retries a failed startup restore
    /// once windows have actually appeared (restore used to be strictly one-shot).
    static func retryRestoreIfPending() {
        guard retryPending, startupGraceActive else { return }
        // Every heavy during the grace retries; decode the file once, not once per heavy (saves
        // are blocked during the grace, so the file can't change underneath)
        if cachedLoadForRetry == nil { cachedLoadForRetry = load() }
        if restoreIfPossible(preloaded: cachedLoadForRetry) {
            retryPending = false
            cachedLoadForRetry = nil
        }
    }

    private static var cachedLoadForRetry: (snapshot: PersistentWorldSnapshot, apps: [UInt32: String])? = nil

    /// Debounced save after structural changes (layout sessions).
    static func scheduleSave() {
        if refuseToOverwrite { return }
        if startupGraceActive { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            // A job: the save snapshots the whole tree, which must not be caught mid-session
            Kernel.submit("session store save") { saveNow(writeInBackground: true) }
        }
        pendingSave = work
        // 2s: every workspace switch changes the structure, and a save used to land 0.4s after the
        // last one — right when the next hotkey tends to arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceSeconds, execute: work)
    }

    static let saveDebounceSeconds: Double = 2.0
    /// Serial so writes land in submission order
    private static let writeQueue = DispatchQueue(label: "bobko.aerospace.session-store", qos: .utility)

    /// Capture now; with `writeInBackground`, JSON-encode and write off the main thread. Quit /
    /// SIGTERM passes false: the process may exit right after, so the write must be done.
    static func saveNow(writeInBackground: Bool = false) {
        // Never overwrite a session written by a newer build (see `load`).
        if refuseToOverwrite { return }
        // Quitting mid-grace: the tree may be half-restored — keep the last good file. But a
        // hard 60s blackout also meant sub-60s restart cycles (config iteration) silently lost
        // every change; after 15s the state is settled enough that keeping it beats dropping it.
        if startupGraceActive, ProcessInfo.processInfo.systemUptime - graceStartedAt < 15 { return }
        pendingSave?.cancel()
        pendingSave = nil
        // Quit path: let a queued background write land before comparing against it
        if !writeInBackground { writeQueue.sync {} }
        let snap = PersistentWorldSnapshot.captureLive()
        if snap.windowIds.isEmpty {
            return
        }
        // While the screen is locked or a native-fullscreen Space shows, macOS hides most windows
        // from AX: a snapshot then is a world with most windows "gone". Saving it destroyed a real
        // layout (a relaunch while on a fullscreen Space wrote every workspace empty)
        if snap.windowIds.count * 2 < lastSavedWindowCount,
           MacOS.current.isScreenLocked || MacOS.current.isOnFullscreenSpace
        {
            return
        }
        // Weights count now: they are the model's (layout used to rewrite them every pass, which is
        // why only structure was compared — and resizes were never saved)
        if let last = lastSavedStructural, last == snap {
            return
        }
        let url = fileUrl
        var dto = SessionLayoutDTO(from: snap)
        dto.apps = appIds(for: snap.windowIds) // reboot-survival matching (ids die with the WS session)
        lastSavedStructural = snap
        lastSavedWindowCount = snap.windowIds.count
        let write = { @Sendable [dto] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                rotateBackups(of: url)
                let data = try JSONEncoder().encode(dto)
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort — never crash the WM on save failure; forget the snapshot so the
                // next save retries instead of short-circuiting on "unchanged"
                Task.startUnstructured { @MainActor in lastSavedStructural = nil }
            }
        }
        if writeInBackground {
            writeQueue.async(execute: write)
        } else {
            write()
        }
    }

    /// How many windows the session file holds (from the last load or save)
    private static var lastSavedWindowCount = 0

    /// How many earlier session files are kept beside the current one (`.1` newest)
    nonisolated static let backupCount = 5

    /// A bad save must be recoverable: keep the previous files
    private nonisolated static func rotateBackups(of url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        func backup(_ n: Int) -> URL { url.appendingPathExtension(String(n)) }
        try? fm.removeItem(at: backup(backupCount))
        for n in stride(from: backupCount - 1, through: 1, by: -1) where fm.fileExists(atPath: backup(n).path) {
            try? fm.moveItem(at: backup(n), to: backup(n + 1))
        }
        try? fm.copyItem(at: url, to: backup(1))
    }

    /// Wait for queued background writes (tests)
    static func flushWritesForTests() { writeQueue.sync {} }

    /// windowId → app bundle id for every live saved window (sync; no AX).
    private static func appIds(for ids: Set<UInt32>) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            if let app = Window.get(byId: id)?.app.rawAppBundleId {
                out[String(id)] = app
            }
        }
        return out
    }

    static func load() -> (snapshot: PersistentWorldSnapshot, apps: [UInt32: String])? {
        let url = fileUrl
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(SessionLayoutDTO.self, from: data)
        else { return nil }
        // The format has carried a `version` field since it was written, and nothing ever READ it.
        // A future format change therefore had no way to announce itself, and a DOWNGRADE was the
        // dangerous direction: an older build would decode a newer file as best it could, then save
        // over it, destroying a layout that upgrading again would otherwise have recovered.
        // Newer-than-known is refused, and `refuseToOverwrite` then stops the save path clobbering
        // it. Older is accepted — new fields are optional precisely so old files still load.
        if dto.version > sessionLayoutFormatVersion {
            refuseToOverwrite = true
            return nil
        }
        var apps: [UInt32: String] = [:]
        for (key, value) in dto.apps ?? [:] {
            if let id = UInt32(key) { apps[id] = value }
        }
        return (dto.toSnapshot(), apps)
    }

    /// Rebuild live tree from the last session snapshot for any windows that still exist.
    /// Returns true if at least one workspace was restored.
    @discardableResult
    static func restoreIfPossible(preloaded: (snapshot: PersistentWorldSnapshot, apps: [UInt32: String])? = nil) -> Bool {
        guard let (rawSnap, savedApps) = preloaded ?? load() else { return false }
        lastSavedWindowCount = max(lastSavedWindowCount, rawSnap.windowIds.count)
        let liveIds = Workspace.all.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
        // After reboot/login all CGWindowIDs are new — translate stale saved ids to relaunched
        // windows of the same app so the layout still comes back (see sessionRestoreIdTranslation).
        var savedWorkspaceById: [UInt32: String] = [:]
        for ws in rawSnap.workspaces {
            for id in collectWindowIds(ws.rootTiling) + ws.floatingWindowIds + ws.unconventionalWindowIds {
                savedWorkspaceById[id] = ws.name
            }
        }
        let translation = sessionRestoreIdTranslation(
            savedIds: rawSnap.windowIds,
            savedApps: savedApps,
            savedWorkspaceById: savedWorkspaceById,
            liveIds: liveIds,
            liveApp: { Window.get(byId: $0)?.app.rawAppBundleId },
        )
        let snap = rawSnap.mappingWindowIds(translation)
        let overlap = snap.windowIds.intersection(liveIds)
        guard !overlap.isEmpty else {
            // Nothing matched yet — most often AeroSpace launched at login BEFORE the user's apps
            // (discovery found almost nothing). The grace must still arm: without it the first
            // discovery save overwrote the good session file with "everything on the focused
            // workspace" and the session was permanently destroyed. Retry as windows appear.
            // Arm once only — repeated failed retries must not extend the grace indefinitely.
            if !startupGraceActive {
                armStartupGrace()
            }
            retryPending = true
            return false
        }
        retryPending = false

        // Remember saved placements for windows discovery hasn't registered yet — late windows
        // consult these (MacWindow.getOrRegister) instead of defaulting to the focused workspace.
        var appsAfterTranslation: [UInt32: String] = [:]
        for (old, app) in savedApps {
            appsAfterTranslation[translation[old] ?? old] = app
        }
        armPendingPlacements(snap, savedApps: appsAfterTranslation, liveIds: liveIds)

        // Resolve a saved monitor by STABLE KEY first, geometry only as a fallback.
        //
        // This used to be geometry only, matched with exact CGPoint equality. Any difference in
        // display arrangement between sessions — a resolution change, displays waking in a different
        // order, a scaling change, an external monitor absent at login — matched NOTHING, so every
        // workspace fell through to the main monitor. That is the "everything ended up in the first
        // workspace after a restart" report.
        let monByKey: [String: Monitor] = Dictionary(
            monitors.map { ($0.persistentKey, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        let monByOrigin: [CGPoint: Monitor] = Dictionary(
            monitors.map { ($0.rect.topLeftCorner, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        func resolveMonitor(key: String?, topLeft: CGPoint) -> Monitor? {
            resolveSavedMonitor(key: key, topLeft: topLeft, byKey: monByKey, byOrigin: monByOrigin)
        }


        // Park every live tiling leaf floating so materialize can rebind by id (same as tests).
        // Track exactly which ids were parked: only THEY may be force-tiled as orphans later —
        // the old blanket force-tile also tiled auto-classified dialogs/fixed-size floats that
        // simply weren't in the snapshot, overriding the window-type decision.
        var parkedIds = Set<UInt32>()
        for workspace in Workspace.allUnsorted {
            for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
                parkedIds.insert(window.windowId)
                window.bindAsFloatingWindow(to: workspace)
            }
        }

        var restoredAny = false
        for wsSnap in snap.workspaces {
            let workspace = Workspace.get(byName: wsSnap.name)
            // Restore the workspace's monitor assignment (multi-monitor): without this every
            // invisible workspace fell through to the main monitor after a restart.
            if let mon = resolveMonitor(key: wsSnap.monitorKey, topLeft: wsSnap.monitorTopLeft) {
                workspace.assignDisplayForSessionRestore(mon.displayId)
            }
            if let filteredRoot = wsSnap.rootTiling.filteringWindows(keeping: liveIds) {
                workspace.materializeTilingSpine(filteredRoot)
                restoredAny = true
            }
            for id in wsSnap.floatingWindowIds where liveIds.contains(id) {
                Window.get(byId: id)?.bindAsFloatingWindow(to: workspace)
            }
        }

        // Monitor → visible workspace from last session
        for assignment in snap.monitorAssignments {
            if let mon = resolveMonitor(key: assignment.key, topLeft: assignment.topLeft) {
                _ = mon.setActiveWorkspace(Workspace.get(byName: assignment.workspace))
            }
        }

        // Parked tiling leaves that no snapshot spine claimed — put them back into tiling on
        // their current workspace. Non-parked floats (dialogs, user floats, fixed-size windows)
        // keep the classification/state they already had.
        for workspace in Workspace.allUnsorted {
            let spineIds = Set(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId))
            for window in workspace.floatingWindows
                where parkedIds.contains(window.windowId) && !spineIds.contains(window.windowId)
            {
                let wasFloating = snap.workspaces.contains { $0.floatingWindowIds.contains(window.windowId) }
                if !wasFloating {
                    _ = workspace.commitTilingPlaceNewWindow(id: window.windowId)
                }
            }
        }

        if restoredAny {
            lastSavedStructural = snap
            // The user is where macOS's focus is: the restore just moved that window back to its
            // saved workspace, and the model's focus must go with it. Left on the startup
            // workspace, its other window was pushed to macOS — a restart pulled the user off the
            // terminal they were typing in (before that, nobody moved and keys went to a parked one)
            if let id = FocusReconciler.record.observed, let window = Window.get(byId: id),
               window.nodeWorkspace != nil, !window.isOwnedByMacos
            {
                _ = window.focusWindow()
            }
            Workspace.garbageCollectUnusedWorkspaces()
        }
        return restoredAny
    }
}

// MARK: - Reboot survival: match stale saved ids to relaunched windows by app

/// CGWindowIDs die with the WindowServer session, so after a reboot/login the saved ids match
/// nothing and restore used to dump every window on the first workspace. Fallback: pair each
/// missing saved id with an unmatched live window of the SAME app, both sides in ascending-id
/// order (creation order within a session — apps recreate windows in a stable order). Pure and
/// unit-testable; ids that can't be paired stay unmapped and are filtered out later.
func sessionRestoreIdTranslation(
    savedIds: Set<UInt32>,
    savedApps: [UInt32: String],
    savedWorkspaceById: [UInt32: String] = [:],
    liveIds: Set<UInt32>,
    liveApp: (UInt32) -> String?,
) -> [UInt32: UInt32] {
    var map: [UInt32: UInt32] = [:]
    // CGWindowID counters restart at login, so a live id can NUMERICALLY collide with a dead
    // saved id of a different app. Raw intersection treated such collisions as "same window" and
    // spliced foreign windows into the saved layout. An id only counts as a direct match when the
    // app agrees (or the saved app is unknown — old session files).
    var appMismatched = Set<UInt32>()
    for id in savedIds.intersection(liveIds) {
        if let savedApp = savedApps[id], let currentApp = liveApp(id), savedApp != currentApp {
            appMismatched.insert(id)
        }
    }
    let missingSaved = savedIds.subtracting(liveIds).union(appMismatched)
    let unmatchedLive = liveIds.subtracting(savedIds).union(appMismatched)
    guard !missingSaved.isEmpty, !unmatchedLive.isEmpty else { return map }
    var savedByApp: [String: [UInt32]] = [:]
    for id in missingSaved {
        if let app = savedApps[id] { savedByApp[app, default: []].append(id) }
    }
    var liveByApp: [String: [UInt32]] = [:]
    for id in unmatchedLive {
        if let app = liveApp(id) { liveByApp[app, default: []].append(id) }
    }
    for (app, olds) in savedByApp {
        guard let news = liveByApp[app] else { continue }
        // Order-pairing is only sound when it can't shuffle windows ACROSS workspaces: ids carry
        // no cross-boot identity, so an app whose saved windows span several workspaces would get
        // them permuted (observed with terminals). Translate only single-workspace apps; the rest
        // fall to the late-discovery grace or fresh placement — unshuffled beats wrongly-shuffled.
        let workspaces = Set(olds.compactMap { savedWorkspaceById[$0] })
        guard workspaces.count <= 1 else { continue }
        for (old, new) in zip(olds.sorted(), news.sorted()) {
            map[old] = new
        }
    }
    // App-mismatched collision ids that found no re-pairing must still be EVICTED from the
    // snapshot (the raw id is live, so filtering alone would keep the foreign window). Map them
    // to a sentinel that is never live — they get filtered out downstream.
    for id in appMismatched where map[id] == nil {
        map[id] = 0
    }
    return map
}

extension PersistentTilingNode {
    /// Rewrite window ids through `map` (identity when unmapped). Structure untouched.
    func mappingWindowIds(_ map: [UInt32: UInt32]) -> PersistentTilingNode {
        switch self {
            case .window(let id, let weight):
                return .window(id: map[id] ?? id, weight: weight)
            case .container(let o, let l, let w, let children, _):
                return .container(orientation: o, layout: l, weight: w, children: children.map { $0.mappingWindowIds(map) })
        }
    }
}

extension PersistentWorldSnapshot {
    /// World snapshot with every window id rewritten through `map` (identity when unmapped).
    func mappingWindowIds(_ map: [UInt32: UInt32]) -> PersistentWorldSnapshot {
        guard !map.isEmpty else { return self }
        let ws = workspaces.map { w in
            PersistentWorkspaceSnapshot(
                name: w.name,
                monitorKey: w.monitorKey,
                monitorTopLeft: w.monitorTopLeft,
                visibleWorkspaceName: w.visibleWorkspaceName,
                rootTiling: w.rootTiling.mappingWindowIds(map),
                floatingWindowIds: w.floatingWindowIds.map { map[$0] ?? $0 },
                unconventionalWindowIds: w.unconventionalWindowIds.map { map[$0] ?? $0 },
            )
        }
        return PersistentWorldSnapshot(
            workspaces: ws,
            monitorAssignments: monitorAssignments,
            windowIds: Set(windowIds.map { map[$0] ?? $0 }),
        )
    }
}

// MARK: - Filter missing windows from spine

extension PersistentTilingNode {
    /// Drop window leaves not in `keeping`. Collapse empty containers; promote single-child containers.
    func filteringWindows(keeping: Set<UInt32>) -> PersistentTilingNode? {
        switch self {
            case .window(let id, let weight):
                return keeping.contains(id) ? .window(id: id, weight: weight) : nil
            case .container(let orientation, let layout, let weight, let children, _):
                let filtered = children.compactMap { $0.filteringWindows(keeping: keeping) }
                if filtered.isEmpty { return nil }
                // Keep a container shell so restore always materializes under Workspace → TilingContainer
                // (windows must not bind as direct workspace children).
                return .container(orientation: orientation, layout: layout, weight: weight, children: filtered)
        }
    }
}

extension PersistentWorldSnapshot {
    /// Structure equality ignoring floating order noise for save-dedup.
    func structureEquals(_ other: PersistentWorldSnapshot) -> Bool {
        guard windowIds == other.windowIds else { return false }
        guard workspaces.count == other.workspaces.count else { return false }
        for (a, b) in zip(workspaces, other.workspaces) {
            if a.name != b.name { return false }
            if !a.rootTiling.structureEquals(b.rootTiling) { return false }
            if a.floatingWindowIds != b.floatingWindowIds { return false }
        }
        return monitorAssignments.count == other.monitorAssignments.count &&
            zip(monitorAssignments, other.monitorAssignments).allSatisfy {
                $0.key == $1.key && $0.topLeft == $1.topLeft && $0.workspace == $1.workspace
            }
    }
}

// MARK: - JSON DTO

private struct SessionLayoutDTO: Codable {
    var version: Int = sessionLayoutFormatVersion
    var workspaces: [WorkspaceDTO]
    var monitors: [MonitorDTO]
    var windowIds: [UInt32]
    /// windowId (stringified) → app bundle id, for reboot-survival matching. Optional so files
    /// written before this field decode fine.
    var apps: [String: String]? = nil

    struct MonitorDTO: Codable {
        var x: Double
        var y: Double
        var workspace: String
        /// Reboot-stable display key. Optional so files written before it decode fine; restore
        /// prefers it and falls back to (x, y).
        var key: String? = nil
    }

    struct WorkspaceDTO: Codable {
        var name: String
        var monitorX: Double
        var monitorY: Double
        var root: NodeDTO
        var floating: [UInt32]
        var unconventional: [UInt32]
        /// Reboot-stable display key; optional for backward compatibility (see MonitorDTO.key).
        var monitorKey: String? = nil
    }

    indirect enum NodeDTO: Codable {
        case window(id: UInt32, weight: Double)
        case container(orientation: String, layout: String, weight: Double, children: [NodeDTO])

        enum CodingKeys: String, CodingKey {
            case type, id, weight, orientation, layout, children
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
                case "window":
                    self = .window(
                        id: try c.decode(UInt32.self, forKey: .id),
                        weight: try c.decode(Double.self, forKey: .weight),
                    )
                case "container":
                    self = .container(
                        orientation: try c.decode(String.self, forKey: .orientation),
                        layout: try c.decode(String.self, forKey: .layout),
                        weight: try c.decode(Double.self, forKey: .weight),
                        children: try c.decode([NodeDTO].self, forKey: .children),
                    )
                default:
                    throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: type)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
                case .window(let id, let weight):
                    try c.encode("window", forKey: .type)
                    try c.encode(id, forKey: .id)
                    try c.encode(weight, forKey: .weight)
                case .container(let o, let l, let w, let ch):
                    try c.encode("container", forKey: .type)
                    try c.encode(o, forKey: .orientation)
                    try c.encode(l, forKey: .layout)
                    try c.encode(w, forKey: .weight)
                    try c.encode(ch, forKey: .children)
            }
        }
    }

    init(from snap: PersistentWorldSnapshot) {
        workspaces = snap.workspaces.map { ws in
            WorkspaceDTO(
                name: ws.name,
                monitorX: ws.monitorTopLeft.x,
                monitorY: ws.monitorTopLeft.y,
                root: NodeDTO(ws.rootTiling),
                floating: ws.floatingWindowIds,
                unconventional: ws.unconventionalWindowIds,
                monitorKey: ws.monitorKey,
            )
        }
        monitors = snap.monitorAssignments.map {
            MonitorDTO(x: $0.topLeft.x, y: $0.topLeft.y, workspace: $0.workspace, key: $0.key)
        }
        windowIds = Array(snap.windowIds)
    }

    func toSnapshot() -> PersistentWorldSnapshot {
        let ws = workspaces.map { w in
            PersistentWorkspaceSnapshot(
                name: w.name,
                monitorKey: w.monitorKey,
                monitorTopLeft: CGPoint(x: w.monitorX, y: w.monitorY),
                visibleWorkspaceName: nil,
                rootTiling: w.root.toNode(),
                floatingWindowIds: w.floating,
                unconventionalWindowIds: w.unconventional,
            )
        }
        let assignments = monitors.map {
            (key: $0.key, topLeft: CGPoint(x: $0.x, y: $0.y), workspace: $0.workspace)
        }
        return PersistentWorldSnapshot(
            workspaces: ws,
            monitorAssignments: assignments,
            windowIds: Set(windowIds),
        )
    }
}

extension SessionLayoutDTO.NodeDTO {
    fileprivate init(_ node: PersistentTilingNode) {
        switch node {
            case .window(let id, let weight):
                self = .window(id: id, weight: Double(weight))
            case .container(let o, let l, let weight, let children, _):
                self = .container(
                    orientation: o == .h ? "h" : "v",
                    layout: l.rawValue,
                    weight: Double(weight),
                    children: children.map { SessionLayoutDTO.NodeDTO($0) },
                )
        }
    }

    fileprivate func toNode() -> PersistentTilingNode {
        switch self {
            case .window(let id, let weight):
                return .window(id: id, weight: CGFloat(weight))
            case .container(let o, let l, let weight, let children):
                let orientation: Orientation = o == "v" ? .v : .h
                let layout = Layout(rawValue: l) ?? .tiles
                return .container(
                    orientation: orientation,
                    layout: layout,
                    weight: CGFloat(weight),
                    children: children.map { $0.toNode() },
                )
        }
    }
}

/// Resolve a monitor recorded in a saved session to one that is connected now.
///
/// Pure and generic so the decision is testable without displays. The order is the whole point:
/// the reboot-stable key wins, and geometry is only a fallback for sessions written before the key
/// existed. Matching on geometry alone — which is what this did — used exact `CGPoint` equality, so
/// any change in display arrangement between sessions (a resolution change, displays waking in a
/// different order, a scaling change, an external display absent at login) resolved NOTHING and
/// every workspace fell through to the main monitor.
func resolveSavedMonitor<M>(
    key: String?,
    topLeft: CGPoint,
    byKey: [String: M],
    byOrigin: [CGPoint: M],
) -> M? {
    if let key, let match = byKey[key] { return match }
    return byOrigin[topLeft]
}
