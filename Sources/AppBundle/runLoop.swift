import Common
import Foundation

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob,
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (RunLoopJob) throws -> T,
    ) async throws -> T { // todo try to convert to typed throws
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        let resumer = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                resumer.install(cont)
                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    // Already resumed with CancellationError: the caller moved on, skip the work
                    if resumer.isResolved { return }
                    do {
                        try job.checkCancellation()
                        resumer.resume(.success(try body(job)))
                    } catch {
                        if cm == .nonCancellable { die() }
                        resumer.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            job.cancel()
            // Resume the caller NOW. Waiting for the app's thread to reach the block meant a
            // cancelled session stayed suspended behind a beachballing app for up to the AX
            // messaging timeout, and anything awaiting it (discovery of every other app) with it.
            if cm == .cancellable { resumer.resume(.failure(CancellationError())) }
        }
    }
}

/// Resumes a checked continuation exactly once, from whichever side gets there first: the app
/// thread finishing the job, or task cancellation. Cancellation that arrives before the
/// continuation is installed is remembered and applied on install.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, any Error>? = nil
    private var early: Result<T, any Error>? = nil
    private var resolved = false

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    func install(_ c: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let early {
            // Resolved exactly once (the `resolved` flag); the value is never touched again
            nonisolated(unsafe) let value = early
            self.early = nil
            lock.unlock()
            c.resume(with: value)
            return
        }
        cont = c
        lock.unlock()
    }

    func resume(_ result: sending Result<T, any Error>) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        guard let c = cont else {
            early = result
            lock.unlock()
            return
        }
        cont = nil
        lock.unlock()
        c.resume(with: result)
    }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
        _refreshSessionEvent = refreshSessionEvent
    }
    @objc func action() {
        if autoCheckCancelled && job.isCancelled { return }
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            _action(job)
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    // Alternative 1. In macOS 15, it's possible to use `Atomic<Bool>` from `Synchronization` module
    // Alternative 2. https://github.com/apple/swift-atomics/tree/main but I don't want to add one more dependency just for
    //                AtomicBool
    nonisolated(unsafe) private var _isCancelled: Int32 = 0
    var isCancelled: Bool { unsafe _isCancelled == 1 }
    func cancel() {
        if cm == .nonCancellable { return }
        while !isCancelled {
            unsafe OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    let cm: CancellationMode
    public init(_ cm: CancellationMode) { self.cm = cm }

    static let cancelled: RunLoopJob = RunLoopJob(.cancellable).also { $0.cancel() }

    func checkCancellation() throws {
        if cm == .cancellable && isCancelled {
            throw CancellationError()
        }
    }
}
