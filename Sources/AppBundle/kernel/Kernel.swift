import Common
import Foundation

/// The one writer.
///
/// Every session — and every other change to the model that an event causes — runs as a kernel
/// JOB, strictly one at a time, in the order the jobs were submitted. This is i3's model (one event
/// loop; each event handled to completion before the next), adapted to Swift concurrency where a
/// session suspends at every `await` (AX reads, frame writes, user callbacks).
///
/// Before the kernel, nothing stopped two sessions from interleaving at those suspension points: a
/// heavy discovery, a hotkey's light session, a focus-follows-mouse session, the mouse-resize
/// driver's per-frame layout and a dozen delayed tasks (belief verification, echo rechecks, write
/// completions) all mutated the same tree and focus between each other's awaits.
///
/// Re-entry: a job that (directly, in the same task) calls into another job-wrapped function runs
/// it inline. Tasks a job merely SPAWNS are separate tasks — they queue like everyone else, so a
/// delayed task can never run "inside" the session that happened to create it.
///
/// Model mutations report themselves via `noteModelMutation`; outside a job that is a violation
/// (logged in debug builds, collected for `KernelBoundaryTest`).
@MainActor
enum Kernel {
    /// Id of the job the current task (or a structured child of it) belongs to
    @TaskLocal static var jobId: UInt64? = nil

    private static var running: (id: UInt64, task: Int?, label: StaticString)? = nil
    /// Held from acquire to release, INCLUDING the hand-off to the next waiter, so a newcomer can
    /// never barge in between one job ending and the next queued one resuming
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    private static var lastJobId: UInt64 = 0

    /// Run `body` as a kernel job: after every job submitted before it, and alone.
    static func exclusive<T>(_ label: StaticString, _ body: @MainActor () async throws -> T) async rethrows -> T {
        let task = currentTaskIdentity()
        if let running, let task, running.task == task {
            return try await body() // the job itself, calling a job-wrapped function
        }
        await acquire()
        lastJobId &+= 1
        let id = lastJobId
        running = (id, task, label)
        defer { release() }
        return try await $jobId.withValue(id) { try await body() }
    }

    /// Enqueue a job from a synchronous context on any thread (notification callbacks, AppKit
    /// actions, per-app AX threads)
    nonisolated static func submit(_ label: StaticString, _ body: @escaping @MainActor @Sendable () async -> Void) {
        Task.startUnstructured { @MainActor in await exclusive(label, body) }
    }

    /// True while the current task is running (inside) the current job
    static var isInsideJob: Bool {
        guard let jobId, let running else { return false }
        return jobId == running.id
    }

    /// Label of the job currently holding the kernel (diagnostics)
    static var currentJobLabel: String? { running.map { "\($0.label)" } }
    static var queuedJobs: Int { waiters.count }

    private static func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Ownership was handed over by `release`: `busy` stayed true
    }

    private static func release() {
        running = nil
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func currentTaskIdentity() -> Int? {
        unsafe withUnsafeCurrentTask { task in unsafe task?.hashValue }
    }

    // MARK: - Boundary enforcement

    /// UI code is drawing the model. The side UI is a projection: it reads, it never changes the
    /// model (a click runs a command — `runUiCommand`)
    private static var projectionDepth = 0

    static func enterProjection() { projectionDepth += 1 }
    static func exitProjection() { projectionDepth -= 1 }

    /// Mutations seen outside any job, most recent last (bounded). Read by `KernelBoundaryTest`.
    private(set) static var violations: [String] = []

    /// Call at every model mutation point (tree edges, weights, focus, frame intent/belief).
    /// Callable from anywhere: a model mutation off the main thread is itself a violation.
    nonisolated static func noteModelMutation(_ what: StaticString) {
        guard Thread.isMainThread else {
            FrameTrace.log("kernel-violation \(what) (off the main thread)")
            return
        }
        MainActor.assumeIsolated {
            let duringProjection = projectionDepth > 0
            if isInsideJob, !duringProjection { return }
            let violation = duringProjection ? "\(what) (while drawing UI)" : "\(what)"
            if violations.count >= 64 { violations.removeFirst() }
            violations.append(violation)
            FrameTrace.log("kernel-violation \(violation)")
        }
    }

    static func resetViolationsForTests() { violations.removeAll() }
}
