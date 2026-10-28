import Foundation

/// Run `op`, but return `fallback` if it hasn't finished within `seconds`. `op` is cancelled on
/// timeout; it must honour cancellation promptly (AX work does, via `runInLoop`'s ResumeOnce).
@MainActor
func withDeadline<T: Sendable>(
    seconds: Double,
    fallback: T,
    _ op: @escaping @MainActor @Sendable () async throws -> T,
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        let nanos = UInt64(seconds * 1_000_000_000)
        group.addTask { @MainActor @Sendable () async throws -> T? in
            let value: T = try await op()
            return value
        }
        group.addTask { @Sendable () async throws -> T? in
            try await Task.sleep(nanoseconds: nanos)
            return nil
        }
        defer { group.cancelAll() }
        do {
            guard let first = try await group.next() else { return fallback }
            return first ?? fallback
        } catch is CancellationError {
            // op was cancelled (e.g. by the deadline racing it) — unless WE are cancelled, fall back
            try Task.checkCancellation()
            return fallback
        }
    }
}

/// Like `withDeadline`, but the work is NOT cancelled when the deadline passes: the caller gets
/// `fallback` and moves on, while `op` runs to completion in the background (its side effects land
/// for the next caller). For work that must not be thrown away on every attempt — an app that is
/// always slower than the deadline would otherwise never finish discovery at all.
@MainActor
func withDeadlineLettingWorkFinish<T: Sendable>(
    seconds: Double,
    fallback: T,
    _ op: @escaping @MainActor @Sendable () async throws -> T,
) async -> T {
    let once = ResumeOnce<T>()
    let nanos = UInt64(seconds * 1_000_000_000)
    let result: T? = try? await withCheckedThrowingContinuation { cont in
        once.install(cont)
        Task.startUnstructured { @MainActor in
            let value: T = (try? await op()) ?? fallback
            once.resume(.success(value))
        }
        Task.startUnstructured {
            try? await Task.sleep(nanoseconds: nanos)
            once.resume(.success(fallback))
        }
    }
    return result ?? fallback
}
