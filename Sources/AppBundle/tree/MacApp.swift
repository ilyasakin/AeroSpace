import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    /// Frame writes still in flight, so "superseded" can mean what it says.
    ///
    /// `setFrameJobs` keeps the last job per window and is never cleared on completion, so the mere
    /// presence of an entry does not mean a write is outstanding — an early version of the counter
    /// below read it that way and reported 60-80% of writes discarded when in fact every one had
    /// been delivered. `RunLoopJob` has no finished state (only `isCancelled`), so completion is
    /// tracked here.
    private var pendingFrameWrites: [UInt32: PendingFrameWrite] = [:]
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        if let existing = allAppsMap[pid] { return existing }
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await()
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        let thread = Thread {
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp

                Task.startUnstructured { @MainActor in
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(nsApp.idForDebug)"
        thread.start()

        try await wip.await()
        return allAppsMap[pid]
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let windowId = try await thread?.runInLoop(cm) { [nsApp, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    /// Focus the window for keyboard input: activate the app and AXRaise, like a normal click.
    ///
    /// There used to be a `raise: false` variant that reached for a private focus-without-raise
    /// call to leave z-order untouched. It existed solely to hold an i3-style float layer above the
    /// tiling stack, and went with it — focus now always raises, which is what macOS does anyway.
    @MainActor func nativeFocus(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || monitors.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
            _ = withWindowAsync(windowId, .cancellable) { window, job in
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        } else {
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [nsApp] window, job in
                window.set(Ax.isMainAttr, true)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
        // Intent is this window; next call can take the activate-only fast path when still current.
        lastNativeFocusedWindowId = windowId
    }

    /// Raises the window within the global z-order without activating the app (unlike nativeFocus)
    func raiseWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        _ = withWindowAsync(windowId, .cancellable) { window, job in
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// Like `raiseWindow`, but returns only after the app has processed the AXRaise.
    /// Ordering-sensitive callers (float-layer settle) must post make-key strictly *after*
    /// the raise — `withWindowAsync` fire-and-forget cannot guarantee that.
    func raiseWindowAndWait(_ windowId: UInt32) async {
        if serverArgs.isReadOnly { return }
        _ = try? await withWindow(windowId, .cancellable) { window, _ in
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// Mark the window as main/key for AppKit without AXRaise (float layer must stay on top).
    @MainActor
    func setMainWithoutRaise(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        _ = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isMainAttr, true)
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        // A write that is STILL IN FLIGHT and gets replaced discards an intent that belief has
        // already recorded. That is the case worth counting; a previous write that already landed is
        // not superseded by the next one.
        if let previous = pendingFrameWrites.removeValue(forKey: windowId), !previous.isDone {
            AxWriteStats.noteSuperseded()
        }
        AxWriteStats.noteSubmitted()
        let pending = PendingFrameWrite()
        pendingFrameWrites[windowId] = pending
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable, pending: pending) { [axApp] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
        }
    }

    func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [axApp] window, job in
            try? disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            semaphore.signal()
        }
        guard !job.isCancelled else { return }
        // Bounded: an app that never answers AX must not keep the process from exiting.
        _ = semaphore.wait(timeout: .now() + AxTerminationBudget.claim())
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await thread?.runInLoop(cm) { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try AppBundle.getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle.getAxRect(window: window, job: job))
        }
        guard !job.isCancelled else { return nil }
        // Bounded: see setAxFrameForTermination. nil (unknown rect) is already a handled outcome.
        return future.blockingGet(timeout: AxTerminationBudget.claim()) ?? nil
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp] window, job in
            let frame = try? AppBundle.getAxRect(window: window, job: job)
            return window.getWindowType(
                axApp: axApp.threadGuarded,
                nsApp.activationPolicy,
                windowLevel,
                coversFullDisplay: frame.map(rectCoversAnyDisplay) ?? false,
            )
        } ?? .window
    }

    /// The user-facing verdict: 'window-detection-rules' from the config take precedence over the heuristics
    @MainActor
    func resolveWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        if let rule = try await matchedWindowDetectionRule(windowId, windowLevel, cm) {
            return rule.treatAs.windowType
        }
        return try await getAxUiElementWindowType(windowId, windowLevel, cm)
    }

    @MainActor
    func matchedWindowDetectionRule(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> WindowDetectionRule? {
        let rules = config.windowDetectionRules
        if rules.isEmpty { return nil }
        guard let signals = try await withWindow(windowId, cm, { window, job in
            (title: window.get(Ax.titleAttr), subrole: window.get(Ax.subroleAttr))
        }) else { return nil }
        let appName = name
        let startup = isStartup
        return rules.first {
            $0.matcher.matches(
                appId: rawAppBundleId,
                appName: appName,
                windowTitle: signals.title,
                windowSubrole: signals.subrole,
                windowLevel: windowLevel,
                isStartup: startup,
            )
        }
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: UInt32, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await thread?.runInLoop(cm) { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    /// True if the AX tree has an `AXToolbar` (shallow: window children + one level).
    /// Used to pick Tahoe's larger toolbar corner radius without Screen Recording.
    func windowHasAxToolbar(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { window, job in
            Self.axSubtreeHasToolbar(window, depth: 0)
        } ?? false
    }

    private static let axToolbarRole = "AXToolbar"
    private static func axSubtreeHasToolbar(_ el: any AxUiElementMock, depth: Int) -> Bool {
        if el.get(Ax.roleAttr) == axToolbarRole { return true }
        guard depth < 2, let kids = el.get(Ax.childrenAttr) else { return false }
        for child in kids {
            if axSubtreeHasToolbar(child, depth: depth + 1) { return true }
        }
        return false
    }

    func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    /// Reads fullscreen + minimized in ONE thread-hop onto the app's AX thread instead of two
    /// separate withWindow calls. Returns nil for an attribute whose AX read failed
    func nativeFullscreenAndMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> (fullscreen: Bool?, minimized: Bool?)? {
        try await withWindow(windowId, cm) { window, job in
            let fullscreen = window.get(Ax.isFullscreenAttr)
            // A fullscreen window is never minimized; skip the second read in that case
            let minimized = fullscreen == true ? false : window.get(Ax.minimizedAttr)
            return (fullscreen, minimized)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: [UInt32]] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, [UInt32]).self, returning: [MacApp: [UInt32]].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, []) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: [UInt32]] = [:]
            for try await (pid, windowIds) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = windowIds
                }
            }
            return result
        }
    }

    private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [UInt32] {
        if nsApp.isTerminated {
            await destroy()
            return []
        }
        guard let thread else { return [] }
        let (alive, dead) = try await thread.runInLoop(.cancellable) { [nsApp, windows, axApp] (job) -> ([UInt32], [UInt32]) in
            var alive: [UInt32: AxWindow] = windows.threadGuarded
            var dead = [UInt32: AxWindow]()
            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                (alive, dead) = try alive.partition {
                    try job.checkCancellation()
                    return $0.value.ax.containingWindowId() != nil
                }
            }

            for (id, window) in axApp.threadGuarded.get(Ax.windowsAttr) ?? [] {
                try job.checkCancellation()
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
            }

            windows.threadGuarded = alive
            return (Array(alive.keys), Array(dead.keys))
        }
        windowsCount = alive.count
        for windowId in dead {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return alive
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        pendingFrameWrites = [:]
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        try await thread?.runInLoop(cm) { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        pending: PendingFrameWrite? = nil,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> (),
    ) -> RunLoopJob {
        thread?.runInLoopAsync(job: RunLoopJob(cm)) { [windows] job in
            defer { pending?.markDone() }
            guard let window = windows.threadGuarded[windowId] else {
                // The window died before its job ran. Previously indistinguishable from success,
                // because the outcome was swallowed by `try?`.
                if pending != nil { AxWriteStats.noteFailed() }
                return
            }
            do {
                try body(window.ax, job)
                if pending != nil { AxWriteStats.noteDelivered() }
            } catch {
                if pending != nil { AxWriteStats.noteFailed() }
            }
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification]),
            (windowStateChangedObs, [kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    try job.checkCancellation()
    return window.getFrame() // position + size in one AX round-trip
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}

/// Wall-clock budget for the blocking AX waits on the quit path.
///
/// `beforeTermination` must finish its work before the process exits, so unlike every other AX call
/// it blocks the main thread. Unbounded, a single unresponsive app (beachballed Electron, an app
/// mid-crash, one that stopped serving AX) meant AeroSpace could never quit — the user's only way
/// out was `kill -9`, which skips the restore sweep entirely and leaves windows parked off-screen.
///
/// The budget is TOTAL across the sweep rather than per window, because window count is unbounded:
/// per-window timeouts would still let 40 windows × 200ms add up to a visible hang. Once it is
/// exhausted, remaining waits return immediately and their windows keep whatever frame they have —
/// a worse restore than blocking, but a bounded one.
///
/// `nonisolated(unsafe)`: the quit sweep runs on the main thread (`beforeTermination` is
/// `@MainActor`) but the AX helpers that consume the budget are nonisolated, matching the rest of
/// this file. Single-threaded by construction, so no lock.
enum AxTerminationBudget {
    static let total: TimeInterval = 2.0
    private nonisolated(unsafe) static var deadline: Double?

    /// Time the next blocking wait may take. Starts the clock on first use.
    static func claim() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        guard let deadline = unsafe deadline else {
            unsafe deadline = now + total
            return total
        }
        return max(0, deadline - now)
    }

    static func resetForTests() { unsafe deadline = nil }
}


/// In-flight marker for one AX frame write.
///
/// `RunLoopJob` only knows whether it was CANCELLED, not whether it ran, and the per-window job
/// dictionary is never cleared on completion — so neither could answer "is a write still
/// outstanding". Set from the app's AX thread when the job finishes, read from the main thread when
/// the next write for that window arrives.
private final class PendingFrameWrite: Sendable {
    nonisolated(unsafe) private var _done: Int32 = 0
    var isDone: Bool { unsafe _done == 1 }
    func markDone() { unsafe OSAtomicCompareAndSwapInt(0, 1, &_done) }
}
