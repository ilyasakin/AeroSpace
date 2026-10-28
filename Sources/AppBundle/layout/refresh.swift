import AppKit
import Common

// Session orchestration lives in SessionPipeline.swift. This file keeps the public entry points
// and the heavy phase implementations (discover, layout) that the pipeline calls.

/// True while a heavy discovery session is scheduled or was cancelled before finishing.
/// Light sessions that cancel a pending heavy must re-queue discovery after they finish
/// (unless they already schedule follow-up heavy themselves).
@MainActor var discoveryHeavyPending: Bool = false

/// Bumps on every schedule **and** when a light cancels a running heavy, so a cancelled task
/// cannot clear pending after `runHeavy` swallows `CancellationError`.
@MainActor var heavyScheduleGeneration: UInt64 = 0

/// Pure policy: re-queue discovery after a light that cancelled (or pre-empted) a heavy
/// without scheduling its own follow-up.
func sessionShouldRescheduleCancelledDiscovery(
    discoveryHeavyPending: Bool,
    hasActiveHeavyTask: Bool,
    planSchedulesFollowUp: Bool,
) -> Bool {
    discoveryHeavyPending && !hasActiveHeavyTask && !planSchedulesFollowUp
}

/// Pure policy: the schedule task may clear `discoveryHeavyPending` only when this generation
/// still owns the obligation **and** heavy completed without cancellation.
func mayClearDiscoveryHeavyPending(
    generationMatches: Bool,
    heavyCompletedSuccessfully: Bool,
) -> Bool {
    generationMatches && heavyCompletedSuccessfully
}

/// Invalidate a cancelled heavy's generation so it cannot clear pending when it returns.
@MainActor
func noteHeavyCancelledByLightSession() {
    if activeRefreshTask != nil {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        // Keep discoveryHeavyPending true; bump gen so the cancelled task cannot clear it.
        heavyScheduleGeneration &+= 1
    }
}

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    activeRefreshTask?.cancel()
    discoveryHeavyPending = true
    heavyScheduleGeneration &+= 1
    let generation = heavyScheduleGeneration
    let debounce = event.heavyDebounceNanoseconds
    activeRefreshTask = Task.startUnstructured { @MainActor in
        do {
            try checkCancellation()
            // Trailing debounce: notification bursts (one app posting created/moved/focused for a
            // handful of windows within a few ms) each used to START a full discovery that the next
            // one cancelled — with the AX work of the cancelled ones still running on app threads
            if debounce > 0 { try await Task.sleep(nanoseconds: debounce) }
            let completed = await runHeavyCompleteRefreshSession(
                event,
                assumeCancellable: true,
                optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
            )
            // Mid-flight cancel: runHeavy may swallow CancellationError and return false —
            // must NOT clear pending (light will re-queue).
            if mayClearDiscoveryHeavyPending(
                generationMatches: generation == heavyScheduleGeneration,
                heavyCompletedSuccessfully: completed && !Task.isCancelled,
            ) {
                discoveryHeavyPending = false
                activeRefreshTask = nil
            }
        } catch is CancellationError {
            // Pre-start cancel: leave discoveryHeavyPending true for re-queue.
        } catch {
            die("Illegal error scheduling heavy: \(error)")
        }
    }
}

extension RefreshSessionEvent {
    /// Coalescing delay before a scheduled heavy starts. Only for notification-driven events;
    /// startup/config/mouse-up/command follow-ups start immediately.
    var heavyDebounceNanoseconds: UInt64 {
        switch self {
            case .ax, .globalObserver: 16_000_000
            case .configAutoReload, .globalObserverLeftMouseUp, .menuBarButton, .hotkeyBinding, .startup,
                 .socketServer, .i3IpcRunCommand, .resetManipulatedWithMouse, .focusFollowsMouse: 0
        }
    }
}

@MainActor
@discardableResult
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async -> Bool {
    await Kernel.exclusive("heavy session") {
        await SessionPipeline.runHeavy(
            event,
            assumeCancellable: assumeCancellable,
            plan: SessionPipeline.planHeavy(
                layout: shouldLayoutWorkspaces,
                optimisticLayout: optimisticallyPreLayoutWorkspaces,
            ),
        )
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    // Drag sessions are marked by currentlyManipulatedWithMouseWindowId (set before light entry
    // on move/resize). Plan skips borders/status rebuild and follow-up heavy for those.
    let mouseManipulate = event.isAx && currentlyManipulatedWithMouseWindowId != nil
    let plan = SessionPipeline.planLight(event: event, mouseManipulate: mouseManipulate)
    // Pre-empt a running heavy BEFORE queueing behind it: it stops at its next cancellation point
    // instead of finishing discovery while a hotkey waits (runLight re-queues discovery after).
    if !plan.skipHeavyCancel, !Kernel.isInsideJob {
        noteHeavyCancelledByLightSession()
    }
    return try await Kernel.exclusive("light session") {
        try await SessionPipeline.runLight(event, plan: plan, body: body)
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { ServerState.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeAllContainers()
    }
}

/// Heavy phase: garbage-collect terminated apps/windows and register newly seen ones
@MainActor
func discoverAliveWindows() async throws {
    try await MacOS.current.discoverWindows()
    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func onAxWindowListChanged(notif: String) {
    Task.startUnstructured { @MainActor in
        if !ServerState.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// kAXFocusedWindowChanged: a focus change is not a structural change. Sync focus in a light
/// session (focus read, hygiene, layout diff, borders) instead of a full AX discovery of every app;
/// discovery runs only when the newly focused window isn't registered yet (apps that never post
/// kAXWindowCreated are still picked up this way).
func onAxFocusedWindowChanged(windowId: UInt32?, notif: String) {
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        if let windowId, Window.get(byId: windowId) != nil {
            try? await runLightSession(.ax(notif), token) {}
        } else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
        }
    }
}

/// kAXTitleChanged: only acted on while a title-based rule could still match this window
func onAxTitleChanged(windowId: UInt32?, notif: String) {
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled,
              let windowId, let window = Window.get(byId: windowId)
        else { return }
        // Tab / stack titles: only windows that are members of an accordion show their title
        if (window.parent as? TilingContainer)?.layout == .accordion {
            let title = try? await window.getTitle(.cancellable) // AX read: outside the kernel
            await Kernel.exclusive("ax title changed") {
                window.cachedTitle = title
                window.cachedTitleIsStale = false
                GroupTabBarManager.shared.refresh()
            }
        } else {
            // Not on a tab now: no read (a terminal retitles constantly), but the cached title no
            // longer holds — a tab shown later read the registration-time title or the app name
            await Kernel.exclusive("ax title changed") { window.cachedTitleIsStale = true }
        }
        guard window.hasPendingTitleRules else { return }
        try? await runLightSession(.ax(notif), token) {
            await onWindowTitleChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        }
    }
}

/// Windows now on a tab whose title changed while they weren't: read before the tab bar draws
/// (drawing never reads AX)
/// (drawing never reads AX). Every session runs this: it only looks at the stale ones.
@MainActor var staleTitleWindowIds: Set<UInt32> = []

@MainActor
func refreshStaleTabTitles() async throws {
    if staleTitleWindowIds.isEmpty { return }
    for id in staleTitleWindowIds {
        guard let window = Window.get(byId: id) else { staleTitleWindowIds.remove(id); continue }
        guard (window.parent as? TilingContainer)?.layout == .accordion, window.nodeWorkspace?.isVisible == true else { continue }
        window.cachedTitle = try await window.getTitle(.cancellable)
        window.cachedTitleIsStale = false
    }
}

/// miniaturized/deminiaturized notifications. Like refreshObs, but first drops the caches of the affected
/// window so the next refresh re-reads its native state over AX
func onAxNativeStateChanged(windowId: UInt32?, notif: String) {
    Task.startUnstructured { @MainActor in
        if !ServerState.isEnabled { return }
        await Kernel.exclusive("ax native state changed") {
            if let windowId, let window = Window.get(byId: windowId) {
                window.noteNativeStateChanged()
            }
            scheduleCancellableCompleteRefreshSession(.ax(notif))
        }
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
func layoutWorkspaces(includeInvisible: Bool = true) async throws {
    if !ServerState.isEnabled {
        for workspace in Workspace.allUnsorted {
            workspace.allLeafWindowsRecursive.forEach { $0.unhideFromCorner() }
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    // Asleep / lid closed without an external display: there is nowhere to lay out, and the
    // fallback monitor geometry would park windows at a corner that is on-screen after wake
    if !isUnitTest && NSScreen.screens.isEmpty { return }
    followActiveWorkspaceForStickyWindows()

    // Mouse-drag: only re-tile the workspace that owns the manipulated window (sibling weights).
    // Laying out every visible monitor each AX tick is the main source of sibling jank.
    if !includeInvisible,
       let id = currentlyManipulatedWithMouseWindowId,
       let ws = Window.get(byId: id)?.nodeWorkspace
    {
        ws.allLeafWindowsRecursive.forEach { $0.unhideFromCorner() }
        try await ws.layoutWorkspace()
        return
    }

    let monitors = monitors

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { $0.unhideFromCorner() }
        try await workspace.layoutWorkspace()
    }
    guard includeInvisible else { return }

    var monitorToOptimalHideCorner: [DisplayId: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: Monitor, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.displayId] = corner
    }
    for workspace in Workspace.allUnsorted where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.displayId] ?? .bottomRightCorner
        for window in workspace.allLeafWindowsRecursive {
            try await window.hideInCorner(corner)
        }
    }
}

@MainActor
func normalizeAllContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.allUnsorted {
        workspace.normalizeContainers()
    }
}
