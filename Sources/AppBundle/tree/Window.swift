import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    /// Emulated: the window is re-raised on every focus change. See always-on-top command
    var isAlwaysOnTop: Bool = false
    /// The window follows the active workspace of its monitor. See sticky command
    var isSticky: Bool = false
    /// i3-like floating toggle: when floated from tiling, remember neighbors so unfloat
    /// re-inserts without scrambling sibling order.
    var floatingRestoreSlot: FloatingRestoreSlot? = nil

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor open func nativeFocus() { die("Not implemented") }
    /// Focus for keyboard without changing global z-order (no AXRaise).
    @MainActor open func nativeFocus(raise: Bool) { if raise { nativeFocus() } }
    /// Focus in the OS under the i3-like float contract (SIP on, no Dock SA).
    ///
    /// Contract:
    /// - Floating windows stay above the tiling stack for normal focus moves.
    /// - Focusing a tile never `AXRaise`s when the workspace has floats (no sink).
    /// - Uses private `_SLPSSetFrontProcessWithOptions` focus-without-raise when available
    ///   so CG z-order is unchanged (verified with SIP enabled).
    /// - Focusing a float may raise (normal stack among peers).
    /// - Durable foreign-window *levels* still require yabai's SA (SIP partial off); we do not.
    @MainActor func nativeFocusRespectingFloats() {
        let hasFloats = workspaceHasFloatingWindows
        let raise = FloatLayerPolicy.shouldRaiseOnFocus(isFloating: isFloating, workspaceHasFloats: hasFloats)
        // Tiles under floats: private focus-without-raise only. Do not AXRaise floats afterward —
        // that re-covers tiles and steals key focus (breaks click/keyboard on tiling).
        if FloatLayerPolicy.preferFocusWithoutRaise(isFloating: isFloating, workspaceHasFloats: hasFloats) {
            FloatLayer.focus(self, raise: false)
        } else {
            FloatLayer.focus(self, raise: raise)
        }
    }

    /// True when this window's workspace currently has at least one floating window.
    @MainActor var workspaceHasFloatingWindows: Bool {
        !(nodeWorkspace?.floatingWindows.isEmpty ?? true)
    }

    /// Raise the window to the top of the z-order without focusing it. Best-effort
    @MainActor func nativeRaise() {}
    /// Like `nativeRaise`, but returns only after the app has processed the raise —
    /// required when a make-key must be ordered strictly after it (float-layer settle).
    @MainActor func nativeRaiseAndWait() async { nativeRaise() }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

/// Snapshot of a window's place in the tiling tree when it is floated (i3 floating toggle).
struct FloatingRestoreSlot: Equatable, Sendable {
    var workspaceName: String
    /// Sibling window immediately before this one in the parent container (nil if first).
    var neighborBeforeId: UInt32?
    /// Sibling window immediately after this one (nil if last).
    var neighborAfterId: UInt32?
    var weight: CGFloat

    /// Capture slot from a currently tiling window. Returns nil if not under a tiling container.
    @MainActor
    static func capture(from window: Window) -> FloatingRestoreSlot? {
        guard let parent = window.parent as? TilingContainer,
              let workspace = window.nodeWorkspace,
              let index = window.ownIndex
        else { return nil }
        let kids = parent.children
        let before: UInt32? = index > 0 ? (kids[index - 1] as? Window)?.windowId : nil
        let after: UInt32? = index + 1 < kids.count ? (kids[index + 1] as? Window)?.windowId : nil
        let weight = window.getWeight(parent.orientation)
        return FloatingRestoreSlot(
            workspaceName: workspace.name,
            neighborBeforeId: before,
            neighborAfterId: after,
            weight: weight,
        )
    }
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
