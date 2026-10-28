@testable import AppBundle
import Common
import XCTest

/// Bugs from the post-re-architecture hunt: wrong assumptions about how macOS behaves
@MainActor
final class HuntRegressionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// cmd-W on ws1: macOS makes another window of the same app key — one parked on ws3. That is
    /// its automatic hand-off, not the user going to ws3
    func testClosingAWindowDoesNotFollowMacosToAHiddenWorkspace() {
        let ws1 = Workspace.get(byName: "1")
        let ws3 = Workspace.get(byName: "3")
        let next = TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: ws1.rootTilingContainer)
        let elsewhere = TestWindow.new(id: 3, parent: ws3.rootTilingContainer)
        _ = closing.focusWindow()
        FocusReconciler.macosReported(closing)

        closing.garbageCollect(skipClosedWindowsCache: true)
        FocusReconciler.macosReported(elsewhere)

        XCTAssertEqual(focus.workspace, ws1, "stays on the workspace")
        XCTAssertTrue(focus.windowOrNil === next)
    }

    func testAPopupDoesNotUseUpItsAppsRememberedPlacement() async throws {
        WindowMemory.rememberLastSession([(savedId: 50, workspace: "4", app: "app")])
        _ = try await registerDiscoveredWindow(windowId: 900, appBundleId: "app", frame: nil, windowType: .popup) { parent in
            TestWindow.new(id: 900, parent: parent)
        }
        let real = try await registerDiscoveredWindow(windowId: 901, appBundleId: "app", frame: nil, windowType: .window) { parent in
            TestWindow.new(id: 901, parent: parent)
        }
        XCTAssertEqual(real.nodeWorkspace?.name, "4")
    }

    func testAWindowLeavingFromNativeFullscreenKeepsItsTile() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let fs = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        ws.captureTileRestorePoint(for: fs)
        fs.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        fs.garbageCollect(skipClosedWindowsCache: true)
        XCTAssertNotNil(WindowMemory.takeSlot(windowId: 2, on: ws.name), "its old tile, not nothing")
    }

    /// A tile dragged a little and dropped over its own slot must snap back
    func testADroppedTileIsRelaidOut() async throws {
        let ws = focus.workspace
        let dragged = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        try await HeadlessHarness.run("balance-sizes")
        currentlyManipulatedWithMouseWindowId = dragged.windowId
        try await resetManipulatedWithMouseIfPossible()
        XCTAssertNil(dragged.desiredRect, "the next layout rewrites it")
    }

    /// ws D: TV went native fullscreen while AeroSpace's cache said "normal". The fast path trusted
    /// the cache on every pass, so the fullscreen window kept half the workspace as a tile
    func testAWindowGoingNativeFullscreenIsNoticedDespiteAStaleCache() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        defer { WindowServerReads.install(nil) }
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let tv = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        seedMacosNativeWindowStateCacheForTests(windowId: 2, MacosNativeWindowState(isFullscreen: false, isMinimized: false))
        SimulatedMacOS.shared.fullscreen.insert(2)
        SimulatedMacOS.shared.frames[2] = ws.workspaceMonitor.rect

        XCTAssertEqual(tv.judgeFrameNotification(), .external, "macOS moved it, not us")
        try await normalizeLayoutReason()
        XCTAssertTrue(tv.parent is MacosFullscreenWindowsContainer, "out of the tiling")
    }

    /// The same window, when no frame notification came: macOS refusing our write gives it away
    func testARefusedWriteRereadsNativeState() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let tv = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        seedMacosNativeWindowStateCacheForTests(windowId: 2, MacosNativeWindowState(isFullscreen: false, isMinimized: false))
        SimulatedMacOS.shared.fullscreen.insert(2)

        let seq = tv.frame.wrote(Rect(topLeftX: 16, topLeftY: 40, width: 500, height: 500), now: ProcessInfo.processInfo.systemUptime)
        tv.frameAnswered(seq: seq, reported: ws.workspaceMonitor.rect)
        try await normalizeLayoutReason()
        XCTAssertTrue(tv.parent is MacosFullscreenWindowsContainer)
    }

    /// Switching to a workspace whose only window is native fullscreen must not focus it: that
    /// took the user onto the fullscreen Space instead of the workspace they asked for
    func testSwitchingToAWorkspaceNeverFocusesAWindowMacosOwns() async throws {
        let home = focus.workspace
        TestWindow.new(id: 1, parent: home.rootTilingContainer).focusWindow()
        let d = Workspace.get(byName: "D")
        let tv = TestWindow.new(id: 2, parent: d.rootTilingContainer)
        tv.bind(to: d.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)

        try await HeadlessHarness.run("workspace D")
        XCTAssertEqual(focus.workspace, d)
        XCTAssertNil(focus.windowOrNil, "shown empty, not the fullscreen window")

        let discord = TestWindow.new(id: 3, parent: d.rootTilingContainer)
        try await HeadlessHarness.run(["workspace \(home.name)", "workspace D"])
        XCTAssertTrue(focus.windowOrNil === discord)
    }

    /// After a restart macOS kept a terminal parked on hidden ws 3 key while the model said Safari on
    /// ws 1; every report was "unchanged" and recorded the model's focus as macOS's, so neither side
    /// ever moved (20 s of typing into an invisible window)
    func testAModelFocusThatMovedOnItsOwnIsStillSentAfterAnUnchangedReport() {
        let ws = focus.workspace
        let safari = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let terminal = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = terminal.focusWindow()
        FocusReconciler.macosReported(terminal)
        _ = safari.focusWindow() // the model moves without a session end (restore)
        FocusReconciler.macosReported(terminal)
        XCTAssertTrue(FocusReconciler.record.needsRequest(for: 1, now: ProcessInfo.processInfo.systemUptime), "the model's focus goes out")
    }

    func testATileWriteDoesNotBecomeTheFloatingSize() {
        let w = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        w.lastFloatingSize = CGSize(width: 800, height: 600)
        w.setAxFrame(CGPoint(x: 16, y: 40), CGSize(width: 1264, height: 1384))
        XCTAssertEqual(w.lastFloatingSize, CGSize(width: 800, height: 600), "`layout floating` brings back 800x600")
    }

    /// Leaving native fullscreen restores the old tile frame — our last write's target. It is
    /// still macOS's doing: the cached "fullscreen" must be re-read, or the window never re-tiles
    func testLeavingNativeFullscreenOntoTheOldTileIsNoticed() async throws {
        WindowServerReads.install(SimulatedWindowServer())
        defer { WindowServerReads.install(nil) }
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let tv = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        let tile = Rect(topLeftX: 1288, topLeftY: 40, width: 1256, height: 1383)
        let seq = tv.frame.wrote(tile, now: ProcessInfo.processInfo.systemUptime)
        tv.frameAnswered(seq: seq, reported: tile)
        ws.captureTileRestorePoint(for: tv)
        tv.layoutReason = .macos(prevParentKind: .tilingContainer)
        tv.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        ws.settleTileRestorePoint(for: tv)
        seedMacosNativeWindowStateCacheForTests(windowId: 2, MacosNativeWindowState(isFullscreen: true, isMinimized: false))
        SimulatedMacOS.shared.frames[2] = tile // macOS put it back exactly

        XCTAssertEqual(tv.judgeFrameNotification(), .external)
        try await normalizeLayoutReason()
        XCTAssertTrue(tv.parent is TilingContainer, "back in the tiling")
    }

    func testAFloatComesBackFromTheCornerAtItsOwnSize() async throws {
        let ws = focus.workspace
        let w = TestWindow.new(id: 1, parent: ws.floatingWindowsContainer)
        SimulatedMacOS.shared.frames[1] = Rect(topLeftX: 300, topLeftY: 300, width: 800, height: 600)
        try await w.hideInCorner(.bottomRightCorner)
        // macOS clamps the parked window
        SimulatedMacOS.shared.frames[1] = Rect(topLeftX: 2559, topLeftY: 1412, width: 500, height: 400)
        w.frame.forget()
        w.unhideFromCorner()
        XCTAssertEqual(SimulatedMacOS.shared.frameWrites.last?.size, CGSize(width: 800, height: 600))
    }

    /// A background window closing must not move the focus off a native-fullscreen window
    func testABackgroundWindowClosingKeepsTheFocus() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let fs = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        let job = TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        _ = fs.focusWindow()
        fs.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        job.garbageCollect(skipClosedWindowsCache: true)
        XCTAssertTrue(focus.windowOrNil === fs)
    }

    /// `workspace 2`, then within a second some window on the old workspace closes: stay on 2
    func testAWindowClosingOnTheWorkspaceJustLeftDoesNotPullBack() async throws {
        let ws1 = focus.workspace
        TestWindow.new(id: 1, parent: ws1.rootTilingContainer).focusWindow()
        let toast = TestWindow.new(id: 2, parent: ws1.rootTilingContainer)
        let ws2 = Workspace.get(byName: "2")
        TestWindow.new(id: 3, parent: ws2.rootTilingContainer)
        try await HeadlessHarness.run("workspace 2")
        toast.garbageCollect(skipClosedWindowsCache: true)
        XCTAssertEqual(focus.workspace, ws2)
    }

    /// cmd-M on ws1: macOS hands focus to another window of the app — parked on ws3 — and the heavy
    /// that sees both reads macOS's focus first. The minimize must be known before that report
    func testMinimizingInAHeavyDoesNotFollowMacosToAHiddenWorkspace() async {
        let ws1 = focus.workspace
        let ws3 = Workspace.get(byName: "3")
        TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        let minimizing = TestWindow.new(id: 2, parent: ws1.rootTilingContainer)
        let elsewhere = TestWindow.new(id: 3, parent: ws3.rootTilingContainer)
        _ = minimizing.focusWindow()
        FocusReconciler.macosReported(minimizing)

        SimulatedMacOS.shared.minimized.insert(2)
        TestApp.shared.focusedWindow = elsewhere
        await HeadlessHarness.heavy()

        XCTAssertEqual(focus.workspace, ws1, "macOS's hand-off, not the user")
    }

    /// cmd-H: the focused window is parked with its hidden app. It must stop being the focus —
    /// `close`/`move` acted on an invisible window, and asking macOS to focus it unhid the app
    func testAHiddenAppsWindowIsNotTheFocus() {
        defer { TestApp.shared.isHidden = false }
        let ws = focus.workspace
        let other = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let hidden = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = other.focusWindow()
        _ = hidden.focusWindow()
        TestApp.shared.isHidden = true
        hidden.bind(to: ws.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        XCTAssertTrue(focus.windowOrNil === other)
        TestApp.shared.isHidden = false
        XCTAssertTrue(focus.windowOrNil === hidden, "a background native tab parked the same way stays focusable")
    }

    func testFocusBackAndForthToAClosedWindowFails() async throws {
        let ws1 = focus.workspace
        let gone = TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        _ = gone.focusWindow()
        let ws2 = Workspace.get(byName: "2")
        TestWindow.new(id: 2, parent: ws2.rootTilingContainer)
        try await HeadlessHarness.run("workspace 2")
        prevFocusedWorkspaceDate = .distantPast // long after the switch
        gone.garbageCollect(skipClosedWindowsCache: true)
        let result = try await HeadlessHarness.run("focus-back-and-forth")
        XCTAssertEqual(result.exitCode, .fail)
        XCTAssertEqual(focus.workspace, ws2)
    }

    /// A title that changed while the window wasn't on a tab: the tab shown later must not read the
    /// registration-time title
    func testATabShowsTheCurrentTitleOfAWindowRetitledBeforeJoining() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        let ws = focus.workspace
        let w = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = w.focusWindow()
        w.cachedTitle = "registration title"
        SimulatedMacOS.shared.titles[1] = "current title"
        w.cachedTitleIsStale = true // what the title-changed notification records off a tab
        try await HeadlessHarness.run("layout h_accordion")
        XCTAssertEqual(w.cachedTitle, "current title")
    }

    /// A reload that put a new title rule in front: the rule that ran must still count as run, and
    /// the new one must not be mistaken for it
    func testDetectionRulesSurviveAReloadThatReordersThem() async throws {
        let before = parseConfig("""
            [[on-window-detected]]
            if.window-title-regex-substring = 'Inbox'
            run = 'layout floating'
            """).config.onWindowDetected
        config.onWindowDetected = before
        let ws = focus.workspace
        let w = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        w.titleForTest = "Inbox - Mail"
        await tryOnWindowDetected(w)
        XCTAssertFalse(w.hasPendingTitleRules)

        config.onWindowDetected = parseConfig("""
            [[on-window-detected]]
            if.window-title-regex-substring = 'Calendar'
            run = 'layout tiling'

            [[on-window-detected]]
            if.window-title-regex-substring = 'Inbox'
            run = 'layout floating'
            """).config.onWindowDetected
        XCTAssertTrue(w.hasPendingTitleRules, "the new Calendar rule hasn't run")
        XCTAssertTrue(w.isFloating)
        w.titleForTest = "Calendar"
        await onWindowTitleChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, w)
        XCTAssertFalse(w.isFloating, "the new rule ran (by index it looked like the Inbox rule, already run)")
    }

    /// A restart while typing in a terminal on ws 2: at launch every window registers on the focused
    /// workspace, then the restore moves the terminal home. The focus must go with it — left
    /// behind, ws 1's Safari was pushed to macOS and the user was pulled off their terminal
    func testARestoreKeepsTheUserOnTheWindowTheyHadFocused() throws {
        let url = SessionLayoutStore.fileUrl
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let ws1 = Workspace.get(byName: "1")
        let ws2 = Workspace.get(byName: "2")
        let safari = TestWindow.new(id: 1, parent: ws1.rootTilingContainer)
        let terminal = TestWindow.new(id: 2, parent: ws2.rootTilingContainer)
        _ = terminal.focusWindow()
        SessionLayoutStore.saveNow()

        // Relaunch: discovery put everything on the startup workspace, macOS still has the terminal
        terminal.bind(to: ws1.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        _ = terminal.focusWindow()
        FocusReconciler.macosReported(terminal)
        XCTAssertTrue(SessionLayoutStore.restoreIfPossible())

        XCTAssertEqual(terminal.nodeWorkspace, ws2)
        XCTAssertTrue(focus.windowOrNil === terminal, "not \(focus.windowOrNil?.windowId ?? 0) (Safari is \(safari.windowId))")
        XCTAssertEqual(focus.workspace, ws2)
    }
}
