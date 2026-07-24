@testable import AppBundle
import Common
import XCTest

/// The spine ↔ live-tree contract is what the whole tiling model rests on, and it was historically
/// maintained by hand (missed invalidations silently rendered a stale layout, or crashed weight
/// sync). These tests prove the guard actually fires — a safety net nobody has tripped on purpose
/// is not a safety net.
@MainActor
final class SpineInvariantTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        SpineInvariant.resetForTests()
    }

    override func tearDown() async throws {
        SpineInvariant.resetForTests()
    }

    func testCleanCommitPassesVerification() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        // A real commit publishes a generation that must describe the live tree.
        XCTAssertTrue(workspace.commitTilingInsertWindow(id: 3))
        XCTAssertEqual(SpineInvariant.violationCount, 0, "a clean commit must not report a desync")
    }

    func testDetectsStaleGenerationAfterUnprotectedLiveMutation() {
        let workspace = Workspace.get(byName: name)
        var w1: Window!
        workspace.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        // Publish a generation, then mutate the LIVE tree behind the spine's back while
        // suppressing invalidation — exactly what a mutation site that forgets the protocol does.
        _ = workspace.currentTilingSpine()
        unsafe Workspace.suppressTilingGenerationInvalidation = true
        w1.unbindFromParent()
        unsafe Workspace.suppressTilingGenerationInvalidation = false

        nonisolated(unsafe) var reported: [String] = []
        SpineInvariant.onViolationForTests = { reported.append($0) }
        SpineInvariant.verify(workspace, context: "unit-test forced desync")

        XCTAssertEqual(SpineInvariant.violationCount, 1)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].contains("desync"), "violation must be described: \(reported[0])")
        XCTAssertNil(
            workspace.tilingStructureGeneration,
            "production self-heal drops the stale generation so the next layout recaptures live",
        )
    }

    func testNoGenerationPublishedIsNotAViolation() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply { TestWindow.new(id: 1, parent: $0) }
        workspace.invalidateTilingStructureGeneration()
        SpineInvariant.verify(workspace, context: "no published generation")
        XCTAssertEqual(SpineInvariant.violationCount, 0, "nothing published → nothing to contradict")
    }
}
