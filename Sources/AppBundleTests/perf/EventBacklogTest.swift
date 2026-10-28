@testable import AppBundle
import Common
import Network
import XCTest

@MainActor
final class EventBacklogTest: XCTestCase {
    /// A subscriber that never reads (here: a connection that is never started, so no send ever
    /// completes) is disconnected once it falls maxBacklog events behind — delivery to others
    /// never waits on it, and its backlog can't grow without bound.
    func testStuckSubscriberIsDroppedAtTheBound() {
        let stuck = NWConnection(to: .unix(path: "/nonexistent/aerospace-test.sock"), using: .tcp)
        var drops = 0
        for _ in 0 ... EventBacklog.maxBacklog {
            EventBacklog.send(Data([1, 2, 3]), to: stuck) { drops += 1 }
            XCTAssertLessThanOrEqual(EventBacklog.backlog(of: stuck), EventBacklog.maxBacklog)
        }
        XCTAssertEqual(drops, 1)
        EventBacklog.forget(stuck)
    }

    func testNativeFrameIsLengthPrefixedJson() throws {
        let frame = try XCTUnwrap(nativeEventFrame(["a": 1], JSONEncoder()))
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(length), frame.count - 4)
    }
}
