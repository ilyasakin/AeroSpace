import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?
    // The corner the window is already parked in. Skips re-hiding an already hidden window on every refresh.
    // Reset when the window moves externally (invalidateAxFrameCaches) so an escaped window gets re-hidden
    private var hiddenCorner: OptimalHideCorner?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        let workspace = isStartup
            ? (rect?.center.monitorApproximation ?? mainMonitor).activeWorkspace
            : focus.workspace
        let windowLevel = getWindowLevel(for: windowId)
        let windowType = try await macApp.resolveWindowType(windowId, windowLevel, .cancellable)

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }

        let window: MacWindow
        switch windowType {
            case .popup:
                window = MacWindow(
                    windowId, macApp, lastFloatingSize: rect?.size,
                    parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST,
                )
            case .dialog:
                window = MacWindow(
                    windowId, macApp, lastFloatingSize: rect?.size,
                    parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST,
                )
            case .window:
                // Park floating first; path-copy place into tiling spine then materialize (dual-link rebuilt)
                window = MacWindow(
                    windowId, macApp, lastFloatingSize: rect?.size,
                    parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST,
                )
                allWindowsMap[windowId] = window
                _ = workspace.commitTilingPlaceNewWindow(id: windowId)
        }
        if windowType != .window {
            allWindowsMap[windowId] = window
        }

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await tryOnWindowDetected(window)
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    @MainActor
    func resolveWindowType(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        try await macApp.resolveWindowType(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        invalidateMacosNativeWindowStateCache(windowId: windowId)
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    @MainActor override func nativeRaise() {
        macApp.raiseWindow(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
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
                let onePixelOffset = macApp.rawAppBundleId == zoomAppBundleId ? .zero : CGPoint(x: 1, y: -1)
                // Park at the physical monitor corner, not visibleRect's. visibleRect excludes the Dock,
                // so parking there leaves a Dock-height 1px strip of the window visible at the screen edge
                p = nodeMonitor.rect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.rawAppBundleId == zoomAppBundleId ? .zero : CGPoint(x: 1, y: 1)
                // Park at the physical monitor corner, not visibleRect's (see bottomLeftCorner comment)
                p = nodeMonitor.rect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
        hiddenCorner = corner
        // The window is parked in the corner now. Force the next layout pass to re-apply the real
        // frame, otherwise the frame diffing in layoutRecursive would keep the window in the corner
        lastAppliedLayoutPhysicalRect = nil
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
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

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        self.hiddenCorner = nil
    }

    // Called when the window's AX frame or native state may have changed behind aerospace's back
    // (moved/resized/miniaturized/deminiaturized AX notifications). Drops all the state that
    // the refresh fast paths rely on, so the next refresh re-reads and re-applies everything
    @MainActor
    func invalidateAxFrameCaches() {
        lastAppliedLayoutPhysicalRect = nil
        hiddenCorner = nil
        invalidateMacosNativeWindowStateCache(windowId: windowId)
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        switch resolveFrameRead(
            windowId: windowId,
            lastApplied: lastAppliedLayoutPhysicalRect,
            mayBeStale: skyLightFrameMayBeStale(windowId),
            serverBounds: { WindowServerReads.current.windowBounds(windowId: $0, forOverlay: false) },
        ) {
            case .lastApplied(let r): return CGSize(width: r.width, height: r.height)
            case .windowServer(let r): return CGSize(width: r.width, height: r.height)
            case .needAx: return try await macApp.getAxSize(windowId, cm)
        }
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        markFrameWrittenThisSession(windowId) // subsequent same-session reads must bypass the lagging SkyLight
        // Merge partial writes into lastApplied so chained commands (resize → center) see the
        // intended size/position, and so we always submit a full frame to MacApp (which cancels
        // the previous AX job per window — size-only then position-only would drop the size).
        if let merged = mergeFrameWrite(previous: lastAppliedLayoutPhysicalRect, topLeft: topLeft, size: size) {
            lastAppliedLayoutPhysicalRect = merged
            if let size { lastFloatingSize = size }
            macApp.setAxFrame(
                windowId,
                merged.topLeftCorner,
                CGSize(width: merged.width, height: merged.height),
            )
        } else {
            if let size { lastFloatingSize = size }
            macApp.setAxFrame(windowId, topLeft, size)
        }
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        switch resolveFrameRead(
            windowId: windowId,
            lastApplied: lastAppliedLayoutPhysicalRect,
            mayBeStale: skyLightFrameMayBeStale(windowId),
            serverBounds: { WindowServerReads.current.windowBounds(windowId: $0, forOverlay: false) },
        ) {
            case .lastApplied(let r): return r
            case .windowServer(let r): return r
            case .needAx: return try await macApp.getAxRect(windowId, cm)
        }
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        if forceTile {
            // Path-copy place into tiling spine (unbind via materialize)
            bindAsFloatingWindow(to: workspace)
            _ = workspace.commitTilingPlaceNewWindow(id: windowId)
            return
        }
        let mac = asMacWindow()
        let windowLevel = getWindowLevel(for: windowId)
        let windowType = try await mac.macApp.resolveWindowType(windowId, windowLevel, cm)
        switch windowType {
            case .popup:
                bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .dialog:
                bindAsFloatingWindow(to: workspace)
            case .window:
                bindAsFloatingWindow(to: workspace)
                _ = workspace.commitTilingPlaceNewWindow(id: windowId)
        }
    }
}

@MainActor
func tryOnWindowDetected(_ window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                // Cheap in-process checks first. The window-title check needs an AX round-trip
                // (getTitle), so it must run LAST — after appId/appName/workspace can reject
                if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
                    return false
                }
                if let appId = matcher.appId, appId != window.app.rawAppBundleId {
                    return false
                }
                if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
                    return false
                }
                if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
                    return false
                }
                if let regex = matcher.windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
                    return false
                }
                return true
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}
