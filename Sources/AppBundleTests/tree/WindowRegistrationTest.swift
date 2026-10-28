@testable import AppBundle
import Common
import XCTest

/// Registration policy is model code (step 2 moved it out of the macOS port), so it runs headlessly
@MainActor
final class WindowRegistrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func register(_ id: UInt32, _ type: AxUiElementWindowType = .window) async throws -> Window {
        try await registerDiscoveredWindow(windowId: id, appBundleId: nil, frame: nil, windowType: type) { parent in
            TestWindow.new(id: id, parent: parent)
        }
    }

    func testANewWindowJoinsTheFocusedWorkspacesTiling() async throws {
        let window = try await register(1)
        XCTAssertEqual(window.nodeWorkspace, focus.workspace)
        XCTAssertTrue(window.parent is TilingContainer)
    }

    func testAWindowThatVanishedBrieflyReturnsToItsWorkspace() async throws {
        WindowMemory.noteLeaving(windowId: 5, from: "7")
        let window = try await register(5)
        XCTAssertEqual(window.nodeWorkspace?.name, "7")
    }

    func testDialogsFloatAndPopupsStayOutOfTheWorkspace() async throws {
        let dialog = try await register(2, .dialog)
        XCTAssertTrue(dialog.isFloating)
        let popup = try await register(3, .popup)
        XCTAssertNil(popup.nodeWorkspace)
    }

    func testRegisteringAKnownIdReturnsTheSameWindow() async throws {
        let first = try await register(4)
        let again = try await register(4)
        XCTAssertTrue(first === again)
    }
}
