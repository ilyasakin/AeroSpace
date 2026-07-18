import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var sponsorshipMessage: String = sponsorshipPrompts.randomElement().orDie()
    @Published var lastReloadConfigContainedWarnings: Bool = false
    @Published var axPermissionStatus: AxPermissionStatus = .waitingWithPrompt
}

enum AxPermissionStatus: Equatable {
    case granted
    case waiting
    case waitingWithPrompt
}

/// Cheap tray identity: what the menu-bar label actually depends on for hover focus.
/// (Per-window focus within the same workspace does not change the tray strip.)
struct TrayVisibleFingerprint: Equatable {
    var focusWorkspace: String
    var mode: String?
    var monitorActiveWorkspaces: [String]
}

/// Pure policy: FFM may skip the full leaf walk when visible tray state is unchanged.
func trayUpdateCanSkip(
    fullLeafWalk: Bool,
    previous: TrayVisibleFingerprint?,
    next: TrayVisibleFingerprint,
) -> Bool {
    !fullLeafWalk && previous == next
}

@MainActor private var lastTrayVisibleFingerprint: TrayVisibleFingerprint?

/// Rebuild tray label + menu models from the tree. Called from every light/heavy session, so it
/// must stay cheap: one leaf walk per workspace (not three), and skip @Published writes when
/// nothing changed (avoids SwiftUI view invalidation on no-op focus/AX refreshes).
///
/// - Parameter fullLeafWalk: When false (FFM), skip the full leaf walk unless the visible
///   workspace/mode fingerprint changed — hover within a workspace is a no-op for the tray.
@MainActor func updateTrayText(fullLeafWalk: Bool = true) {
    let sortedMonitors = sortedMonitors
    let focus = focus
    let multiMonitor = sortedMonitors.count > 1
    let fingerprint = TrayVisibleFingerprint(
        focusWorkspace: focus.workspace.name,
        mode: activeMode?.takeIf { $0 != mainModeId },
        monitorActiveWorkspaces: sortedMonitors.map(\.activeWorkspace.name),
    )
    if trayUpdateCanSkip(fullLeafWalk: fullLeafWalk, previous: lastTrayVisibleFingerprint, next: fingerprint) {
        return
    }
    lastTrayVisibleFingerprint = fingerprint

    // Single pass over sorted workspaces (menu order). Collect apps + fullscreen in one walk
    var workspaceModels: [WorkspaceViewModel] = []
    var fullscreenByName: [String: Bool] = [:]
    let allWorkspaces = Workspace.all
    workspaceModels.reserveCapacity(allWorkspaces.count)
    fullscreenByName.reserveCapacity(allWorkspaces.count)
    for workspace in allWorkspaces {
        var apps = Set<String>()
        var hasFullscreen = false
        for window in workspace.allLeafWindowsRecursive {
            if window.isFullscreen { hasFullscreen = true }
            if let name = window.app.name?.takeIf({ !$0.isEmpty }) {
                apps.insert(name)
            }
        }
        fullscreenByName[workspace.name] = hasFullscreen
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case workspace.isVisible: dash + workspace.workspaceMonitor.name
            default: ""
        }
        workspaceModels.append(WorkspaceViewModel(
            name: workspace.name,
            suffix: suffix,
            isFocused: focus.workspace == workspace,
            isEffectivelyEmpty: workspace.isEffectivelyEmpty,
            isVisible: workspace.isVisible,
            hasFullscreenWindows: hasFullscreen,
        ))
    }

    let trayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        sortedMonitors
        .map {
            let name = $0.activeWorkspace.name
            let hasFullscreen = fullscreenByName[name] ?? false
            let activeWorkspaceName = hasFullscreen ? "[\(name)]" : name
            return (multiMonitor && $0.activeWorkspace == focus.workspace ? "*" : "") + activeWorkspaceName
        }
        .joined(separator: " │ ")

    var items = sortedMonitors.map {
        TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: fullscreenByName[$0.activeWorkspace.name] ?? false,
        )
    }
    if let modeName = activeMode?.takeIf({ $0 != mainModeId })?.first {
        items.insert(
            TrayItem(type: .mode, name: modeName.uppercased(), isActive: true, hasFullscreenWindows: false),
            at: 0,
        )
    }

    let model = TrayMenuModel.shared
    // Only publish diffs — menu bar re-renders are visible jank on busy desktops
    if model.trayText != trayText { model.trayText = trayText }
    if model.workspaces != workspaceModels { model.workspaces = workspaceModels }
    if model.trayItems != items { model.trayItems = items }
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        switch Int(name) {
            case let number?: if !(0 ... 50).contains(number) { return nil }
            case nil where name.count == 1: if !validLetters.contains(name) { return nil }
            default: return nil
        }
        let lowercasedName = name.lowercased()
        return switch type {
            case .mode: "\(lowercasedName).circle"
            case .workspace where isActive: "\(lowercasedName).square.fill"
            case .workspace: "\(lowercasedName).square"
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
