@testable import AppBundle
import XCTest

/// Criterion 3: test windows implement frame / title / focus without hitting Window.die stubs.
@MainActor
final class TestWindowCompletenessTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    func testFrameTitleFocusAndCornerDoNotDie() async throws {
        let ws = Workspace.get(byName: "test")
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 400)
        let window = TestWindow.new(id: 99, parent: ws.rootTilingContainer, rect: rect)

        // Frame
        let got = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(got, rect)
        let size = try await window.getAxSize(.nonCancellable)
        XCTAssertEqual(size, CGSize(width: 300, height: 400))

        window.setAxFrame(CGPoint(x: 50, y: 60), CGSize(width: 120, height: 80))
        let after = try await window.getAxRect(.nonCancellable)
        XCTAssertEqual(after, Rect(topLeftX: 50, topLeftY: 60, width: 120, height: 80))

        // Title
        let title = try await window.getTitle(.nonCancellable)
        XCTAssertTrue(title.contains("99"))

        // Focus
        window.nativeFocus()
        XCTAssertTrue(TestApp.shared.focusedWindow === window)

        // Corner hide flag (base Window would die)
        XCTAssertFalse(window.isHiddenInCorner)

        // Center uses getAxRect
        let center = try await window.getCenter(.nonCancellable)
        XCTAssertEqual(center, CGPoint(x: 50 + 60, y: 60 + 40))
    }

    func testWindowGetByIdFindsTestWindow() {
        let ws = Workspace.get(byName: "test")
        let window = TestWindow.new(id: 1234, parent: ws.rootTilingContainer)
        XCTAssertTrue(Window.get(byId: 1234) === window)
    }
}
