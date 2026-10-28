@testable import AppBundle
import Common
import XCTest

/// Step 6: one memory of windows that left, one order of trust
@MainActor
final class WindowMemoryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTheLastSessionIsTrustedBeforeADeparture() {
        WindowMemory.noteLeaving(windowId: 7, from: "3")
        WindowMemory.rememberLastSession([(savedId: 7, workspace: "5", app: nil)])
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 7, appId: nil)?.name, "5")
        // Consumed: the departure is what's left
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 7, appId: nil)?.name, "3")
        XCTAssertNil(WindowMemory.recallWorkspace(windowId: 7, appId: nil))
    }

    func testAfterARebootAnAppsWindowsAreMatchedByApp() {
        WindowMemory.rememberLastSession([(savedId: 100, workspace: "2", app: "term"), (savedId: 101, workspace: "2", app: "term")])
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 900, appId: "term")?.name, "2")
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 901, appId: "term")?.name, "2")
        XCTAssertNil(WindowMemory.recallWorkspace(windowId: 902, appId: "term"))
    }

    func testAnAppSpreadOverWorkspacesIsNotMatchedByOrder() {
        WindowMemory.rememberLastSession([(savedId: 100, workspace: "1", app: "term"), (savedId: 101, workspace: "2", app: "term")])
        XCTAssertNil(WindowMemory.recallWorkspace(windowId: 900, appId: "term"), "ambiguous: would shuffle them")
    }

    func testWorkspaceAndSlotAreConsumedIndependently() {
        let ws = focus.workspace
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let leaving = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        WindowMemory.noteLeaving(leaving, from: ws.name)
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 2, appId: nil), ws)
        XCTAssertNotNil(WindowMemory.takeSlot(windowId: 2, on: ws.name), "the slot outlives the workspace recall")
        XCTAssertNil(WindowMemory.takeSlot(windowId: 2, on: ws.name))
    }

    func testRenameReachesEveryKindOfMemory() {
        WindowMemory.noteLeaving(windowId: 1, from: "old")
        WindowMemory.rememberLastSession([(savedId: 2, workspace: "old", app: nil)])
        _ = Workspace.get(byName: "old").rename(to: "new")
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 1, appId: nil)?.name, "new")
        XCTAssertEqual(WindowMemory.recallWorkspace(windowId: 2, appId: nil)?.name, "new")
    }

    func testTheMemoryIsBounded() {
        for id in 0 ..< UInt32(WindowMemory.capacity + 10) { WindowMemory.noteLeaving(windowId: id, from: "1") }
        XCTAssertNil(WindowMemory.recallDeparture(windowId: 0), "oldest forgotten")
        XCTAssertNotNil(WindowMemory.recallDeparture(windowId: UInt32(WindowMemory.capacity + 9)))
    }

    func testThereIsOneMemory() throws {
        let appBundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle")
        let gone = ["RememberedWorkspaces", "DepartedTileSlots", "closedWindowsCache", "pendingById", "pendingByApp",
                    "cacheClosedWindowIfNeeded", "restoreClosedWindowsCacheIfNeeded", "resetClosedWindowsCache"]
        for file in FileManager.default.enumerator(at: appBundle, includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
            where file.pathExtension == "swift"
        {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
                .joined(separator: "\n")
            for name in gone where code.contains(name) {
                XCTFail("\(file.lastPathComponent) has `\(name)` — departed windows are remembered in WindowMemory only")
            }
        }
    }
}
