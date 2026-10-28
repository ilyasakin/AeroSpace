import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    /// i3 fullscreen (CF_OUTPUT): at most one per workspace; persists until exited or until a
    /// different TILING window of the workspace is explicitly focused (`con_activate_unblock`)
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    /// Floating frame to restore when a fullscreen float exits fullscreen
    var floatingFrameBeforeFullscreen: Rect? = nil
    /// When the window joined the tree, and whether it was ever focused — a window opening behind
    /// a fullscreen window must not take focus from it (i3 manage.c: "not focusing")
    let registeredAt: Date = .now
    var hasEverBeenFocused = false
    /// i3 marks. A mark names at most one window (see `setMark`)
    var marks: [String] = []
    /// i3 scratchpad state: stays a scratchpad window while shown, until it is tiled again
    var isScratchpadWindow = false
    /// Indices of the `on-window-detected` callbacks that already ran for this window
    /// The `on-window-detected` rules that ran for this window — by content, not index: a config
    /// reload that inserted or reordered rules made indices point at other rules (new title rules
    /// skipped, old ones run twice)
    var ranDetectionCallbacks: [WindowDetectedCallback] = []
    /// Last known title (tab / stack titles). Kept fresh by kAXTitleChanged while it is shown
    var cachedTitle: String? = nil
    /// The title changed while it wasn't shown on a tab (see `refreshStaleTabTitles`)
    @MainActor var cachedTitleIsStale: Bool {
        get { staleTitleWindowIds.contains(windowId) }
        set { if newValue { staleTitleWindowIds.insert(windowId) } else { staleTitleWindowIds.remove(windowId) } }
    }
    var scratchpadWasShown = false
    var layoutReason: LayoutReason = .standard
    /// Emulated: the window is re-raised on every focus change. See always-on-top command
    var isAlwaysOnTop: Bool = false
    /// The window follows the active workspace of its monitor. See sticky command
    var isSticky: Bool = false
    /// Learned hard max size (e.g. System Settings caps its width ~723px). macOS exposes no
    /// max-size AX attribute, so this is discovered by observing the window refuse to grow to the
    /// size the tiling layout requested. `.infinity` in a dimension means "no cap there". Used by
    /// the tiles layout to stop reserving space the window can't fill (waterfillTileSpans).
    var learnedMaxSize: CGSize? = nil
    /// The request and answer that taught `learnedMaxSize` (see `reprobeLearnedCapIfSlotChanged`)
    var learnedCapEvidence: (target: Rect, actual: Rect)? = nil
    /// An own-size answer seen once (requested, answered). A cap needs the SAME answer for a
    /// DIFFERENT request: an aspect-locked video's height follows its width, a terminal rounds each
    /// size to its cell grid — neither is a maximum, and a one-off answer latched them as caps
    var capCandidate: (target: Rect, actual: Rect)? = nil
    /// True only when the USER explicitly floated this window via `layout floating` (alt-shift-space).
    /// Auto-classified floats (dialogs, OAuth popups, panels bound to the floating container by
    /// window detection) are NOT user floats. The i3-style float quirks — click-without-raise
    /// interception and the float-layer settle — apply ONLY to user floats; everything else must
    /// behave exactly like a stock window (natural focus/raise/ordering).
    /// Where this window's tile was when it left tiling — by the user floating it, or by macOS
    /// taking it (minimize, native fullscreen, app hide, parked native tab) — so it comes back to
    /// the same slot instead of beside the focused window (i3 never reorders on these round trips).
    /// Captured by `Workspace.captureTileRestorePoint`, consumed by `Workspace.restoreTile`.
    var tileRestoreSlot: FloatingRestoreSlot? = nil
    /// Exact workspace spine right before this window left tiling (window still included). When the
    /// spine is unchanged at restore time, restore materializes this verbatim — undoing the
    /// container flatten that removal triggered (neighbor slots can't reconstruct lost structure).
    var tileRestorePreSpine: PersistentTilingNode? = nil
    /// Spine right after the removal settled (window removed, containers normalized) — the
    /// "nothing changed meanwhile" comparison baseline.
    var tileRestorePostSpine: PersistentTilingNode? = nil
    /// Monotonic stamp of when the restore point was captured (0 = none); restores run LIFO
    var tileRestoreSequence: UInt64 = 0

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Every registered window, by id — the one registry, in production and under test alike (it
    /// used to be `MacWindow.allWindowsMap` in production and a separate test registry, chosen by
    /// `isUnitTest`, so the two environments resolved ids differently).
    @MainActor static var registry: [UInt32: Window] = [:]
    @MainActor static var all: [Window] { Array(registry.values) }

    @MainActor static func get(byId windowId: UInt32) -> Window? { registry[windowId] } // todo make non optional

    /// A command's request for this FLOATING window's frame — position and/or size — not yet
    /// applied. Commands state intent; the floating layout pass applies it (and clears it). Commands
    /// used to write frames directly, each with its own belief bookkeeping.
    var frameIntent: FrameIntent? = nil

    // MARK: - Frame / parking state (see WindowFrame.swift; step 3 folds it into the reconciler)

    /// Where the window was, as a fraction of its monitor, before it was parked in the hide corner
    var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?
    /// The corner the window is already parked in. Skips re-hiding an already hidden window on every
    /// refresh. Reset when the window moves externally (invalidateAxFrameCaches) so an escaped
    /// window gets re-hidden
    var hiddenCorner: OptimalHideCorner?
    /// Everything known about the window's frame (see `FrameRecord`): written, answered, reported
    var frame = FrameRecord() {
        didSet { Kernel.noteModelMutation("frame") }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    // MARK: - macOS, through the port

    /// Press the window's close button. It leaves the model once the app reports it gone.
    @MainActor func closeAxWindow() { MacOS.current.close(windowId) }
    @MainActor func getTitle(_ cm: CancellationMode) async throws -> String { try await MacOS.current.axTitle(windowId, cm) ?? "" }
    /// Both native-state attributes in one read. `nil` means the read FAILED (busy app, dying
    /// window) — which is not the same as "normal".
    @MainActor func readMacosNativeState(_ cm: CancellationMode) async throws -> MacosNativeWindowState? {
        try await MacOS.current.nativeState(windowId, cm)
    }
    @MainActor func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await readMacosNativeState(cm)?.isFullscreen == true }
    @MainActor func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await readMacosNativeState(cm)?.isMinimized == true }
    @MainActor func setNativeFullscreen(_ value: Bool) { MacOS.current.setNativeFullscreen(windowId, value) }
    @MainActor func setNativeMinimized(_ value: Bool) { MacOS.current.setNativeMinimized(windowId, value) }
    @MainActor func nativeFocus() {
        FrameTrace.log("native-focus \(windowId) parent=\(parent.map { "\(type(of: $0))" } ?? "nil")")
        MacOS.current.focus(windowId)
    }
    /// Focus in the OS.
    ///
    /// Floating windows get NATIVE macOS z-order: focusing a window raises it, like any other app.
    /// There used to be an i3-style float layer here — floats held above the tiling stack, tiles
    /// focused without raising via a private SLPS call, a click-interception tap re-posting
    /// synthetic events, and an awaited AXRaise settle pipeline. macOS offers no durable window
    /// level without yabai's SIP-off scripting addition, so the layer had to be re-asserted after
    /// every restack and drifted whenever anything else reordered windows. It was removed.
    @MainActor func nativeFocusRespectingFloats() {
        nativeFocus()
    }

    /// Keyboard focus without raising (hover only — see PrivateFocus). False = not possible here;
    /// the caller then raises normally.
    @MainActor func nativeFocusWithoutRaise(previousKeyWindowId: UInt32?) async -> Bool {
        await MacOS.current.focusWithoutRaise(windowId, previousKeyWindowId: previousKeyWindowId)
    }

    /// True when this window's workspace currently has at least one floating window.
    @MainActor var workspaceHasFloatingWindows: Bool {
        !(nodeWorkspace?.floatingWindows.isEmpty ?? true)
    }

    /// Raise the window to the top of the z-order without focusing it. Best-effort
    @MainActor func nativeRaise() { MacOS.current.raise(windowId) }
    /// Like `nativeRaise`, but returns only after the app has processed the raise
    @MainActor func nativeRaiseAndWait() async { await MacOS.current.raiseAndWait(windowId) }
    @MainActor func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }
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
    /// The window's share of its container (0…1). Not its raw weight: weights are proportions on a
    /// per-container scale (an old session's ~960 beside a new split's 1), so a raw weight restored
    /// into another container took the whole span or became a 50px sliver.
    var share: CGFloat

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
        let total = kids.reduce(CGFloat(0)) { $0 + max($1.getWeight(parent.orientation), 0) }
        let share = total > 0 ? max(window.getWeight(parent.orientation), 0) / total : 1 / CGFloat(kids.count)
        return FloatingRestoreSlot(
            workspaceName: workspace.name,
            neighborBeforeId: before?.id,
            neighborBeforeAscent: before?.ascent ?? 0,
            neighborAfterId: after?.id,
            neighborAfterAscent: after?.ascent ?? 0,
            share: share,
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

}

extension Window {
    /// i3 con_enable_fullscreen: the workspace's other fullscreen window (if any) exits first
    @MainActor func enterFullscreen(noOuterGaps: Bool) {
        if let ws = nodeWorkspace {
            for other in ws.allLeafWindowsRecursive where other !== self && other.isFullscreen {
                other.exitFullscreen()
            }
        }
        if isFloating, !isFullscreen {
            floatingFrameBeforeFullscreen = knownFrame ?? lastAppliedLayoutVirtualRect
        }
        isFullscreen = true
        noOuterGapsInFullscreen = noOuterGaps
        desiredRect = nil // next layout writes the fullscreen frame
    }

    @MainActor func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        desiredRect = nil // next layout writes the tile frame again
        if isFloating, let frame = floatingFrameBeforeFullscreen {
            if nodeWorkspace?.isVisible == true {
                requestFrame(topLeft: frame.topLeftCorner, size: CGSize(width: frame.width, height: frame.height))
            } else {
                // Hidden workspace: writing a frame would put it on screen; the unhide restores
                // its size, the hide corner keeps it parked meanwhile
                lastFloatingSize = CGSize(width: frame.width, height: frame.height)
            }
        }
        floatingFrameBeforeFullscreen = nil
    }

    /// The window focus must stay on instead of `self`: a fullscreen tiling window of the same
    /// workspace, when `self` is a tiling window that just opened and was never focused (i3 opens
    /// it behind the fullscreen window without focusing it)
    @MainActor var fullscreenWindowKeepingFocus: Window? {
        guard !hasEverBeenFocused, parent is TilingContainer, registeredAt.distance(to: .now) < 3,
              let ws = nodeWorkspace
        else { return nil }
        return ws.rootTilingContainer.allLeafWindowsRecursive.first { $0 !== self && $0.isFullscreen }
    }
}

extension Window {
    /// The window holding `mark`, if any
    @MainActor static func marked(_ mark: String) -> Window? {
        allWindowsForMarks.first { $0.marks.contains(mark) }
    }

    /// i3 `mark`: a mark is unique — taking it removes it from whichever window had it
    @MainActor func setMark(_ mark: String, add: Bool) {
        for other in Window.allWindowsForMarks where other !== self { other.marks.removeAll { $0 == mark } }
        if add {
            if !marks.contains(mark) { marks.append(mark) }
        } else {
            marks = [mark]
        }
    }

    /// Every registered window
    @MainActor static var allWindowsForMarks: [Window] { all }
}

extension Window {
    /// A native tab group occupies ONE tile, held by its lowest-id member; the other tabs are
    /// parked. When the tile holder goes away (its tab closed), the next tab becomes the holder —
    /// and must take over THIS tile, not be re-inserted beside the focused window as if new.
    /// Called right before the holder is unbound.
    @MainActor func handOverTileToParkedTabSibling() {
        guard parent is TilingContainer, let ws = nodeWorkspace, let slot = FloatingRestoreSlot.capture(from: self) else { return }
        let candidates = ws.macOsNativeHiddenAppsWindowsContainer.children
            .compactMap { $0 as? Window }
            .filter { $0.app.pid == app.pid && !$0.app.isHidden }
        // Two tab groups of one app: the heir is the tab that shares THIS tile's frame
        let myFrame = desiredRect ?? knownFrame
        let sameGroup = candidates.filter { c in
            guard let myFrame, let f = WindowServerReads.current.windowBounds(windowId: c.windowId, forOverlay: true) else { return false }
            return NativeTabDetection.rectsApproximatelyEqual(f, myFrame)
        }
        let heir = (sameGroup.isEmpty ? candidates : sameGroup).min { $0.windowId < $1.windowId }
        guard let heir else { return }
        heir.tileRestoreSlot = slot
        heir.tileRestorePreSpine = nil
        heir.tileRestorePostSpine = nil
    }
}
