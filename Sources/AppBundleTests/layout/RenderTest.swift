@testable import AppBundle
import Common
import XCTest

/// Step 4: layout is a pure `render` plus a separate apply
@MainActor
final class RenderTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRenderingChangesNothing() {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        let b = TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 3)
        let result = render(ws, spine: PersistentTilingNode.capture(ws.rootTilingContainer))

        XCTAssertEqual(result.tiles.map(\.windowId), [1, 2])
        XCTAssertEqual(result.tiles[1].physical.width / result.tiles[0].physical.width, 3, accuracy: 0.05, "weights are proportions")
        // Nothing was written: no intent recorded, no frame sent, weights as they were
        XCTAssertNil(a.desiredRect)
        XCTAssertNil(b.laidOutRect)
        XCTAssertTrue(SimulatedMacOS.shared.frameWrites.isEmpty)
        XCTAssertEqual(a.hWeight, 1)
        XCTAssertEqual(b.hWeight, 3)
    }

    func testLayoutNoLongerRewritesWeightsAsPixels() async throws {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        try await HeadlessHarness.run("balance-sizes")
        XCTAssertEqual(a.hWeight, 1, "weights are the model's; spans are the render's")
        XCTAssertGreaterThan(a.laidOutRect?.width ?? 0, 100)
    }

    func testPixelResizeIsPixelsWhateverTheWeightUnits() async throws {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        _ = a.focusWindow()
        try await HeadlessHarness.run("balance-sizes")
        let before = try XCTUnwrap(a.laidOutRect).width
        try await HeadlessHarness.run("resize width +100")
        XCTAssertEqual(try XCTUnwrap(a.laidOutRect).width - before, 100, accuracy: 2)
    }
}

/// The render stays a pure function: no effects, no knowledge of macOS, no mutation
final class RenderPurityTest: XCTestCase {
    func testRenderHasNoEffects() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AppBundle/layout/render.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .joined(separator: "\n")
        for effect in ["async", "await", "setAxFrame", "desiredRect", "lastAppliedLayout", "setWeight", "MacOS.",
                       "WindowServerReads", ".frame", "hideInCorner", "bind(", "unbindFromParent"]
            where code.contains(effect)
        {
            XCTFail("render.swift uses `\(effect)` — render computes; applying is the reconciler's job")
        }
    }
}
