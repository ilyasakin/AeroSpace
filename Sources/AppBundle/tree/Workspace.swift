import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]
/// Bumped when the workspace set gains/loses members so `Workspace.all` can reuse its sorted array
@MainActor private var workspaceListGeneration: UInt64 = 0
@MainActor private var sortedWorkspacesCache: (generation: UInt64, list: [Workspace])?

// Workspace<->monitor association is keyed on DISPLAY IDENTITY, never on geometry. Keying these on
// `rect.topLeftCorner` meant the key moved whenever displays were rearranged, a resolution changed,
// or a lid closed — and `rearrangeWorkspacesOnMonitors` then had to guess which old corner became
// which new corner by nearest-Euclidean distance, silently dropping a workspace on any collision.
// See `DisplayId`.
@MainActor private var displayToPrevVisibleWorkspace: [DisplayId: String] = [:]
@MainActor private var displayToVisibleWorkspace: [DisplayId: Workspace] = [:]
@MainActor private var visibleWorkspaceToDisplay: [Workspace: DisplayId] = [:]

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    getStubWorkspace(for: monitor.displayId)
}

@MainActor
private func getStubWorkspace(for display: DisplayId) -> Workspace {
    if let prev = displayToPrevVisibleWorkspace[display].map({ Workspace.get(byName: $0) }),
       !prev.isScratchpad,
       !prev.isVisible && prev.workspaceMonitor.displayId == display && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    // Prefer the alphabetically first match (same as the old Workspace.all.first(where:) path).
    // Scan allUnsorted so we don't re-sort the whole set; still O(n) and stable if two parked
    // workspaces share a monitor.
    var best: Workspace?
    for candidate in Workspace.allUnsorted
        where !candidate.isVisible && !candidate.isScratchpad && candidate.workspaceMonitor.displayId == display
    {
        if best.map({ candidate < $0 }) ?? true { best = candidate }
    }
    if let best { return best }
    return (1 ... Int.max).lazy
        .map { Workspace.get(byName: String($0)) }
        .first { $0.isEffectivelyEmpty && !$0.isVisible && !config.persistentWorkspaces.contains($0.name) && $0.forceAssignedMonitor == nil }
        .orDie("Can't create empty workspace")
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    let name: String
    nonisolated private let nameLogicalSegments: StringLogicalSegments
    /// `assignedDisplay` must be interpreted only when the workspace is invisible
    fileprivate var assignedDisplay: DisplayId? = nil

    /// Session restore: re-pin an invisible workspace to its saved monitor. Without this every
    /// non-visible workspace fell back to the main monitor after a restart on multi-monitor.
    @MainActor
    func assignDisplayForSessionRestore(_ display: DisplayId) {
        assignedDisplay = display
    }
    /// Set by the tiling-policy command. nil means "follow the config"
    var tilingPolicyOverride: TilingPolicy? = nil
    /// Runtime `gaps current ...` changes (see GapsOverride)
    var gapsOverride = GapsOverride()

    @MainActor
    private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    /// Sorted by name. Use for UI/CLI listing. Hot-path iterate-all callers should prefer `allUnsorted`.
    /// The sorted array is cached until a workspace is created or GC'd (membership change only —
    /// name order is stable for the lifetime of each Workspace instance)
    /// Every workspace a user sees or cycles through — excludes the hidden scratchpad
    @MainActor static var userFacing: [Workspace] { all.filter { !$0.isScratchpad } }

    var isScratchpad: Bool { name == scratchpadWorkspaceName }

    @MainActor static var all: [Workspace] {
        if let cached = sortedWorkspacesCache, cached.generation == workspaceListGeneration {
            return cached.list
        }
        let list = workspaceNameToWorkspace.values.sorted()
        sortedWorkspacesCache = (workspaceListGeneration, list)
        return list
    }

    /// Unsorted view for callers that just iterate every workspace (refresh/normalize/gc/layout).
    /// Avoids the O(n log n) sort with the StringLogicalSegments comparator on every access
    @MainActor static var allUnsorted: some Collection<Workspace> {
        workspaceNameToWorkspace.values
    }

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            workspaceNameToWorkspace[name] = workspace
            workspaceListGeneration &+= 1
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        tilingRect.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        let before = workspaceNameToWorkspace.count
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
        if workspaceNameToWorkspace.count != before {
            workspaceListGeneration &+= 1
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToDisplay.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        // Exact identity match, then the saved assignment, then main. Previously these two middle
        // steps were `monitorApproximation` over a stored POINT — nearest-monitor-to-a-coordinate —
        // so a display that moved handed the workspace to whichever monitor was now closest.
        forceAssignedMonitor
            ?? visibleWorkspaceToDisplay[self]?.monitor
            ?? assignedDisplay?.monitor
            ?? mainMonitor
    }
}

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = displayToVisibleWorkspace[displayId] {
            return existing
        }
        // What if the monitor set changed? (a display appeared or disappeared)
        rearrangeWorkspacesOnMonitors()
        if let existing = displayToVisibleWorkspace[displayId] { return existing }
        // This display isn't in the current monitor set (asleep / just unplugged, or no screens at
        // all): give it a stub directly. Recursing here never terminated when `monitors` was empty.
        let stub = getStubWorkspace(for: displayId)
        _ = displayId.setActiveWorkspace(stub)
        return stub
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        displayId.setActiveWorkspace(workspace)
    }
}

@MainActor
func gcMonitors() {
    // Compare the SET of displays: swapping one display for another (a different dock / KVM
    // target) keeps the count and used to keep a mapping keyed on a display that is gone
    if Set(displayToVisibleWorkspace.keys) != Set(monitors.map(\.displayId)) {
        rearrangeWorkspacesOnMonitors()
        // The focused workspace's display went away: like i3 moving a gone output's workspaces to
        // a remaining one, keep it focused and SHOW it (on its fallback monitor) — otherwise focus
        // stayed on an invisible workspace and typing went to a window parked in the corner.
        // (setActiveWorkspace directly: focusWorkspace() is a no-op when the focus value is unchanged)
        let focused = focus.workspace
        if !focused.isVisible, !focused.isScratchpad {
            _ = focused.workspaceMonitor.setActiveWorkspace(focused)
        }
    }
}

extension DisplayId {
    /// The monitor with this identity, if it is currently connected.
    @MainActor var monitor: Monitor? { monitors.first { $0.displayId == self } }

    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, display: self) {
            return false
        }
        if let prevDisplay = visibleWorkspaceToDisplay[workspace] {
            visibleWorkspaceToDisplay.removeValue(forKey: workspace)
            displayToPrevVisibleWorkspace[prevDisplay] =
                displayToVisibleWorkspace.removeValue(forKey: prevDisplay)?.name
        }
        if let prevWorkspace = displayToVisibleWorkspace[self] {
            displayToPrevVisibleWorkspace[self] =
                displayToVisibleWorkspace.removeValue(forKey: self)?.name
            visibleWorkspaceToDisplay.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToDisplay[workspace] = self
        displayToVisibleWorkspace[self] = workspace
        workspace.assignedDisplay = self
        return true
    }
}

/// Re-establish the display→visible-workspace association after the monitor set changes.
///
/// Identity makes this trivial: a display that is still connected keeps its workspace, because it is
/// the SAME key. There is nothing to guess and nothing to drop.
///
/// The previous version had to guess. Keyed on top-left corners, it mapped each old corner to the
/// nearest new corner, and when two old corners resolved to one new corner it discarded the loser
/// with a bare `continue` — so on any rearrangement that collapsed coordinates (unplugging a
/// display, mirroring, a resolution change that shifted origins) a visible workspace lost its
/// monitor and fell back to main. Workspaces that were merely INVISIBLE were never remapped at all,
/// which is why parked workspaces collected on the main display after a topology change.
@MainActor
private func rearrangeWorkspacesOnMonitors() {
    let connected = monitors.map(\.displayId)
    let previous = displayToVisibleWorkspace
    displayToVisibleWorkspace = [:]
    visibleWorkspaceToDisplay = [:]
    // A display that went away remembers what it showed, so re-plugging it (sleep, KVM, dock)
    // brings THAT workspace back instead of an older one
    for (display, workspace) in previous where !connected.contains(display) {
        displayToPrevVisibleWorkspace[display] = workspace.name
    }

    for display in connected {
        // Still connected → same identity → keeps its workspace.
        if let existing = previous[display], display.setActiveWorkspace(existing) {
            continue
        }
        let stub = getStubWorkspace(for: display)
        check(display.setActiveWorkspace(stub),
              "getStubWorkspace generated incompatible stub workspace (\(stub)) for the monitor (\(display))")
    }

    // A workspace pinned to a display that is now GONE keeps its assignment rather than being
    // silently re-homed: if the display comes back (sleep, KVM switch, re-plug) the workspace
    // returns to it. `workspaceMonitor` already falls back to main for as long as it is absent.
}

@MainActor
private func isValidAssignment(workspace: Workspace, display: DisplayId) -> Bool {
    // The scratchpad is never shown (i3's __i3_scratch)
    if workspace.isScratchpad { return false }
    return switch workspace.forceAssignedMonitor {
        case let forceAssigned? where forceAssigned.displayId != display: false
        default: true
    }
}

extension Workspace {
    /// i3 `rename workspace <old> to <new>`: a new workspace object takes over everything — the
    /// windows (all containers move as they are), the monitor, the focus and back-and-forth memory,
    /// and the runtime per-workspace settings. Fails if `newName` is taken (as in i3).
    @MainActor func rename(to newName: String) -> Bool {
        if newName == name { return true }
        if workspaceNameToWorkspace[newName] != nil { return false }
        let renamed = Workspace.get(byName: newName)
        for (index, child) in children.enumerated() {
            child.unbindFromParent()
            child.bind(to: renamed, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: index)
        }
        renamed.tilingPolicyOverride = tilingPolicyOverride
        renamed.gapsOverride = gapsOverride
        renamed.assignedDisplay = assignedDisplay
        if let display = visibleWorkspaceToDisplay[self] {
            _ = display.setActiveWorkspace(renamed)
        }
        for (display, prev) in displayToPrevVisibleWorkspace where prev == name {
            displayToPrevVisibleWorkspace[display] = newName
        }
        noteWorkspaceRenamed(from: name, to: newName)
        renameNameKeyedWorkspaceState(from: name, to: newName)
        workspaceNameToWorkspace.removeValue(forKey: name)
        workspaceListGeneration &+= 1
        return true
    }
}

/// Everything outside the workspace object that refers to a workspace by NAME. Rename used to move
/// only focus and the monitor: departed/floated windows, the special workspace toggle and session
/// restore still pointed at a workspace that no longer existed.
/// (Step 6 of the re-architecture merges these memories into one; until then, one place.)
@MainActor private func renameNameKeyedWorkspaceState(from old: String, to new: String) {
    WindowMemory.renameWorkspace(from: old, to: new)
    SpecialWorkspaceToggleState.renameWorkspace(from: old, to: new)
    for workspace in Workspace.allUnsorted {
        for window in workspace.allLeafWindowsRecursive where window.tileRestoreSlot?.workspaceName == old {
            window.tileRestoreSlot?.workspaceName = new
        }
    }
}
