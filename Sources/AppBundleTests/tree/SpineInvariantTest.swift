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

    /// The suppression flag is process-global. Before `withSuppressedGenerationInvalidation` it
    /// was set/reset by bare assignment at three sites, so a throw or cancellation in between
    /// (layoutWorkspace is `async throws`) left it stuck `true` — silently disabling invalidation
    /// for the entire process and turning every later mutation into a stale-spine desync.
    func testSuppressionIsRestoredWhenBodyThrows() {
        struct Boom: Error {}
        XCTAssertFalse(unsafe Workspace.suppressTilingGenerationInvalidation)
        XCTAssertThrowsError(
            try Workspace.withSuppressedGenerationInvalidation {
                XCTAssertTrue(unsafe Workspace.suppressTilingGenerationInvalidation, "suppressed inside")
                throw Boom()
            },
        )
        XCTAssertFalse(
            unsafe Workspace.suppressTilingGenerationInvalidation,
            "a throwing body must not leave invalidation disabled process-wide",
        )
    }

    /// Nesting must not have the inner scope cancel the outer one's suppression.
    func testSuppressionNests() {
        Workspace.withSuppressedGenerationInvalidation {
            Workspace.withSuppressedGenerationInvalidation {}
            XCTAssertTrue(
                unsafe Workspace.suppressTilingGenerationInvalidation,
                "inner scope must restore to the outer scope's value, not to false",
            )
        }
        XCTAssertFalse(unsafe Workspace.suppressTilingGenerationInvalidation)
    }

    func testNoGenerationPublishedIsNotAViolation() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply { TestWindow.new(id: 1, parent: $0) }
        workspace.invalidateTilingStructureGeneration()
        SpineInvariant.verify(workspace, context: "no published generation")
        XCTAssertEqual(SpineInvariant.violationCount, 0, "nothing published → nothing to contradict")
    }
}
