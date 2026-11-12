@testable import AppBundle
import Common
import XCTest

/// A focus notification that names its window (or our own request activating its app) is taken
/// as macOS's report without asking the app again
@MainActor
final class FocusHintTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        FocusReconciler.resetForTests()
    }

    func testAHintedSessionFollowsTheNamedWindow() async throws {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = a.focusWindow()
        try await SessionPipeline.$nativeFocusHint.withValue(2) {
            try await runLightSession(.ax("AXFocusedWindowChanged"), .forceRun) {}
        }
        XCTAssertEqual(focus.windowOrNil?.windowId, 2, "the user focused window 2 (the notification said so)")
    }

    func testAPendingRequestBelongsToItsApp() async throws {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = b.focusWindow()
        FocusReconciler.reconcile() // the model's focus goes out as a request
        XCTAssertEqual(FocusReconciler.pendingRequest(forAppPid: TestApp.shared.pid), 2)
        XCTAssertNil(FocusReconciler.pendingRequest(forAppPid: 4242), "another app's activation is not our echo")
    }
}
