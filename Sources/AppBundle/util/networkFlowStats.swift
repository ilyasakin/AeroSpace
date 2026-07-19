import Foundation

/// Flow-level network byte counters from the private NetworkStatistics framework ("ntstat" —
/// the source nettop / Activity Monitor use). Legacy interface counters (getifaddrs if_data)
/// miss inbound bytes on modern macOS whenever network extensions (VPN / content filters) or
/// Skywalk user-space networking carry the flow — observed as en0 ibytes frozen while obytes
/// ticks. Flow accounting sees all TCP/UDP traffic regardless of tunnels.
///
/// Symbols resolve at runtime (dlsym) so symbol drift degrades to "unavailable" (callers fall
/// back to interface counters) instead of failing to launch.
final class NetworkFlowStats: @unchecked Sendable {
    static let shared = NetworkFlowStats()

    private typealias ManagerCreateFun = @convention(c) (CFAllocator?, dispatch_queue_t, AnyObject) -> OpaquePointer?
    private typealias ManagerVoidFun = @convention(c) (OpaquePointer?) -> Void
    private typealias SourceSetBlockFun = @convention(c) (OpaquePointer?, AnyObject) -> Void
    private typealias ManagerQueryFun = @convention(c) (OpaquePointer?, AnyObject) -> Void

    /// Serializes all state. ntstat delivers source/counts callbacks on this queue.
    private let queue = DispatchQueue(label: "bobko.aerospace.network-flow-stats")
    private var started = false
    private var manager: OpaquePointer?
    private var queryAll: ManagerQueryFun?
    private var queryInFlight = false
    /// Cumulative bytes of closed flows plus last-known counts per live flow. Monotonic:
    /// removal folds the flow's last counts into the closed accumulator, never subtracts.
    private var closedRx: UInt64 = 0
    private var closedTx: UInt64 = 0
    private var liveCounts: [OpaquePointer: (rx: UInt64, tx: UInt64)] = [:]

    private init() {}

    /// Cumulative (rx, tx) as of the last completed query, then kicks the next async query —
    /// values are one poll interval stale, which is fine for a 1 Hz rate display.
    /// nil when the framework is unavailable.
    func poll() -> (rx: UInt64, tx: UInt64)? {
        queue.sync {
            startLocked()
            guard let manager, let queryAll else { return nil }
            var rx = closedRx
            var tx = closedTx
            for (_, counts) in liveCounts {
                rx &+= counts.rx
                tx &+= counts.tx
            }
            if !queryInFlight {
                queryInFlight = true
                // Completion fires async on `queue`; direct mutation is queue-safe there
                let done: @convention(block) () -> Void = { self.queryInFlight = false }
                queryAll(manager, done as AnyObject)
            }
            return (rx, tx)
        }
    }

    /// Must run on `queue`. One-shot: resolve symbols, create the manager, subscribe to all flows.
    private func startLocked() {
        guard !started else { return }
        started = true
        guard let handle = unsafe dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY),
              let createSym = unsafe dlsym(handle, "NStatManagerCreate"),
              let addTcpSym = unsafe dlsym(handle, "NStatManagerAddAllTCP"),
              let addUdpSym = unsafe dlsym(handle, "NStatManagerAddAllUDP"),
              let setCountsSym = unsafe dlsym(handle, "NStatSourceSetCountsBlock"),
              let setRemovedSym = unsafe dlsym(handle, "NStatSourceSetRemovedBlock"),
              let queryAllSym = unsafe dlsym(handle, "NStatManagerQueryAllSources")
        else { return }
        let create = unsafe unsafeBitCast(createSym, to: ManagerCreateFun.self)
        let addTcp = unsafe unsafeBitCast(addTcpSym, to: ManagerVoidFun.self)
        let addUdp = unsafe unsafeBitCast(addUdpSym, to: ManagerVoidFun.self)
        let setCounts = unsafe unsafeBitCast(setCountsSym, to: SourceSetBlockFun.self)
        let setRemoved = unsafe unsafeBitCast(setRemovedSym, to: SourceSetBlockFun.self)
        queryAll = unsafe unsafeBitCast(queryAllSym, to: ManagerQueryFun.self)

        // All blocks below fire on `queue` (the queue given to NStatManagerCreate), so they
        // mutate state directly. Blocks pass as AnyObject: @convention(c) params treat block
        // args as noescape, but the manager retains them.
        let sourceAdded: @convention(block) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { source, _ in
            guard let source else { return }
            let counts: @convention(block) (CFDictionary?) -> Void = { dict in
                guard let dict = dict as? [String: Any] else { return }
                let rx = (dict["rxBytes"] as? NSNumber)?.uint64Value ?? 0
                let tx = (dict["txBytes"] as? NSNumber)?.uint64Value ?? 0
                self.liveCounts[source] = (rx, tx)
            }
            let removed: @convention(block) () -> Void = {
                if let last = self.liveCounts.removeValue(forKey: source) {
                    self.closedRx &+= last.rx
                    self.closedTx &+= last.tx
                }
            }
            setCounts(source, counts as AnyObject)
            setRemoved(source, removed as AnyObject)
        }
        guard let created = create(kCFAllocatorDefault, queue, sourceAdded as AnyObject) else { return }
        manager = created
        addTcp(created)
        addUdp(created)
    }
}
