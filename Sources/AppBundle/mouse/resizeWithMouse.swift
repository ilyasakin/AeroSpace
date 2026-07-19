import AppKit
import Common

/// High-rate mouse-resize driver paced by **`WorkspaceDisplayLink`** on the workspace’s screen.
///
/// Policy: frame-bound work uses `DisplayRefresh` for the workspace host display — never a
/// hard-coded 60 Hz. See `DisplayRefresh.swift`.
///
/// Per vsync of that display:
/// 1. Sample the drag target’s live frame (WindowServer overlay bounds)
/// 2. Update tile weights from the drag-start baseline
/// 3. Layout **only** that workspace (tiling only — skip floating)
/// 4. Sync borders from layout rects
@MainActor
enum MouseResizeDriver {
    private static var target: Window?
    private static var busy = false
    private static var lastLive: Rect?
    private static let subscriptionId = UUID()
    private static var subscribedDisplayId: CGDirectDisplayID?
    /// Nominal Hz of the active workspace display (diagnostics).
    private(set) static var activeRefreshHz: Double = DisplayRefresh.fallbackHz

    /// Enter / continue a resize gesture. Safe to call from AX or WindowServer paths.
    static func kick(_ window: Window) {
        guard window.parent is TilingContainer else { return }
        currentlyManipulatedWithMouseWindowId = window.windowId
        target = window
        ensureSubscribed(for: window)
        // Immediate tick so the first edge move is not delayed one frame.
        scheduleTick()
    }

    /// WindowServer move/resize for the drag target — starts/continues the gesture; pacing is
    /// the workspace display link (not every WS event).
    static func noteWindowServerFrame(windowId: UInt32) {
        guard currentlyManipulatedWithMouseWindowId == windowId,
              let window = Window.get(byId: windowId),
              mouseResizePhysicalBaselineIfSet(for: window) != nil
              || window.lastAppliedLayoutPhysicalRect != nil
        else { return }
        kick(window)
    }

    static func stop() {
        target = nil
        lastLive = nil
        if let displayId = subscribedDisplayId {
            WorkspaceDisplayLink.unsubscribe(displayId: displayId, id: subscriptionId)
            subscribedDisplayId = nil
        }
        activeRefreshHz = DisplayRefresh.fallbackHz
    }

    private static func ensureSubscribed(for window: Window) {
        let displayId = DisplayRefresh.displayId(for: window)
            ?? window.nodeWorkspace.flatMap { DisplayRefresh.displayId(for: $0) }
            ?? CGMainDisplayID()
        activeRefreshHz = DisplayRefresh.hz(forDisplayId: displayId)

        if subscribedDisplayId == displayId { return }
        if let old = subscribedDisplayId {
            WorkspaceDisplayLink.migrate(
                id: subscriptionId,
                from: old,
                to: displayId,
                onPulse: { MouseResizeDriver.onDisplayPulse() },
            )
        } else {
            WorkspaceDisplayLink.subscribe(displayId: displayId, id: subscriptionId) {
                MouseResizeDriver.onDisplayPulse()
            }
        }
        subscribedDisplayId = displayId
        activeRefreshHz = WorkspaceDisplayLink.activeRefreshHz(for: displayId)
            ?? DisplayRefresh.hz(forDisplayId: displayId)
    }

    private static func onDisplayPulse() {
        guard target != nil else { return }
        scheduleTick()
    }

    private static func scheduleTick() {
        guard !busy, let window = target else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await tick(window)
        }
    }

    private static func tick(_ window: Window) async {
        guard currentlyManipulatedWithMouseWindowId == window.windowId else { return }
        guard window.parent is TilingContainer else { return }

        // Workspace may have moved monitors mid-drag — keep the link on the host display.
        ensureSubscribed(for: window)

        let live = liveRectForMouseResizeSync(window)
        if let live, live == lastLive { return }

        let weightsChanged = applyResizeWeights(window, live: live)
        lastLive = live
        guard weightsChanged else { return }

        guard let ws = window.nodeWorkspace else { return }
        do {
            try await ws.layoutWorkspace(skipFloating: true)
            WindowBordersManager.shared.syncAfterMouseLayout()
        } catch {
            return
        }
    }
}

// MARK: - AX entry (gesture start + fallback when WS notifies are quiet)

@MainActor
var resizeWithMouseTask: Task<(), any Error>? = nil // kept for move path cancel compatibility

/// Noise floor for move-vs-resize detection (floating precision + layout vs WS lag).
let mouseResizeNoiseThreshold: CGFloat = 5
/// Weight updates during drag — lower than move detection so siblings track the edge smoothly.
let mouseResizeWeightThreshold: CGFloat = 1

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard RunSessionGuard.isServerEnabled != nil else { return }
        let window = windowId.flatMap { Window.get(byId: $0) }
        guard let window else { return }

        let mouseResize: Bool
        do {
            mouseResize = try await isManipulatedWithMouse(window)
        } catch {
            return
        }

        if !mouseResize {
            (window as? MacWindow)?.invalidateAxFrameCaches()
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }

        moveWithMouseTask?.cancel()
        // Ensure WS delivers continuous resize events for this window (and siblings).
        ensureMouseResizeWindowServerNotifications(for: window)
        MouseResizeDriver.kick(window)
    }
}

@MainActor
private var mouseResizeWsEventsRegistered = false

@MainActor
func ensureMouseResizeWindowServerNotifications(for window: Window) {
    // Borders also register this; do it here so resize is smooth even with borders off.
    if !mouseResizeWsEventsRegistered {
        mouseResizeWsEventsRegistered = true
        SkyLight.registerWindowEvents(windowBordersEventProc)
    }
    var ids: [UInt32] = [window.windowId]
    if let parent = window.parent as? TilingContainer {
        for child in parent.children {
            if let w = child as? Window { ids.append(w.windowId) }
        }
    }
    // Include all bordered tiles so sibling WS events still paint; driver only reacts to target.
    ids.append(contentsOf: WindowBordersManager.shared.borderedWindowIds)
    SkyLight.requestNotifications(for: ids)
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        MouseResizeDriver.stop()
        FloatingBorderTracker.stop()
        for workspace in Workspace.allUnsorted {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")
/// Physical layout rect at drag start — edge diffs are vs live, while lastApplied tracks live layout.
private let mouseResizePhysicalBaselineKey = TreeNodeUserDataKey<Rect>(key: "mouseResizePhysicalBaselineKey")

func resizeWithMouseCanApplyDiffs(lastApplied: Rect?, live: Rect?) -> Bool {
    lastApplied != nil && live != nil
}

func isMouseResizeLikeDrag(lastApplied: Rect?, live: Rect?, threshold: CGFloat = mouseResizeNoiseThreshold) -> Bool {
    guard let lastApplied, let live else { return false }
    return abs(lastApplied.width - live.width) > threshold
        || abs(lastApplied.height - live.height) > threshold
}

/// Sync live frame (no await) — hot path for 60fps ticks.
@MainActor
func liveRectForMouseResizeSync(_ window: Window) -> Rect? {
    WindowServerReads.current.windowBounds(windowId: window.windowId, forOverlay: true)
}

@MainActor
func liveRectForMouseResize(_ window: Window) async throws -> Rect? {
    if let bounds = liveRectForMouseResizeSync(window) { return bounds }
    if let mac = window as? MacWindow {
        return try await mac.macApp.getAxRect(mac.windowId, .cancellable)
    }
    return try await window.getAxRect(.cancellable)
}

@MainActor
func mouseResizePhysicalBaselineIfSet(for window: Window) -> Rect? {
    window.getUserData(key: mouseResizePhysicalBaselineKey)
}

@MainActor
func mouseResizePhysicalBaseline(for window: Window) -> Rect? {
    if let cached = mouseResizePhysicalBaselineIfSet(for: window) { return cached }
    guard let baseline = window.lastAppliedLayoutPhysicalRect else { return nil }
    window.putUserData(key: mouseResizePhysicalBaselineKey, data: baseline)
    return baseline
}

/// Update tile weights from live vs drag-start baseline. Returns whether any weight changed.
@MainActor
@discardableResult
func applyResizeWeights(_ window: Window, live: Rect?) -> Bool {
    guard let rect = live else { return false }
    guard let baseline = mouseResizePhysicalBaseline(for: window) else { return false }
    guard resizeWithMouseCanApplyDiffs(lastApplied: baseline, live: rect) else { return false }

    let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
    let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
    let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
    let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
    let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
        (baseline.minX - rect.minX, lParent, 0,                        lOwnIndex),
        (rect.maxY - baseline.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count),
        (baseline.minY - rect.minY, uParent, 0,                        uOwnIndex),
        (rect.maxX - baseline.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count),
    ]

    var changed = false
    let ws = window.nodeWorkspace
    unsafe Workspace.suppressTilingGenerationInvalidation = true
    defer {
        unsafe Workspace.suppressTilingGenerationInvalidation = false
        if changed { ws?.invalidateTilingStructureGeneration() }
    }

    for (diff, parent, startIndex, pastTheEndIndex) in table {
        if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0
            && abs(diff) > mouseResizeWeightThreshold
        {
            let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
            let orientation = parent.orientation

            window.parentsWithSelf.lazy
                .prefix(while: { $0 != parent })
                .filter {
                    let parent = $0.parent as? TilingContainer
                    return parent?.orientation == orientation && parent?.layout == .tiles
                }
                .forEach {
                    $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff)
                    changed = true
                }
            for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                changed = true
            }
        }
    }
    currentlyManipulatedWithMouseWindowId = window.windowId
    return changed
}

/// Public entry used by tests and move-with-mouse fallback (weights only; caller layouts if needed).
@MainActor
func resizeWithMouse(_ window: Window) async throws {
    switch window.windowParentCases {
        case .tilingContainer:
            let live = try await liveRectForMouseResize(window)
            _ = applyResizeWeights(window, live: live)
            currentlyManipulatedWithMouseWindowId = window.windowId
        case .unbound, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation)
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        cleanUserData(key: mouseResizePhysicalBaselineKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
