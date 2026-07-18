import AppKit
import Common
import Foundation

/// Disk-backed session layout so tiling structure + workspace placement survive AeroSpace restarts
/// (while apps stay open — CGWindowIDs remain valid for the WindowServer lifetime of each window).
///
/// Format is a versioned JSON of the persistent spine already used for in-memory TreeHistory.
@MainActor
enum SessionLayoutStore {
    private static let fileName = "session-layout.json"
    private static var pendingSave: DispatchWorkItem?
    private static var lastSavedStructural: PersistentWorldSnapshot?

    static var fileUrl: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent(aeroSpaceAppId, isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Debounced save after structural changes (layout sessions).
    static func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Immediate save (quit / SIGTERM).
    static func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snap = PersistentWorldSnapshot.captureLive()
        if snap.windowIds.isEmpty {
            return
        }
        if let last = lastSavedStructural, last.structureEquals(snap) {
            return
        }
        do {
            let url = fileUrl
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dto = SessionLayoutDTO(from: snap)
            let data = try JSONEncoder().encode(dto)
            try data.write(to: url, options: .atomic)
            lastSavedStructural = snap
        } catch {
            // Best-effort — never crash the WM on save failure
        }
    }

    static func load() -> PersistentWorldSnapshot? {
        let url = fileUrl
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(SessionLayoutDTO.self, from: data)
        else { return nil }
        return dto.toSnapshot()
    }

    /// Rebuild live tree from the last session snapshot for any windows that still exist.
    /// Returns true if at least one workspace was restored.
    @discardableResult
    static func restoreIfPossible() -> Bool {
        guard let snap = load() else { return false }
        let liveIds = Workspace.all.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
        let overlap = snap.windowIds.intersection(liveIds)
        guard !overlap.isEmpty else { return false }

        let monByOrigin: [CGPoint: Monitor] = Dictionary(
            uniqueKeysWithValues: monitors.map { ($0.rect.topLeftCorner, $0) },
        )

        // Park every live tiling leaf floating so materialize can rebind by id (same as tests).
        for workspace in Workspace.allUnsorted {
            for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
                window.bindAsFloatingWindow(to: workspace)
            }
        }

        var restoredAny = false
        for wsSnap in snap.workspaces {
            let workspace = Workspace.get(byName: wsSnap.name)
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
            if let mon = monByOrigin[assignment.topLeft] {
                _ = mon.setActiveWorkspace(Workspace.get(byName: assignment.workspace))
            }
        }

        // Windows that never appeared in the snapshot stay where discovery put them (usually floating
        // on the focused workspace after the park step) — force-tile orphans onto their current workspace.
        for workspace in Workspace.allUnsorted {
            let spineIds = Set(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId))
            for window in workspace.floatingWindows where !spineIds.contains(window.windowId) {
                // Leave floating windows that were floating in the snapshot; force-tile unknown ones.
                let wasFloating = snap.workspaces.contains { $0.floatingWindowIds.contains(window.windowId) }
                if !wasFloating {
                    _ = workspace.commitTilingPlaceNewWindow(id: window.windowId)
                }
            }
        }

        if restoredAny {
            lastSavedStructural = snap
            Workspace.garbageCollectUnusedWorkspaces()
        }
        return restoredAny
    }
}

// MARK: - Filter missing windows from spine

extension PersistentTilingNode {
    /// Drop window leaves not in `keeping`. Collapse empty containers; promote single-child containers.
    func filteringWindows(keeping: Set<UInt32>) -> PersistentTilingNode? {
        switch self {
            case .window(let id, let weight):
                return keeping.contains(id) ? .window(id: id, weight: weight) : nil
            case .container(let orientation, let layout, let weight, let children):
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
                $0.topLeft == $1.topLeft && $0.workspace == $1.workspace
            }
    }
}

// MARK: - JSON DTO

private struct SessionLayoutDTO: Codable {
    var version: Int = 1
    var workspaces: [WorkspaceDTO]
    var monitors: [MonitorDTO]
    var windowIds: [UInt32]

    struct MonitorDTO: Codable {
        var x: Double
        var y: Double
        var workspace: String
    }

    struct WorkspaceDTO: Codable {
        var name: String
        var monitorX: Double
        var monitorY: Double
        var root: NodeDTO
        var floating: [UInt32]
        var unconventional: [UInt32]
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
            )
        }
        monitors = snap.monitorAssignments.map {
            MonitorDTO(x: $0.topLeft.x, y: $0.topLeft.y, workspace: $0.workspace)
        }
        windowIds = Array(snap.windowIds)
    }

    func toSnapshot() -> PersistentWorldSnapshot {
        let ws = workspaces.map { w in
            PersistentWorkspaceSnapshot(
                name: w.name,
                monitorTopLeft: CGPoint(x: w.monitorX, y: w.monitorY),
                visibleWorkspaceName: nil,
                rootTiling: w.root.toNode(),
                floatingWindowIds: w.floating,
                unconventionalWindowIds: w.unconventional,
            )
        }
        let assignments = monitors.map {
            (topLeft: CGPoint(x: $0.x, y: $0.y), workspace: $0.workspace)
        }
        return PersistentWorldSnapshot(
            workspaces: ws,
            monitorAssignments: assignments,
            windowIds: Set(windowIds),
        )
    }
}

private extension SessionLayoutDTO.NodeDTO {
    init(_ node: PersistentTilingNode) {
        switch node {
            case .window(let id, let weight):
                self = .window(id: id, weight: Double(weight))
            case .container(let o, let l, let weight, let children):
                self = .container(
                    orientation: o == .h ? "h" : "v",
                    layout: l.rawValue,
                    weight: Double(weight),
                    children: children.map { SessionLayoutDTO.NodeDTO($0) },
                )
        }
    }

    func toNode() -> PersistentTilingNode {
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
