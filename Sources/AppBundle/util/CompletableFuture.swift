import Dispatch
import Foundation

final class CompletableFuture<T>: Sendable {
    nonisolated(unsafe) private var value: T?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ t: T) {
        unsafe value = t
        semaphore.signal()
    }

    func blockingGet() -> T {
        semaphore.wait()
        return unsafe value.orDie("semaphore should have been signaled")
    }

    /// Bounded wait; nil if `timeout` elapsed first. For the quit path, where blocking the main
    /// thread is accepted but an unresponsive app must not be able to prevent the process exiting.
    func blockingGet(timeout: TimeInterval) -> T? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return unsafe value
    }
}
