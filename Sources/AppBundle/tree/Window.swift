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
    /// True only when the USER explicitly floated this window via `layout floating` (alt-shift-space).
    /// Auto-classified floats (dialogs, OAuth popups, panels bound to the floating container by
    /// window detection) are NOT user floats. The i3-style float quirks — click-without-raise
    /// interception and the float-layer settle — apply ONLY to user floats; everything else must
    /// behave exactly like a stock window (natural focus/raise/ordering).
    var isUserFloat: Bool = false
    /// i3-like floating toggle: when floated from tiling, remember neighbors so unfloat
    /// re-inserts without scrambling sibling order.
    var floatingRestoreSlot: FloatingRestoreSlot? = nil
    /// Exact workspace spine right before this window floated (window still included). When the
    /// spine is unchanged at unfloat time, restore materializes this verbatim — undoing the
    /// container flatten that removal triggered (neighbor slots can't reconstruct lost structure).
    var floatingRestorePreSpine: PersistentTilingNode? = nil
    /// Spine right after the float settled (window removed, containers normalized) — the
    /// "nothing changed while floating" comparison baseline.
    var floatingRestorePostSpine: PersistentTilingNode? = nil

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
///
/// Neighbors are the nearest **leaf** windows inside the adjacent sibling subtrees, plus how many
/// levels that leaf sits below the sibling root (`ascent`). A direct window sibling has ascent 0;
/// a container sibling records its edge leaf so restore can find the container again by walking
/// up from the leaf — direct-window-only capture used to bail to fallback placement whenever the
/// neighbor was a split or accordion group.
struct FloatingRestoreSlot: Equatable, Sendable {
    var workspaceName: String
    /// Nearest leaf window in the sibling subtree before this one (nil if first in parent).
    var neighborBeforeId: UInt32?
    /// Levels from that leaf up to the sibling subtree root (0 = the sibling is the window itself).
    var neighborBeforeAscent: Int
    /// Nearest leaf window in the sibling subtree after this one (nil if last in parent).
    var neighborAfterId: UInt32?
    var neighborAfterAscent: Int
    var weight: CGFloat

    /// Capture slot from a currently tiling window. Returns nil if not under a tiling container.
    @MainActor
    static func capture(from window: Window) -> FloatingRestoreSlot? {
        guard let parent = window.parent as? TilingContainer,
              let workspace = window.nodeWorkspace,
              let index = window.ownIndex
        else { return nil }
        let kids = parent.children
        let before = index > 0 ? edgeLeaf(kids[index - 1], last: true) : nil
        let after = index + 1 < kids.count ? edgeLeaf(kids[index + 1], last: false) : nil
        let weight = window.getWeight(parent.orientation)
        return FloatingRestoreSlot(
            workspaceName: workspace.name,
            neighborBeforeId: before?.id,
            neighborBeforeAscent: before?.ascent ?? 0,
            neighborAfterId: after?.id,
            neighborAfterAscent: after?.ascent ?? 0,
            weight: weight,
        )
    }

    /// Edge leaf window of a sibling subtree: the window itself (ascent 0), or the first/last
    /// leaf of a container with how many levels it sits below the subtree root.
    @MainActor
    private static func edgeLeaf(_ node: TreeNode, last: Bool) -> (id: UInt32, ascent: Int)? {
        if let window = node as? Window { return (window.windowId, 0) }
        var ascent = 0
        var current: TreeNode? = node
        while let container = current as? TilingContainer {
            guard let child = last ? container.children.last : container.children.first else { return nil }
            ascent += 1
            if let window = child as? Window { return (window.windowId, ascent) }
            current = child
        }
        return nil
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
