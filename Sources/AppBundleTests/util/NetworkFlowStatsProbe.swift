@testable import AppBundle
import Common
import XCTest

/// Live probe for the flow-accounting path. Opt-in (it subscribes to every TCP/UDP flow on the
/// machine and needs real traffic to be meaningful):
///   NET_PROBE=1 swift test --filter NetworkFlowStatsProbe 2>&1 | grep NETPROBE
///
/// Exists because a regression here is invisible to unit tests: the bytes come from a private
/// framework via per-flow callbacks, and the bug that prompted it — a retired-source set keyed on
/// reusable heap addresses — silently rejected most flows while every unit test still passed.
final class NetworkFlowStatsProbe: XCTestCase {
    /// The reported symptom needed a LONG-LIVED process: the broken version kept a retired-source
    /// set keyed on reusable heap addresses, so it only degraded once enough flows had opened and
    /// closed for the allocator to hand an address back. A 7-second run never churns enough, which
    /// is why the first A/B could not tell the two versions apart. This forces the churn.
    func testAccountingSurvivesHeavyFlowChurn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NET_PROBE"] == "1", "set NET_PROBE=1")
        guard NetworkFlowStats.shared.poll() != nil else { throw XCTSkip("framework unavailable") }

        // Hundreds of short-lived connections: each opens a flow and closes it, so sources are
        // allocated and freed repeatedly and addresses get reused.
        for _ in 0 ..< 6 {
            let p = Process()
            p.executableURL = URL(filePath: "/bin/sh")
            p.arguments = ["-c", "for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 https://cloudflare.com/cdn-cgi/trace & done; wait"]
            try? p.run()
            p.waitUntilExit()
            _ = NetworkFlowStats.shared.poll()
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1.5)
        _ = NetworkFlowStats.shared.poll()
        Thread.sleep(forTimeInterval: 1.5)
        guard let base = NetworkFlowStats.shared.poll() else { return XCTFail("sampler stopped") }
        print("NETPROBE churn baseline rx=\(base.rx)")

        // Now a known 25MB download AFTER the churn. Broken accounting drops flows whose address
        // was previously retired, so this is where the undercount shows.
        let dl = Process()
        dl.executableURL = URL(filePath: "/usr/bin/curl")
        dl.arguments = ["-s", "-o", "/dev/null", "https://speed.cloudflare.com/__down?bytes=25000000"]
        try? dl.run()
        dl.waitUntilExit()

        Thread.sleep(forTimeInterval: 2.0)
        _ = NetworkFlowStats.shared.poll()
        Thread.sleep(forTimeInterval: 1.5)
        guard let after = NetworkFlowStats.shared.poll() else { return XCTFail("sampler stopped") }
        let d = after.rx >= base.rx ? after.rx - base.rx : 0
        print("NETPROBE post-churn delta rx=\(d) bytes (\(d / 1_000_000) MB)")
        XCTAssertGreaterThan(d, 5_000_000, "after flow churn, a 25MB download was accounted as only \(d) bytes")
    }

    func testCountersAdvanceUnderRealTraffic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NET_PROBE"] == "1", "set NET_PROBE=1")

        guard NetworkFlowStats.shared.poll() != nil else {
            throw XCTSkip("NetworkStatistics.framework unavailable")
        }
        // poll() returns the PREVIOUS query's result and kicks the next, so the first call is 0.
        // Baseline only once a query has actually landed, or the delta is the whole cumulative
        // total and the assertion passes no matter how broken the accounting is.
        Thread.sleep(forTimeInterval: 1.5)
        _ = NetworkFlowStats.shared.poll()
        Thread.sleep(forTimeInterval: 1.5)
        guard let first = NetworkFlowStats.shared.poll(), first.rx > 0 else {
            throw XCTSkip("no baseline traffic observed")
        }
        print("NETPROBE baseline rx=\(first.rx) tx=\(first.tx)")

        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/curl")
        task.arguments = ["-s", "-o", "/dev/null", "https://speed.cloudflare.com/__down?bytes=25000000"]
        try? task.run()
        task.waitUntilExit()

        Thread.sleep(forTimeInterval: 2.0)
        _ = NetworkFlowStats.shared.poll()
        Thread.sleep(forTimeInterval: 1.5)
        guard let last = NetworkFlowStats.shared.poll() else { return XCTFail("sampler stopped answering") }

        let dRx = last.rx >= first.rx ? last.rx - first.rx : 0
        let dTx = last.tx >= first.tx ? last.tx - first.tx : 0
        print("NETPROBE end   rx=\(last.rx) tx=\(last.tx)")
        print("NETPROBE delta rx=\(dRx) bytes (\(dRx / 1_000_000) MB)  tx=\(dTx) bytes")

        // A 25 MB download must show up as MEGAbytes. The bug reported single-digit kB/s forever,
        // so the threshold is deliberately far below the real figure but far above the broken one.
        XCTAssertGreaterThan(dRx, 5_000_000, "downloaded ~25MB but the flow accounting saw \(dRx) bytes")
    }
}
