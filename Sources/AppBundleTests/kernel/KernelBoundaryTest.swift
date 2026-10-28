@testable import AppBundle
import Common
import XCTest

/// Step 1 of the re-architecture: the kernel is the one writer. These guard the boundary — jobs
/// never interleave, a spawned task never runs "inside" its creator, and every event path that
/// changes the model does so inside a job.
@MainActor
final class KernelBoundaryTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        Kernel.resetViolationsForTests()
    }

    // MARK: - Serialization

    func testJobsNeverInterleaveAcrossSuspensionPoints() async {
        var log: [String] = []
        let first = Task.startUnstructured { @MainActor in
            await Kernel.exclusive("first") {
                log.append("first start")
                try? await Task.sleep(nanoseconds: 20_000_000) // a suspension point, like an AX read
                log.append("first end")
            }
        }
        await Task.yield()
        let second = Task.startUnstructured { @MainActor in
            await Kernel.exclusive("second") { log.append("second") }
        }
        await first.value
        await second.value
        XCTAssertEqual(log, ["first start", "first end", "second"])
    }

    func testJobsRunInSubmissionOrder() async {
        var log: [Int] = []
        var tasks: [Task<Void, Never>] = []
        for i in 0 ..< 5 {
            tasks.append(Task.startUnstructured { @MainActor in
                await Kernel.exclusive("ordered") {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    log.append(i)
                }
            })
            await Task.yield()
        }
        for t in tasks { await t.value }
        XCTAssertEqual(log, [0, 1, 2, 3, 4])
    }

    func testTheJobItselfReentersInline() async {
        // A session calling another job-wrapped entry (startup → heavy → light) must not deadlock
        let result = await Kernel.exclusive("outer") {
            await Kernel.exclusive("inner") { 42 }
        }
        XCTAssertEqual(result, 42)
    }

    func testATaskSpawnedByAJobWaitsForItInsteadOfRunningInside() async {
        var log: [String] = []
        var spawned: Task<Void, Never>?
        await Kernel.exclusive("parent") {
            spawned = Task.startUnstructured { @MainActor in
                await Kernel.exclusive("child") { log.append("child") }
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // the child gets every chance to barge in
            log.append("parent end")
        }
        await spawned?.value
        XCTAssertEqual(log, ["parent end", "child"])
    }

    // MARK: - Mutations only inside jobs

    func testMutationOutsideAJobIsAViolationInsideIsNot() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        Kernel.resetViolationsForTests()
        await Kernel.exclusive("inside") { window.desiredRect = Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1) }
        XCTAssertEqual(Kernel.violations, [])
        window.desiredRect = nil
        XCTAssertEqual(Kernel.violations, ["desiredRect"])
    }

    func testCommandSessionsMutateOnlyInsideJobs() async throws {
        let root = focus.workspace.rootTilingContainer
        _ = TestWindow.new(id: 1, parent: root)
        _ = TestWindow.new(id: 2, parent: root)
        _ = TestWindow.new(id: 3, parent: root)
        Kernel.resetViolationsForTests()
        try await HeadlessHarness.run([
            "focus left", "move right", "split vertical", "layout accordion horizontal",
            "resize width +50", "workspace 2", "workspace 1", "move-node-to-workspace 3",
        ])
        await HeadlessHarness.heavy()
        XCTAssertEqual(Kernel.violations, [])
    }

    func testEventEntryPointsMutateOnlyInsideJobs() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        Kernel.resetViolationsForTests()

        // Mouse-up after a drag: resets the gesture and resize weights
        currentlyManipulatedWithMouseWindowId = window.windowId
        try await resetManipulatedWithMouseIfPossible()
        // Display reconfiguration
        await Kernel.exclusive("test") { onScreenParametersChanged() }
        // A hotkey press
        config.modes[mainModeId] = Mode(bindings: [:])
        try await runHotkeyBinding(HotkeyBinding(.option, .one, parseCommand("workspace 4").cmdOrDie))
        // Hover focus
        try await HoverFocus.apply(window.windowId)
        await HeadlessHarness.settle()

        XCTAssertEqual(Kernel.violations, [])
    }
}
