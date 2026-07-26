import AppKit
import Common
import CoreGraphics

/// WindowServer move/resize callback (runs on the thread that registered it - the main thread).
/// `data` points to the moved window's CGWindowID. Only the moved window's own border changes —
/// occlusion is handled by the compositor (each border is ordered above its target), so a move no
/// longer forces neighbor mask recomputes. Also starts mouse-resize gestures.
let windowBordersEventProc: SkyLight.NotifyProc = { _, data, _, _ in
    guard let data else { return }
    let windowId = data.load(as: UInt32.self)
    if Thread.isMainThread {
        MainActor.assumeIsolated { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    } else {
        DispatchQueue.main.async { WindowBordersManager.shared.handleWindowMoved(windowId: windowId) }
    }
}

/// Per-window borders backed by raw SkyLight windows ordered above each target (JankyBorders model).
/// No overlay, no occlusion mask: the compositor keeps every border directly above its window, so a
/// border can never leak over a float or any other window stacked between them.
@MainActor
final class WindowBordersManager {
    static let shared = WindowBordersManager()
    private var entries: [UInt32: BorderWindow] = [:]
    /// Last painted rect per id — style/order refreshes reuse it without a fresh SLS read.
    private var rects: [UInt32: Rect] = [:]
    /// The focused window (drives active vs inactive style).
    private var activeId: UInt32?
    private var observingWindowServer = false
    /// Per-window chrome class for corner-radius probes (plain vs toolbar). Filled async once.
    private var chromeCache: [UInt32: WindowCornerRadius.Chrome] = [:]
    /// Session-persistent chrome per app bundle id. Seeds a new window's *first* paint with the
    /// app's known chrome so it doesn't flash the .plain radius before the async probe corrects it
    /// — the flicker that hit every new window and every workspace return (per-window cache is
    /// cleared when a window leaves the visible set; this survives).
    private var chromeByApp: [String: WindowCornerRadius.Chrome] = [:]
    /// Monotonic deadline (systemUptime) until which a freshly-created border pins to its layout
    /// target instead of tracking live move events. On a workspace switch / window appearance the
    /// app animates the window into place; without this the border follows that entrance animation
    /// (a "grows into position" blink). Cleared once the window settles.
    private var settlingUntil: [UInt32: Double] = [:]
    private static let settleDuration: Double = 0.4
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

    /// Window ids currently carrying a border (for WS notify subscription during mouse-resize).
    var borderedWindowIds: [UInt32] { Array(entries.keys) }

    private init() {}

    /// Full rebuild: driven from AeroSpace's refresh loop (focus / move / resize / layout /
    /// workspace change). Establishes which windows are bordered, their styles, and re-orders each
    /// border above its target.
    func refresh() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled, BorderSkyLight.isAvailable else {
            teardownAll()
            return
        }
        // During startup, apps animate their windows into AeroSpace's layout over ~seconds and a
        // border faithfully tracks that motion — a visible slide/jump on every launch. Skip border
        // work until startup settles; the first post-startup refresh creates them in place.
        if isStartup { return }
        if !observingWindowServer {
            observingWindowServer = true
            SkyLight.registerWindowEvents(windowBordersEventProc)
        }
        activeId = focus.windowOrNil?.windowId
        invalidateOnScreenWindowSnapshot()
        computeStackNeighbors()

        var seen = Set<UInt32>(minimumCapacity: entries.count)
        for workspace in Workspace.allUnsorted where workspace.isVisible {
            // Borders must not paint over a native-fullscreen app on this display.
            if workspaceDisplayIsFullscreen(workspace) { continue }
            for window in workspace.allLeafWindowsRecursive {
                guard let rect = resolvedBorderRect(for: window) else { continue }
                seen.insert(window.windowId)
                paint(id: window.windowId, window: window, rect: rect, cfg: cfg, reorder: true)
            }
        }
        for (id, entry) in entries where !seen.contains(id) {
            entry.release()
            entries.removeValue(forKey: id)
        }
        // Prune per-id state for anything out of the visible set — including ids that never got
        // an entry (chrome-probe deferral), which used to leak and resurrect ghost rings.
        for id in rects.keys where !seen.contains(id) { rects.removeValue(forKey: id) }
        for id in chromeCache.keys where !seen.contains(id) { chromeCache.removeValue(forKey: id) }
        for id in settlingUntil.keys where !seen.contains(id) { settlingUntil.removeValue(forKey: id) }
        for id in lastStackNeighbor.keys where !seen.contains(id) { lastStackNeighbor.removeValue(forKey: id) }
        requestWindowServerNotifications()
    }

    /// Restyle + reorder existing borders after a focus change when the light session skipped a
    /// full `refresh()` (focus-follows-mouse, float click-without-raise). Reordering is what keeps
    /// each border glued above its window after a raise restacks the z-order.
    func syncActiveFocus() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled, BorderSkyLight.isAvailable else { return }
        activeId = focus.windowOrNil?.windowId
        // Focus changes are when macOS restacks — refresh the stack fingerprint so tiles whose
        // z-position moved get re-ordered (and only those).
        invalidateOnScreenWindowSnapshot()
        computeStackNeighbors()
        for (id, _) in entries {
            guard let window = Window.get(byId: id) else { continue }
            guard let rect = rects[id] ?? window.believedRect else { continue }
            // Focus change restacked z-order — reassert each border above its target.
            paint(id: id, window: window, rect: rect, cfg: cfg, reorder: true)
        }
    }

    /// A window moved/resized (WindowServer event) — repaint only that window's own border.
    func handleWindowMoved(windowId: UInt32) {
        // Drag-target WS events start/continue mouse-resize; must run even when borders are off.
        MouseResizeDriver.noteWindowServerFrame(windowId: windowId)
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }

        if let window = Window.get(byId: windowId), window.isFloating, entries[windowId] != nil {
            FloatingBorderTracker.kick(window)
        }
        guard entries[windowId] != nil, let window = Window.get(byId: windowId) else { return }
        // Still settling after appearing: pin to the layout target so the entrance animation isn't
        // tracked. A real mouse drag overrides (its own path / mouseManipulate resolves live).
        //
        // The deadline and the availability of a target rect are checked SEPARATELY on purpose. A
        // single combined `if let` dropped the pin whenever the desired rect was nil
        // — i.e. for windows we never wrote a frame for (fresh floats) — so the one case the pin
        // exists to cover, the entrance animation, was tracked frame by frame instead of ignored.
        if let until = settlingUntil[windowId] {
            if ProcessInfo.processInfo.systemUptime < until, currentlyManipulatedWithMouseWindowId != windowId {
                // No layout target yet: hold the border where it is rather than chasing the
                // animation (matches sampleFloatingBorder, which also skips while settling).
                if let target = window.desiredRect {
                    paint(id: windowId, window: window, rect: target, cfg: config.windowBorders, reorder: false)
                }
                return
            }
            settlingUntil.removeValue(forKey: windowId)
        }
        guard let rect = resolvedLiveBorderRect(windowId: windowId) else { return }
        // Hot path: a moving window keeps its z-order, so skip the reorder IPC (~225µs/frame).
        paint(id: windowId, window: window, rect: rect, cfg: config.windowBorders, reorder: false)
    }

    /// Sample live bounds + paint for a floating drag target (display-link / immediate tick).
    func sampleFloatingBorder(windowId: UInt32) {
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled, entries[windowId] != nil else { return }
        guard let window = Window.get(byId: windowId) else { return }
        // Respect the settling pin (entrance animation) unless the user is actually dragging —
        // otherwise this display-rate painter and the settle path fight over the border position
        // and the ring flickers between the pin and the animation for the whole settle window.
        if let until = settlingUntil[windowId], ProcessInfo.processInfo.systemUptime < until,
           currentlyManipulatedWithMouseWindowId != windowId
        {
            return
        }
        guard let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true) else { return }
        // Floating free-drag frame: geometry only, z-order unchanged.
        paint(id: windowId, window: window, rect: live, cfg: config.windowBorders, reorder: false)
    }

    /// Stop display-link floating border tracking (mouse-up).
    func stopFloatingBorderTracking() {
        FloatingBorderTracker.stop()
    }

    /// After mouse-drag layout: repaint tile borders from layout geometry (belief) —
    /// EXCEPT the drag target, whose border tracks live WS bounds (repainting it from
    /// belief here fought the live path and snapped the ring back to the grid slot).
    func syncAfterMouseLayout() {
        let cfg = config.windowBorders
        guard cfg.enabled, TrayMenuModel.shared.isEnabled, !entries.isEmpty else { return }
        for (id, _) in entries {
            if id == currentlyManipulatedWithMouseWindowId { continue }
            guard let window = Window.get(byId: id) else { continue }
            guard let rect = window.believedRect
                ?? WindowServerReads.current.windowBounds(windowId: id, forOverlay: true)
            else { continue }
            // Mouse resize changes geometry, not z-order — geometry-only repaint.
            paint(id: id, window: window, rect: rect, cfg: cfg, reorder: false)
        }
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
    private func paint(id: UInt32, window: Window, rect: Rect, cfg: WindowBorders, reorder: Bool) {
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
        let isNew = entries[id] == nil
        ensureEntry(id)
        guard let entry = entries[id] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isNew {
            // Pin to the layout target briefly so the entrance animation isn't tracked (see above).
            settlingUntil[id] = now + Self.settleDuration
        }
        rects[id] = rect
        let isActive = id == activeId
        let style = isActive ? cfg.resolvedActiveStyle() : cfg.resolvedInactiveStyle()
        let radius = cfg.cornerRadius(forAppId: appId, chrome: knownChrome ?? .plain)
        // Reorder policy: floats reorder on request (they restack on raise). Tiles reorder only
        // when their WindowServer stack POSITION actually changed since the last refresh
        // (accordion cycle, cmd-tab raise) — reordering every tile on every refresh flashed on
        // click, and never reordering left stale rings over restacked windows.
        let settling = (settlingUntil[id]).map { now < $0 } ?? false
        let stackChanged = currentStackNeighbor[id] != nil
            && lastStackNeighbor[id] != nil
            && currentStackNeighbor[id] != lastStackNeighbor[id]
        let needsReorder = reorder && !settling && (window.isFloating || stackChanged)
        // Commit the fingerprint only when the restack was actually ACTED on (or when there was
        // nothing to react to). Committing unconditionally swallowed restacks that happened while a
        // reorder was suppressed — the hot move path paints with `reorder: false` on every
        // WindowServer notify, and the settle window suppresses too — so the next refresh compared
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
        settlingUntil.removeAll()
        probing.removeAll()
        lastStackNeighbor.removeAll()
        currentStackNeighbor.removeAll()
        if !notifiedWindowIds.isEmpty {
            SkyLight.removeNotifications(for: Array(notifiedWindowIds))
            notifiedWindowIds.removeAll()
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
            let prev = chromeCache[id]
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
                guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled,
                      let workspace = window.nodeWorkspace, workspace.isVisible,
                      !workspaceDisplayIsFullscreen(workspace)
                else {
                    rects.removeValue(forKey: id)
                    return
                }
            }
            guard deferredFirstPaint || prev != chrome,
                  let rect = rects[id] ?? window.believedRect
            else { return }
            paint(id: id, window: window, rect: rect, cfg: config.windowBorders, reorder: deferredFirstPaint)
            if deferredFirstPaint {
                requestWindowServerNotifications()
            }
        }
    }

    private func detectWindowChrome(_ window: Window) async -> WindowCornerRadius.Chrome {
        guard let mac = window as? MacWindow else { return .plain }
        do {
            if try await mac.macApp.windowHasAxToolbar(mac.windowId, .cancellable) {
                return .toolbar
            }
        } catch {
            // AX flake → plain probe radius
        }
        return .plain
    }

    // MARK: - Frame resolution

    /// Prefer live on-screen bounds so a user drag is not frozen to belief. Only use belief
    /// when we just wrote the frame and SkyLight may lag.
    private func resolvedBorderRect(for window: Window) -> Rect? {
        let id = window.windowId
        let applied = window.believedRect
        let mayBeStale = skyLightFrameMayBeStale(id)
        if mayBeStale, applied != nil {
            return resolveBorderRect(believed: applied, mayBeStale: true, liveBounds: nil, stackRect: nil)
        }
        let live = WindowServerReads.current.windowBounds(windowId: id, forOverlay: true)
        return resolveBorderRect(believed: applied, mayBeStale: false, liveBounds: live, stackRect: nil)
    }

    /// Frame source for a WindowServer move/resize notify.
    private func resolvedLiveBorderRect(windowId: UInt32) -> Rect? {
        let window = Window.get(byId: windowId)
        let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true)
        let applied = window?.believedRect
        let manipulated = currentlyManipulatedWithMouseWindowId
        return resolveLiveBorderRect(
            isFloating: window?.isFloating == true,
            isMouseManipulationTarget: manipulated == windowId,
            otherWindowManipulateActive: manipulated != nil && manipulated != windowId,
            mayBeStale: skyLightFrameMayBeStale(windowId),
            believed: applied,
            liveBounds: live,
        )
    }

    /// Tell WindowServer which windows we care about for move/resize notify delivery.
    ///
    /// Diffed against the previous set, not re-requested wholesale: requests were never withdrawn,
    /// so every window that ever had a border kept pushing move/resize events for the rest of the
    /// session — the set only grew, and each event woke the handler just to be discarded.
    private func requestWindowServerNotifications() {
        let wanted = Set(entries.keys)
        guard wanted != notifiedWindowIds else { return }
        let added = wanted.subtracting(notifiedWindowIds)
        let removed = notifiedWindowIds.subtracting(wanted)
        if !added.isEmpty { SkyLight.requestNotifications(for: Array(added)) }
        if !removed.isEmpty { SkyLight.removeNotifications(for: Array(removed)) }
        notifiedWindowIds = wanted
    }
}

/// True when the workspace's display currently shows a native macOS fullscreen Space.
/// Border overlays skip such workspaces: their windows sit behind the fullscreen app.
@MainActor
func workspaceDisplayIsFullscreen(_ workspace: Workspace) -> Bool {
    guard let displayId = DisplayRefresh.displayId(for: workspace) else { return false }
    return SkyLight.currentSpaceIsFullscreen(displayId: displayId)
}

/// True when the display is showing fullscreen *content* of either kind:
/// - a native macOS fullscreen Space (Safari video, green-button fullscreen), or
/// - a non-native fullscreen overlay: the frontmost normal-level window on the display covers its
///   ENTIRE frame, menu-bar strip included (VLC default fullscreen, borderless-fullscreen games).
/// The status bar / tab strips float above normal windows, so they must hide for both.
@MainActor
func displayShowsFullscreenContent(_ displayId: CGDirectDisplayID) -> Bool {
    if SkyLight.currentSpaceIsFullscreen(displayId: displayId) { return true }
    let display = CGDisplayBounds(displayId)
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

    static func kick(_ window: Window) {
        guard window.isFloating else { return }
        guard config.windowBorders.enabled, TrayMenuModel.shared.isEnabled else { return }
        targetId = window.windowId
        idlePulses = 0
        ensureNotifications(for: window)
        ensureSubscribed(for: window)
        sampleNow()
    }

    static func stop() {
        targetId = nil
        lastSampled = nil
        idlePulses = 0
        if let displayId = subscribedDisplayId {
            WorkspaceDisplayLink.unsubscribe(displayId: displayId, id: subscriptionId)
            subscribedDisplayId = nil
        }
    }

    private static func ensureNotifications(for window: Window) {
        var ids: [UInt32] = [window.windowId]
        ids.append(contentsOf: WindowBordersManager.shared.borderedWindowIds)
        SkyLight.requestNotifications(for: ids)
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
