import AppKit
import Common
import CoreGraphics

/// Per-window borders backed by raw SkyLight windows ordered above each target (JankyBorders model).
/// No overlay, no occlusion mask: the compositor keeps every border directly above its window, so a
/// border can never leak over a float or any other window stacked between them.
///
/// # Geometry has exactly one input
///
/// A border's rect is the window's frame **as WindowServer reports it now** (`liveFrame`) — never
/// layout intent (`desiredRect`), never what AeroSpace believes (`knownFrame`), never a pin. The model decides only
/// WHICH windows carry a border, their style, and z-order. Geometry is re-read whenever it may have
/// changed: WindowServer move/resize events (every managed window is subscribed), a frame write
/// being delivered, the post-write verification, the end of a mouse gesture, and every refresh.
///
/// Every earlier alternative source — belief right after our write, the layout target while a new
/// window animated in, the grid for drag siblings — was a guess, and each guess had its own expiry
/// rule; the mismatches (Apple TV flicker, frozen float rings, rings left behind on drop) were
/// those guesses disagreeing with the window. The cost of honesty is that a border shows a window's
/// own lag and entrance animation, exactly as the window does. `BorderGeometrySourceTest` keeps
/// intent and belief out of this file.
@MainActor
final class WindowBordersManager {
    static let shared = WindowBordersManager()
    private var entries: [UInt32: BorderWindow] = [:]
    /// Last painted rect per id — style/order refreshes reuse it without a fresh SLS read.
    private var rects: [UInt32: Rect] = [:]
    /// Per-window chrome class for corner-radius probes (plain vs toolbar). Filled async once.
    private var chromeCache: [UInt32: WindowCornerRadius.Chrome] = [:]
    /// Session-persistent chrome per app bundle id. Seeds a new window's *first* paint with the
    /// app's known chrome so it doesn't flash the .plain radius before the async probe corrects it
    /// — the flicker that hit every new window and every workspace return (per-window cache is
    /// cleared when a window leaves the visible set; this survives).
    private var chromeByApp: [String: WindowCornerRadius.Chrome] = [:]
    /// Windows with a chrome probe currently in flight (dedup — paint retries the probe each refresh
    /// while the border is deferred).
    private var probing: Set<UInt32> = []
    /// Per-window relative stack fingerprint from the last refresh (the id of the next layer-0
    /// window in front-to-back order). When it changes, the WindowServer restacked around this
    /// window and its border must re-order — reordering only floats missed tile restacks (stale
    /// rings over accordion cycles / cmd-tab raises); reordering everything flashed on click.
    private var lastStackNeighbor: [UInt32: UInt32] = [:]
    /// Fresh fingerprint computed at refresh() start; consumed by paint's reorder decision.
    private var currentStackNeighbor: [UInt32: UInt32] = [:]
    /// Window ids we have an outstanding WindowServer move/resize notify request for. Tracked so the
    /// request set can be diffed and withdrawn instead of growing for the whole session.
    private var notifiedWindowIds: Set<UInt32> = []


    private init() {}

    /// Full rebuild: driven from AeroSpace's refresh loop (focus / move / resize / layout /
    /// workspace change). Establishes which windows are bordered, their styles, and re-orders each
    /// border above its target.
    func refresh() {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        let cfg = config.windowBorders
        guard cfg.enabled, ServerState.isEnabled, WindowServerEvents.canDrawBorders else {
            teardownAll()
            return
        }
        // During startup, apps animate their windows into AeroSpace's layout over ~seconds and a
        // border faithfully tracks that motion — a visible slide/jump on every launch. Skip border
        // work until startup settles; the first post-startup refresh creates them in place.
        if isStartup { return }
        WindowServerEvents.startDelivering()
        invalidateOnScreenWindowSnapshot()
        computeStackNeighbors()

        var seen = Set<UInt32>(minimumCapacity: entries.count)
        for workspace in Workspace.allUnsorted where workspace.isVisible {
            // Borders must not paint over a native-fullscreen app on this display.
            if workspaceDisplayIsFullscreen(workspace) { continue }
            for window in workspace.allLeafWindowsRecursive {
                guard let rect = liveFrame(window.windowId) else { continue }
                seen.insert(window.windowId)
                paint(id: window.windowId, window: window, rect: rect, cfg: cfg, reorder: true, mayUnhide: true)
            }
        }
        for (id, entry) in entries where !seen.contains(id) {
            // Still alive (hidden workspace, momentarily unresolvable rect): keep it pooled
            if Window.get(byId: id) != nil, entries.count <= Self.maxPooledBorders {
                entry.hide()
            } else {
                entry.release()
                entries.removeValue(forKey: id)
            }
        }
        // Prune per-id state for anything out of the visible set — including ids that never got
        // an entry (chrome-probe deferral), which used to leak and resurrect ghost rings.
        for id in rects.keys where !seen.contains(id) { rects.removeValue(forKey: id) }
        // Chrome is a property of the window, not of being visible: kept until the window is gone
        // (dropping it on every workspace switch re-probed every window on every return)
        for id in chromeCache.keys where Window.get(byId: id) == nil { chromeCache.removeValue(forKey: id) }
        for id in lastStackNeighbor.keys where !seen.contains(id) { lastStackNeighbor.removeValue(forKey: id) }
        requestWindowServerNotifications()
    }

    /// Restyle + reorder existing borders after a focus change when the light session skipped a
    /// full `refresh()` (focus-follows-mouse, float click-without-raise). Reordering is what keeps
    /// each border glued above its window after a raise restacks the z-order.
    func syncActiveFocus() {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        let cfg = config.windowBorders
        guard cfg.enabled, ServerState.isEnabled, WindowServerEvents.canDrawBorders else { return }
        // Focus changes are when macOS restacks — refresh the stack fingerprint so tiles whose
        // z-position moved get re-ordered (and only those).
        invalidateOnScreenWindowSnapshot()
        computeStackNeighbors()
        for (id, _) in entries {
            guard let window = Window.get(byId: id) else { continue }
            guard let rect = liveFrame(id) ?? rects[id] else { continue }
            // Focus change restacked z-order — reassert each border above its target.
            paint(id: id, window: window, rect: rect, cfg: cfg, reorder: true)
        }
    }

    /// A window moved/resized (WindowServer event) — repaint only that window's own border.
    func handleWindowMoved(windowId: UInt32) {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        // Drag-target WS events start/continue mouse-resize; must run even when borders are off.
        MouseResizeDriver.noteWindowServerFrame(windowId: windowId)
        guard config.windowBorders.enabled, ServerState.isEnabled,
              entries[windowId] != nil, let window = Window.get(byId: windowId)
        else { return }
        if window.isFloating {
            FloatingBorderTracker.noteWindowServerNotify(windowId: windowId)
            FloatingBorderTracker.kick(window)
        }
        guard let rect = liveFrame(windowId) else { return }
        // Hot path: a moving window keeps its z-order, so skip the reorder IPC (~225µs/frame).
        paint(id: windowId, window: window, rect: rect, cfg: config.windowBorders, reorder: false)
    }

    /// Re-read this window's frame and repaint its border if it moved. For the moments a
    /// WindowServer event may not come: our write was just delivered (the event may have fired
    /// before we subscribed), a write was verified, a mouse gesture ended (the display-link sampler
    /// stops at mouse-up; a window at rest sends nothing more).
    func observe(windowId: UInt32) {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        guard config.windowBorders.enabled, ServerState.isEnabled, entries[windowId] != nil,
              let window = Window.get(byId: windowId),
              let live = liveFrame(windowId), live != rects[windowId]
        else { return }
        paint(id: windowId, window: window, rect: live, cfg: config.windowBorders, reorder: false)
    }

    /// Sample live bounds + paint for a floating drag target (display-link / immediate tick).
    func sampleFloatingBorder(windowId: UInt32) {
        Kernel.enterProjection()
        defer { Kernel.exitProjection() }
        guard config.windowBorders.enabled, ServerState.isEnabled, entries[windowId] != nil else { return }
        guard let window = Window.get(byId: windowId), let live = liveFrame(windowId) else { return }
        // Floating free-drag frame: geometry only, z-order unchanged.
        paint(id: windowId, window: window, rect: live, cfg: config.windowBorders, reorder: false)
    }

    /// Stop display-link floating border tracking (mouse-up).
    func stopFloatingBorderTracking() {
        FloatingBorderTracker.stop()
    }

    // MARK: - Paint

    /// Fingerprint each candidate window's position in the WindowServer's layer-0 stack as
    /// "the id in front of me". Our own border windows are already absent from `normalStack`.
    /// O(stack) per refresh.
    private func computeStackNeighbors() {
        currentStackNeighbor.removeAll(keepingCapacity: true)
        var prev: UInt32 = 0 // 0 = frontmost
        for item in onScreenWindowSnapshot().normalStack {
            currentStackNeighbor[item.id] = prev
            prev = item.id
        }
    }

    private func ensureEntry(_ id: UInt32) {
        if entries[id] == nil { entries[id] = BorderWindow(targetWid: id) }
    }

    /// Resolve style/radius/scale for `id` and (re)paint its border window. `reorder` reasserts the
    /// z-placement (create / focus / layout) and is skipped on the pure-move hot path.
    /// Upper bound on border windows kept alive (visible + pooled)
    static let maxPooledBorders = 128

    private func paint(id: UInt32, window: Window, rect: Rect, cfg: WindowBorders, reorder: Bool, mayUnhide: Bool = false) {
        // A pooled border stays hidden until a full refresh finds its window visible again: move
        // events of a window on a hidden workspace (hide-in-corner) must not resurrect its ring
        if !mayUnhide, entries[id]?.isHidden == true { return }
        // A window covering an entire display is fullscreen content (VLC non-native fullscreen
        // classified mid-transition as a float, or any window grown display-sized) — a ring around
        // it is noise. Release the SLS window but KEEP the entry: handleWindowMoved guards on
        // `entries`, so dropping it made the border unrecoverable until the next full refresh
        // (drag a float fullscreen-sized and back → ring gone for the rest of the gesture).
        // BorderWindow.update recreates the released window on the next non-covering paint.
        if rectCoversAnyDisplay(rect) {
            entries[id]?.release()
            rects[id] = rect
            return
        }
        let appId = window.app.rawAppBundleId
        // This window's probed chrome, else the app's known chrome from a prior probe.
        let knownChrome = chromeCache[id] ?? appId.flatMap { chromeByApp[$0] }
        // Radius depends on chrome (plain vs toolbar). If detection is on and the chrome is not yet
        // known, DEFER the border's first appearance until the async probe resolves — otherwise it
        // paints at the plain radius and visibly snaps to toolbar ~100ms later (the focus/switch
        // flicker). Cached chrome → paint immediately, no delay.
        if cfg.detectCornerRadius, knownChrome == nil {
            rects[id] = rect
            scheduleChromeProbe(window) // its completion calls paint() again with chrome known
            return
        }
        // Painted from the app's seed: still probe THIS window — an app's windows differ (Finder's
        // toolbar browser vs its plain Settings/panels), and the seed alone gave every later window
        // the first one's radius. Its completion repaints only if the radius was wrong.
        if cfg.detectCornerRadius, chromeCache[id] == nil { scheduleChromeProbe(window) }
        ensureEntry(id)
        guard let entry = entries[id] else { return }
        rects[id] = rect
        // Read from the model at paint time (the manager used to keep its own copy of focus): the
        // focused window, or every window of the focused container after `focus parent`
        let isActive = id == focus.windowOrNil?.windowId
            || focus.focusedNode?.allLeafWindowsRecursive.contains { $0.windowId == id } == true
        let style = isActive ? cfg.resolvedActiveStyle() : cfg.resolvedInactiveStyle()
        let radius = cfg.cornerRadius(forAppId: appId, chrome: knownChrome ?? .plain)
        // Reorder policy: floats reorder on request (they restack on raise). Tiles reorder only
        // when their WindowServer stack POSITION actually changed since the last refresh
        // (accordion cycle, cmd-tab raise) — reordering every tile on every refresh flashed on
        // click, and never reordering left stale rings over restacked windows.
        let stackChanged = currentStackNeighbor[id] != nil
            && lastStackNeighbor[id] != nil
            && currentStackNeighbor[id] != lastStackNeighbor[id]
        let needsReorder = reorder && (window.isFloating || stackChanged)
        // Commit the fingerprint only when the restack was actually ACTED on (or when there was
        // nothing to react to). Committing unconditionally swallowed restacks that happened while a
        // reorder was suppressed — the hot move path paints with `reorder: false` on every
        // WindowServer notify — so the next refresh compared
        // against the already-updated neighbor, concluded "no change", and left a stale ring
        // sitting under the window that had moved above it.
        if needsReorder || !stackChanged, let neighbor = currentStackNeighbor[id] {
            lastStackNeighbor[id] = neighbor
        }
        entry.update(
            rect: rect, width: cfg.width, radius: radius, style: style,
            scale: backingScale(forRect: rect), reorder: needsReorder,
        )
    }

    private func teardownAll() {
        for (_, entry) in entries { entry.release() }
        entries.removeAll()
        rects.removeAll()
        chromeCache.removeAll()
        probing.removeAll()
        lastStackNeighbor.removeAll()
        currentStackNeighbor.removeAll()
        // A live mouse gesture keeps its notifies (resize with borders off still needs them)
        let toRemove = notifiedWindowIds.subtracting(dragNotifiedWindowIds)
        if !toRemove.isEmpty {
            WindowServerEvents.remove(Array(toRemove))
            notifiedWindowIds = notifiedWindowIds.intersection(dragNotifiedWindowIds)
        }
        FloatingBorderTracker.stop()
    }

    // MARK: - Corner radius chrome probe

    /// Classify window chrome (toolbar vs plain) once so radius can track Tahoe's split.
    private func scheduleChromeProbe(_ window: Window) {
        let id = window.windowId
        guard !probing.contains(id) else { return } // one probe in flight per window
        probing.insert(id)
        let appId = window.app.rawAppBundleId
        Task { @MainActor in
            let chrome = await detectWindowChrome(window)
            probing.remove(id)
            // What the border was painted with (this window's probe, else the app's seed)
            let prev = chromeCache[id] ?? appId.flatMap { chromeByApp[$0] }
            chromeCache[id] = chrome
            if let appId { chromeByApp[appId] = chrome } // seed future windows of this app
            // Paint when the border was deferred waiting for this result (create), or when the
            // chrome actually changed (radius restyle). Deferred creates must ALSO still be in
            // the visible set — otherwise a workspace switch during the ~100ms probe resurrected
            // a ghost ring at the stale rect. And they must re-request WS notifications: the
            // border wasn't in `entries` when refresh subscribed, so without this the new border
            // never received move events (frozen border on the first window of every app).
            let deferredFirstPaint = entries[id] == nil
            if deferredFirstPaint {
                guard config.windowBorders.enabled, ServerState.isEnabled,
                      let workspace = window.nodeWorkspace, workspace.isVisible,
                      !workspaceDisplayIsFullscreen(workspace)
                else {
                    rects.removeValue(forKey: id)
                    return
                }
            }
            guard deferredFirstPaint || prev != chrome,
                  let rect = liveFrame(id) ?? rects[id]
            else { return }
            paint(id: id, window: window, rect: rect, cfg: config.windowBorders, reorder: deferredFirstPaint)
            if deferredFirstPaint {
                requestWindowServerNotifications()
            }
        }
    }

    private func detectWindowChrome(_ window: Window) async -> WindowCornerRadius.Chrome {
        // An AX flake answers false → plain probe radius
        await MacOS.current.windowHasToolbar(window.windowId) ? .toolbar : .plain
    }

    // MARK: - Geometry

    /// The only source of border geometry (see the type doc).
    private func liveFrame(_ windowId: UInt32) -> Rect? {
        WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true)
    }

    /// Tell WindowServer which windows we care about for move/resize notify delivery: every managed
    /// window, not just the bordered ones. A window that is about to become bordered (its workspace
    /// is being shown) is moved by our own layout write BEFORE the refresh that borders it — if it
    /// was subscribed only then, that move's event was already gone and the ring stayed where the
    /// window had been. Events for windows without a visible border are dropped in the handler.
    ///
    /// Diffed against the previous set, not re-requested wholesale: requests were never withdrawn,
    /// so every window that ever had a border kept pushing move/resize events for the rest of the
    /// session — the set only grew, and each event woke the handler just to be discarded.
    ///
    /// Always sends the FULL set. JankyBorders and yabai both re-send their whole window list to
    /// `SLSRequestNotificationsForWindows`, which suggests it replaces rather than adds; sending only
    /// the newly bordered ids would then have silenced every other window (a new Finder window was
    /// the only one whose ring tracked moves). The full set is correct under either reading.
    private func requestWindowServerNotifications() {
        let wanted = Set(Window.registry.keys).union(dragNotifiedWindowIds)
        guard wanted != notifiedWindowIds else { return }
        let removed = notifiedWindowIds.subtracting(wanted)
        if !wanted.isEmpty { WindowServerEvents.request(Array(wanted)) }
        if !removed.isEmpty { WindowServerEvents.remove(Array(removed)) }
        notifiedWindowIds = wanted
    }

    /// Extra ids a mouse gesture needs notifies for (the drag target, a resize's siblings) on top
    /// of the bordered set. Routed through the one tracked request so gestures can't clobber it.
    private var dragNotifiedWindowIds: Set<UInt32> = []

    func ensureNotifications(forGesture ids: [UInt32]) {
        let new = Set(ids).subtracting(notifiedWindowIds)
        guard !new.isEmpty else { return } // already delivered: no WindowServer IPC per move event
        dragNotifiedWindowIds.formUnion(new)
        requestWindowServerNotifications()
    }

    /// Gesture over: stop the gesture-only notifies, and put the target's ring where the window
    /// actually came to rest. The display-link sampler stops at mouse-up, and a window at rest sends
    /// no further notify — so a final frame the sampler skipped (main thread busy) left the ring a
    /// few frames behind the dropped window. Once more shortly after: some apps settle post-drop.
    func endGesture(targetWindowId: UInt32?) {
        if !dragNotifiedWindowIds.isEmpty {
            dragNotifiedWindowIds.removeAll()
            requestWindowServerNotifications()
        }
        guard let id = targetWindowId else { return }
        observe(windowId: id)
        Task.startUnstructured { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            WindowBordersManager.shared.observe(windowId: id)
        }
    }
}

/// True when the workspace's display currently shows a native macOS fullscreen Space.
/// Border overlays skip such workspaces: their windows sit behind the fullscreen app.
@MainActor
func workspaceDisplayIsFullscreen(_ workspace: Workspace) -> Bool {
    guard let displayId = DisplayRefresh.displayId(for: workspace) else { return false }
    return cachedCurrentSpaceIsFullscreen(displayId)
}

/// True when the display is showing fullscreen *content* of either kind:
/// - a native macOS fullscreen Space (Safari video, green-button fullscreen), or
/// - a non-native fullscreen overlay: the frontmost normal-level window on the display covers its
///   ENTIRE frame, menu-bar strip included (VLC default fullscreen, borderless-fullscreen games).
/// The status bar / tab strips float above normal windows, so they must hide for both.
@MainActor
func displayShowsFullscreenContent(_ displayId: CGDirectDisplayID) -> Bool {
    if cachedCurrentSpaceIsFullscreen(displayId) { return true }
    let display = WindowServerEvents.displayBounds(displayId)
    let tol: CGFloat = 2
    for item in onScreenWindowSnapshot().normalStack {
        let r = item.rect
        guard r.topLeftX < display.maxX, r.topLeftX + r.width > display.minX,
              r.topLeftY < display.maxY, r.topLeftY + r.height > display.minY
        else { continue }
        // Frontmost normal window on this display: fullscreen content iff it covers the display.
        return r.topLeftX <= display.minX + tol && r.topLeftY <= display.minY + tol
            && r.topLeftX + r.width >= display.maxX - tol
            && r.topLeftY + r.height >= display.maxY - tol
    }
    return false
}

/// Backing scale of the display containing `rect` (retina = 2). Border windows draw in points;
/// the resolution must match the target display or the stroke renders at the wrong crispness.
@MainActor
private func backingScale(forRect rect: Rect) -> Double {
    let ak = rect.toAppKitFrame()
    let center = CGPoint(x: ak.midX, y: ak.midY)
    for screen in NSScreen.screens where screen.frame.contains(center) {
        return Double(screen.backingScaleFactor)
    }
    return Double(NSScreen.main?.backingScaleFactor ?? 2)
}

// MARK: - Floating free-drag: display-Hz border glue

/// Samples a floating window's live frame on the workspace display's vsync so the border follows
/// at monitor Hz (ProMotion 120, etc.), not at the rate of AX/SLS notify delivery.
@MainActor
enum FloatingBorderTracker {
    private static var targetId: UInt32?
    private static let subscriptionId = UUID()
    private static var subscribedDisplayId: CGDirectDisplayID?
    private static var lastSampled: Rect?
    /// Consecutive pulses with an unchanged frame. The tracker is kicked by ANY WS move event on
    /// a float (including programmatic stash/unstash moves), and mouse-up teardown only runs for
    /// real drags — without an idle cutoff the display link ran at monitor Hz forever after any
    /// workspace switch that repositioned a float.
    private static var idlePulses = 0
    private static let idleStopThreshold = 30 // ≈ 0.25–0.5s of no motion
    /// Drag diagnostics (frame trace, debug builds): pulses, paints, WS notifies, worst paint gap
    private static var stats = (pulses: 0, paints: 0, notifies: 0, lastPaint: 0.0, worstGap: 0.0, startedAt: 0.0)

    static func noteWindowServerNotify(windowId: UInt32) {
        if windowId == targetId { stats.notifies += 1 }
    }

    static func kick(_ window: Window) {
        guard window.isFloating else { return }
        guard config.windowBorders.enabled, ServerState.isEnabled else { return }
        if targetId != window.windowId { stats = (0, 0, 0, 0, 0, ProcessInfo.processInfo.systemUptime) }
        targetId = window.windowId
        idlePulses = 0
        ensureNotifications(for: window)
        ensureSubscribed(for: window)
        sampleNow()
    }

    static func stop() {
        if let id = targetId, stats.pulses > 0 {
            let s = stats
            FrameTrace.log("float-drag \(id) \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - s.startedAt))s pulses=\(s.pulses) paints=\(s.paints) ws-notifies=\(s.notifies) worst-gap=\(Int(s.worstGap * 1000))ms")
        }
        stats = (0, 0, 0, 0, 0, 0)
        targetId = nil
        lastSampled = nil
        idlePulses = 0
        if let displayId = subscribedDisplayId {
            WorkspaceDisplayLink.unsubscribe(displayId: displayId, id: subscriptionId)
            subscribedDisplayId = nil
        }
    }

    private static func ensureNotifications(for window: Window) {
        WindowBordersManager.shared.ensureNotifications(forGesture: [window.windowId])
    }

    private static func ensureSubscribed(for window: Window) {
        let displayId = DisplayRefresh.displayId(for: window)
            ?? window.nodeWorkspace.flatMap { DisplayRefresh.displayId(for: $0) }
            ?? CGMainDisplayID()
        if subscribedDisplayId == displayId { return }
        if let old = subscribedDisplayId {
            WorkspaceDisplayLink.migrate(
                id: subscriptionId,
                from: old,
                to: displayId,
                onPulse: { FloatingBorderTracker.onDisplayPulse() },
            )
        } else {
            WorkspaceDisplayLink.subscribe(displayId: displayId, id: subscriptionId) {
                FloatingBorderTracker.onDisplayPulse()
            }
        }
        subscribedDisplayId = displayId
    }

    private static func onDisplayPulse() {
        guard targetId != nil else { return }
        stats.pulses += 1
        if let id = targetId, let window = Window.get(byId: id), window.isFloating {
            ensureSubscribed(for: window)
        }
        sampleNow()
    }

    private static func sampleNow() {
        guard let id = targetId else { return }
        guard let live = WindowServerReads.current.windowBounds(windowId: id, forOverlay: true) else {
            stop() // window gone — don't spin the link on a dead id
            return
        }
        if live == lastSampled {
            // A held-but-motionless drag still has the button down — keep sampling then.
            if currentlyManipulatedWithMouseWindowId != id {
                idlePulses += 1
                if idlePulses >= idleStopThreshold { stop() }
            }
            return
        }
        idlePulses = 0
        lastSampled = live
        let now = ProcessInfo.processInfo.systemUptime
        if stats.lastPaint > 0 { stats.worstGap = max(stats.worstGap, now - stats.lastPaint) }
        stats.lastPaint = now
        stats.paints += 1
        WindowBordersManager.shared.sampleFloatingBorder(windowId: id)
    }
}

extension Rect {
    /// Convert an AeroSpace Rect (top-left origin, y-down) to an AppKit frame (bottom-left, y-up).
    /// AeroSpace Rects live in the unified main-screen-relative space, so the flip uses mainMonitor.height
    @MainActor func toAppKitFrame() -> NSRect {
        NSRect(
            x: topLeftX,
            y: mainMonitor.height - (topLeftY + height),
            width: width,
            height: height,
        )
    }
}

/// Per-session answer to "is this display showing a native fullscreen Space?". Borders, the group
/// tab bar and the status bar each asked for every display on every session (a display-UUID
/// allocation + two SkyLight calls per ask). Cleared with the monitors cache (session start,
/// screen-parameter changes) and on every status-bar tick.
@MainActor private var spaceFullscreenCache: [CGDirectDisplayID: Bool] = [:]

@MainActor
func cachedCurrentSpaceIsFullscreen(_ displayId: CGDirectDisplayID) -> Bool {
    if let cached = spaceFullscreenCache[displayId] { return cached }
    let value = WindowServerEvents.currentSpaceIsFullscreen(displayId)
    spaceFullscreenCache[displayId] = value
    return value
}

@MainActor
func invalidateSpaceFullscreenCache() {
    spaceFullscreenCache.removeAll(keepingCapacity: true)
}
