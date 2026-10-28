import AppKit
import Common

/// A window's frame as AeroSpace handles it: reading it, writing it (minimal AX plans), recognising
/// its own writes coming back, and parking it in the hide corner. What is KNOWN about the frame lives
/// in one place, the window's `FrameRecord`; this file feeds it (writes, the app's answers,
/// WindowServer reports) and acts on its verdicts. Every macOS call goes through `MacOS.current`,
/// so tests run exactly this code against a simulator.
@MainActor
extension Window {
    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
        // macOS owns these: a native-fullscreen window lives in its own Space, a minimized one
        // isn't on screen. Writing their position is refused at best (a fullscreen TV window was
        // "parked" — and refused — on every switch away from its workspace). Hidden apps' windows
        // ARE parked: unhiding shows them where they are, which must not be on screen
        if isOwnedByMacos { return }
        if hiddenCorner == corner { return } // Already parked in the requested corner
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == zoomAppBundleId ? .zero : CGPoint(x: 1, y: -1)
                // Park at the physical monitor corner, not visibleRect's. visibleRect excludes the Dock,
                // so parking there leaves a Dock-height 1px strip of the window visible at the screen edge
                p = nodeMonitor.rect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = app.rawAppBundleId == zoomAppBundleId ? .zero : CGPoint(x: 1, y: 1)
                // Park at the physical monitor corner, not visibleRect's (see bottomLeftCorner comment)
                p = nodeMonitor.rect.bottomRightCorner - onePixelOffset
        }
        // Marked before the write: its answer (synchronous in the simulator) is judged as a park
        hiddenCorner = corner
        setAxFrame(p, nil)
        // The window is parked in the corner now. Force the next layout pass to re-apply the real
        // frame, otherwise the frame diffing in layoutRecursive would keep the window in the corner
        desiredRect = nil
    }

    /// The corner moved (screen parameters changed): the next layout re-parks this window, and a
    /// visible window gets its tile frame rewritten
    @MainActor
    func forgetHideCornerParking() {
        hiddenCorner = nil
        desiredRect = nil
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        if isOwnedByMacos { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                // Its own size, not the parked one: macOS clamps windows in the corner, and the
                // float came back shrunk
                setAxFrame(CGPoint(x: newX, y: newY), lastFloatingSize)
            case .macosNativeHiddenAppWindow:
                // Still hidden: it stays parked, and comes back from the corner once shown
                return
            case .macosNativeFullscreenWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        self.hiddenCorner = nil
    }

    /// The window moved or resized for a reason of its own (the user, the app): the layout target
    /// no longer describes it, so the next layout re-applies it; a parked window gets re-parked.
    /// The frame record keeps the observation.
    func noteExternalFrameChange() {
        desiredRect = nil
        hiddenCorner = nil
    }

    /// Native state changed behind our back (miniaturized, deminiaturized): nothing we knew about
    /// the frame holds
    func noteNativeStateChanged() {
        noteExternalFrameChange()
        frame.forget()
        invalidateMacosNativeWindowStateCache(windowId: windowId)
    }

    /// Native fullscreen, minimized, popup: macOS decides where these are
    var isOwnedByMacos: Bool {
        parent is MacosFullscreenWindowsContainer || parent is MacosMinimizedWindowsContainer || parent is MacosPopupWindowsContainer
    }

    var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    /// The frame as layout and commands should read it: our own write while WindowServer may still
    /// lag it, else WindowServer, else the app itself (AX)
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        if frame.windowServerMayLag(now: ProcessInfo.processInfo.systemUptime), let known = frame.bestKnown {
            return known
        }
        if let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: false) { return live }
        return try await MacOS.current.axFrame(windowId, cm)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await getAxRect(cm).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The best knowledge of the frame that asks nothing of macOS
    var knownFrame: Rect? { frame.bestKnown }

    /// A moved/resized notification for this window: `true` when it is our own write coming back
    /// (in flight, the app's answer, or WindowServer catching up), which needs no handling. Echoes
    /// used to wipe every frame cache and schedule a full heavy discovery — for every window of
    /// every layout.
    func isOwnFrameWrite() -> Bool { judgeFrameNotification() != .external }

    /// See `FrameRecord.windowServerReported`; `.lagging` asks the caller to look again later
    func judgeFrameNotification() -> FrameRecord.Report {
        let now = ProcessInfo.processInfo.systemUptime
        let report: FrameRecord.Report
        if isOwnedByMacos {
            // We never write to these, so nothing is an echo. Leaving native fullscreen puts the
            // window back exactly on its old tile — our last write's target — and read as our own
            // write, the stale "fullscreen" state was never re-read: the window stayed out of tiling
            report = .external
        } else if let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true) {
            report = frame.windowServerReported(
                live,
                now: now,
                isParkedOffScreen: hiddenCorner != nil && isOffEveryScreen(live),
            )
        } else {
            report = frame.windowServerMayLag(now: now) ? .ownWrite : .external // no WindowServer data: trust a recent write
        }
        if report == .external {
            // Entering or leaving native fullscreen is a frame change we didn't make, and nothing
            // else announces it: a stale "normal" kept a fullscreen video tiled — holding half the
            // workspace, and focused (pulling the user onto its Space) on every switch back
            invalidateMacosNativeWindowStateCache(windowId: windowId)
        } else {
            SessionStats.echoesSuppressed += 1
        }
        return report
    }

    /// The lag window is over: if WindowServer still doesn't show the window where we know it is,
    /// that wasn't lag — the app put its own frame back. True when it was an outside change.
    func recheckAfterLag() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard !frame.isAwaitingAnswer(now: now),
              let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true),
              let known = frame.bestKnown, !FrameRecord.near(live, known)
        else { return false }
        return frame.windowServerReported(live, now: now + FrameRecord.windowServerLagSeconds) == .external
    }

    /// At most a sliver (the 1px parking offset) on any screen
    func isOffEveryScreen(_ rect: Rect) -> Bool { isOffEveryScreenRect(rect, screens: monitors.map(\.rect)) }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        // Tiles and the fullscreen frame are layout's sizes, not the float's: recording them made
        // `layout floating` / center-window / sticky bring a float back at its tile (or screen) size
        if let size, isFloating, !isFullscreen { lastFloatingSize = size }
        let previous = frame.bestKnown
        guard let target = mergeFrameWrite(previous: previous, topLeft: topLeft, size: size) else {
            // Half a frame and nothing known to complete it: send it as asked, adopt the app's answer
            let windowId = windowId
            MacOS.current.writeFrame(windowId, topLeft: topLeft, size: size, trailingSize: true) { reported in
                deliverFrameAnswer(windowId: windowId, seq: nil, reported: reported)
            }
            return
        }
        let plan = planAxFrameWrite(
            previous: previous,
            previousInFlight: frame.isWriting,
            target: target,
            // A corner-parked window's centre is off every monitor: its "nearest monitor" may
            // be a neighbour, so treat it as crossing (full write, trailing size)
            crossesMonitor: previous.map { prev in
                !monitors.contains { $0.rect.contains(prev.center) }
                    || prev.center.monitorApproximation.rect != target.center.monitorApproximation.rect
            } ?? true,
            previousOverhangsScreen: previous.map { prev in
                let m = prev.center.monitorApproximation.rect
                return prev.minX < m.minX - 0.5 || prev.maxX > m.maxX + 0.5 || prev.minY < m.minY - 0.5 || prev.maxY > m.maxY + 0.5
            } ?? false,
        )
        let seq = frame.wrote(target, now: ProcessInfo.processInfo.systemUptime)
        FrameTrace.log("write \(windowId) prev=\(fmt(previous)) target=\(fmt(target)) plan=size:\(plan.size) pos:\(plan.position) trail:\(plan.trailingSize) hidden=\(hiddenCorner != nil)")
        let windowId = windowId
        MacOS.current.writeFrame(
            windowId,
            topLeft: plan.position ? target.topLeftCorner : nil,
            size: plan.size ? CGSize(width: target.width, height: target.height) : nil,
            trailingSize: plan.trailingSize,
        ) { reported in
            deliverFrameAnswer(windowId: windowId, seq: seq, reported: reported)
        }
    }

    /// The app answered a write (see `FrameRecord.appAnswered`)
    func frameAnswered(seq: UInt64?, reported: Rect?) {
        guard let seq else {
            // A half-frame write's answer must not overwrite a newer write still in flight
            if let reported, !frame.isWriting { frame.adopt(reported) }
            return
        }
        var outcome = frame.appAnswered(seq: seq, reported: reported, now: ProcessInfo.processInfo.systemUptime)
        // Parked: macOS keeps a sliver of the window reachable, so the corner is never exact
        if outcome == .missed, hiddenCorner != nil, let reported, isOffEveryScreen(reported) {
            frame.adopt(reported)
            outcome = .landed
        }
        FrameTrace.log("answer \(windowId) \(outcome) reported=\(fmt(reported))")
        switch outcome {
            case .landed, .stale:
                break
            case .appSized:
                // Not a cap yet: an app that resizes asynchronously answers with its old size and
                // gets there later. `confirmLearnedCap` decides once the answer has stood.
                break
            case .missed:
                // macOS refuses writes to a window it owns (native fullscreen, minimized): re-read
                // that state before believing the window is still ours to place
                invalidateMacosNativeWindowStateCache(windowId: windowId)
                // A visible tile whose frame never landed (a busy app dropped it, or took the size
                // before the move and lost it): its layout target is unchanged, so no pass would
                // ever rewrite it. Re-send, a bounded number of times.
                guard frame.shouldResend, parent is TilingContainer, nodeWorkspace?.isVisible == true,
                      currentlyManipulatedWithMouseWindowId != windowId // a drag's siblings still get theirs
                else { break }
                desiredRect = nil
                scheduleCancellableCompleteRefreshSession(.ax("frame-missed"))
        }
        // The border follows the window's real frame
        WindowBordersManager.shared.observe(windowId: windowId)
    }
}

@MainActor
extension Window {
    /// macOS has no max-size AX attribute: a tile whose app answered smaller than asked — and still
    /// is, per WindowServer, a while later — has a cap. Run before rendering, so the render gives
    /// the space it can't use to its siblings.
    func confirmLearnedCap() {
        guard learnedMaxSize == nil || capCandidate != nil else { return }
        guard parent is TilingContainer, currentlyManipulatedWithMouseWindowId == nil,
              let (target, actual) = frame.settledAppSize(now: ProcessInfo.processInfo.systemUptime),
              let live = WindowServerReads.current.windowBounds(windowId: windowId, forOverlay: true),
              FrameRecord.near(live, actual),
              let observed = learnedCap(target: target, actual: actual)
        else { return }
        // Confirmed per dimension: an earlier, different request answered with the same size
        let tol: CGFloat = 2
        let confirmedWidth = observed.width.isFinite && capCandidate.map {
            abs($0.target.width - target.width) > 24 && abs($0.actual.width - actual.width) <= tol
        } == true
        let confirmedHeight = observed.height.isFinite && capCandidate.map {
            abs($0.target.height - target.height) > 24 && abs($0.actual.height - actual.height) <= tol
        } == true
        guard confirmedWidth || confirmedHeight else {
            if capCandidate.map({ !FrameRecord.near($0.target, target) }) ?? true { capCandidate = (target, actual) }
            return
        }
        let cap = CGSize(width: confirmedWidth ? observed.width : .infinity, height: confirmedHeight ? observed.height : .infinity)
        guard cap != learnedMaxSize else { return }
        learnedMaxSize = cap
        learnedCapEvidence = (target, actual)
        FrameTrace.log("learned-cap \(windowId) cap=\(fmt(cap.width))x\(fmt(cap.height)) target=\(fmt(target)) actual=\(fmt(actual))")
    }
}

@MainActor
extension Window {
    /// A learned cap can't relax on its own: the tile is never asked for more than the cap, so the
    /// window is never seen larger (the only thing that dropped it). When the space its tile would
    /// get without the cap is no longer what it was when the cap was learned (a sibling closed, the
    /// layout changed, another monitor), ask again — the cap is dropped, and the old evidence kept as
    /// a candidate, so an app that is still capped re-confirms it on its first answer.
    func reprobeLearnedCapIfSlotChanged(uncappedSlot: Rect) {
        guard learnedMaxSize != nil, let evidence = learnedCapEvidence else { return }
        let tol: CGFloat = 24
        guard abs(uncappedSlot.width - evidence.target.width) > tol || abs(uncappedSlot.height - evidence.target.height) > tol else { return }
        learnedMaxSize = nil
        learnedCapEvidence = nil
        capCandidate = evidence
        FrameTrace.log("reprobe-cap \(windowId) slot=\(fmt(uncappedSlot))")
    }
}

/// A dimension the app answered meaningfully smaller than asked is capped; `.infinity` = no cap
/// there. Small differences (terminal cell rounding) are not caps.
func learnedCap(target: Rect, actual: Rect, tolerance: CGFloat = 24) -> CGSize? {
    let w: CGFloat = actual.width < target.width - tolerance ? actual.width : .infinity
    let h: CGFloat = actual.height < target.height - tolerance ? actual.height : .infinity
    return w.isFinite || h.isFinite ? CGSize(width: w, height: h) : nil
}

/// Hand the app's answer to the kernel. The simulator answers synchronously inside the job that
/// wrote; production answers from the app's AX thread
nonisolated func deliverFrameAnswer(windowId: UInt32, seq: UInt64?, reported: Rect?) {
    let apply: @MainActor @Sendable () -> Void = { Window.get(byId: windowId)?.frameAnswered(seq: seq, reported: reported) }
    if Thread.isMainThread, MainActor.assumeIsolated({ Kernel.isInsideJob }) {
        MainActor.assumeIsolated { apply() }
    } else {
        Kernel.submit("frame write answered") { apply() }
    }
}

/// At most a sliver (the 1px parking offset) of `rect` on any of `screens`
func isOffEveryScreenRect(_ rect: Rect, screens: [Rect]) -> Bool {
    !screens.contains { m in
        min(m.maxX, rect.maxX) - max(m.minX, rect.minX) > 4
            && min(m.maxY, rect.maxY) - max(m.minY, rect.minY) > 4
    }
}

struct FrameIntent: Equatable {
    var topLeft: CGPoint?
    var size: CGSize?
}

@MainActor
extension Window {
    /// Ask for this floating window to take `topLeft` and/or `size`. Merges with an earlier request
    /// in the same session (`resize … && center-window`); applied by the floating layout pass.
    func requestFrame(topLeft: CGPoint?, size: CGSize?) {
        frameIntent = FrameIntent(topLeft: topLeft ?? frameIntent?.topLeft, size: size ?? frameIntent?.size)
        if let size { lastFloatingSize = size }
    }

    /// The frame as a command should reason about it: pending requests over the window's frame
    func intendedFrame(_ cm: CancellationMode) async throws -> Rect? {
        let base = try await getAxRect(cm)
        guard let intent = frameIntent else { return base }
        guard let origin = intent.topLeft ?? base?.topLeftCorner,
              let size = intent.size ?? base.map({ CGSize(width: $0.width, height: $0.height) })
        else { return base }
        return Rect(topLeftX: origin.x, topLeftY: origin.y, width: size.width, height: size.height)
    }

    /// Render side: carry out a pending request
    func applyFrameIntent() {
        guard let intent = frameIntent else { return }
        frameIntent = nil
        setAxFrame(intent.topLeft, intent.size)
    }
}
