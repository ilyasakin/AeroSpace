import Common
import Foundation

/// Accounting for AX frame writes — the slow, unreliable half of the two output clocks.
///
/// Writing a window frame is not like drawing our own border. A border stroke goes to the compositor
/// in microseconds and cannot fail. A frame write is a request to another process that may take
/// milliseconds, may be clamped to the app's own constraints, may be silently ignored, and — the
/// case nothing recorded — **may be cancelled before it is ever sent**: `MacApp.setAxFrame` cancels
/// the outstanding per-window job before enqueuing the next one, and `withWindowAsync` swallows
/// failures with `try?`.
///
/// That matters because belief is updated at SUBMISSION time. So after a superseded write, our
/// belief describes a frame the app was never asked for, and the next comparison against it is
/// meaningless. The architecture calls for reconciling desired state against belief with
/// acknowledgements and deadlines, and explicitly names the number wanted before building that:
/// **AX writes per second during a drag**, and how many of them are thrown away. This measures it.
///
/// Diagnostics only — nothing branches on these counters. Read them via `debug-windows`.
///
/// `nonisolated(unsafe)`: mutated from the main thread at submission and from per-app AX threads at
/// completion. Counters are monotonic and read for reporting, so a torn read costs a wrong number in
/// a diagnostic, never behaviour. Same discipline as the other session counters in this codebase.
enum AxWriteStats {
    /// Frame writes handed to an app's AX thread.
    nonisolated(unsafe) private(set) static var submitted = 0
    /// Submissions cancelled by a newer write for the same window before being delivered. Each one
    /// is an intent that was recorded as belief and then thrown away.
    nonisolated(unsafe) private(set) static var superseded = 0
    /// Submissions whose AX call threw or whose window had vanished by the time the job ran.
    nonisolated(unsafe) private(set) static var failed = 0
    /// Submissions that reached the app without throwing. Not proof the app honored them — an app
    /// may clamp or ignore a frame it accepted — only that the request was delivered.
    nonisolated(unsafe) private(set) static var delivered = 0

    static func noteSubmitted() { unsafe submitted += 1 }
    static func noteSuperseded() { unsafe superseded += 1 }
    static func noteFailed() { unsafe failed += 1 }
    static func noteDelivered() { unsafe delivered += 1 }

    static func resetForTests() {
        unsafe submitted = 0
        unsafe superseded = 0
        unsafe failed = 0
        unsafe delivered = 0
    }

    /// Share of submissions discarded before delivery. High during a drag means we are generating
    /// intents faster than apps can accept them, which is the case the reconcile design must handle.
    static var supersededShare: Double {
        let s = unsafe submitted
        guard s > 0 else { return 0 }
        return Double(unsafe superseded) / Double(s)
    }

    static var report: String {
        let pct = String(format: "%.1f%%", supersededShare * 100)
        return unsafe "ax-frame-writes: submitted=\(submitted) delivered=\(delivered) "
            + "superseded=\(superseded) (\(pct)) failed=\(failed)"
    }
}
