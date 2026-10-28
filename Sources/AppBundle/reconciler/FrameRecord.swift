import Common
import Foundation

/// Everything AeroSpace knows about one window's frame — and the only place that knowledge lives.
///
/// Three inputs, nothing else:
/// - **we wrote** a target (`wrote`),
/// - **the app answered** it: the frame the app reports right after applying the write, read on
///   its own AX thread (`appAnswered`) — the app's word on what it did,
/// - **WindowServer reported** the window's frame (`windowServerReported`), from a move/resize
///   event or a read.
///
/// Every decision is a pure function of those inputs and their timestamps. This replaces the
/// belief field recorded at submission, the "written this session" lag marks, the pre-write frame,
/// the 80 ms echo recheck, the 250 ms post-write verification task, the bounded reconcile counter
/// and the "app-constrained" adoption — seven guesses about the one signal this record now has:
/// what the app answered.
struct FrameRecord: Equatable {
    enum Phase: Equatable {
        /// Nothing written or reported yet (or knowledge was dropped)
        case unknown
        /// The frame as last reported — by WindowServer, or by the app answering our write
        case known(Rect)
        /// Write `seq` is on its way; the app hasn't answered
        case writing(target: Rect, from: Rect?, seq: UInt64)
        /// The app answered at the position we asked for, with a size of its own (aspect-locked
        /// video, terminal cell increments, a minimum or maximum size)
        case appSized(target: Rect, actual: Rect)
    }

    enum WriteOutcome: Equatable {
        /// The app took the frame
        case landed
        /// Position taken, size is the app's choice — its answer, not a failed write
        case appSized(actual: Rect)
        /// The app ended up somewhere else, or couldn't say where: the target was not applied
        case missed
        /// An answer to a write that a newer one already replaced
        case stale
    }

    enum Report: Equatable {
        /// Our own write (in flight, landed, or WindowServer still catching up with it)
        case ownWrite
        /// The window moved or resized for another reason: the user, the app, macOS
        case external
        /// Looks like WindowServer still catching up with our write (the pre-write frame) — or the
        /// app putting its own saved frame back, which looks identical right now. Ours for now;
        /// look again once the lag window is over
        case lagging
    }

    private(set) var phase: Phase = .unknown
    /// The frame before the last answered write and when it was answered: WindowServer reporting
    /// it shortly afterwards is WindowServer catching up, not the window moving back
    private(set) var lastAnswer: LastAnswer? = nil
    private(set) var lastSeq: UInt64 = 0
    /// The last frame we asked for: WindowServer showing it later means the app applied the write
    /// late (Electron apps resize asynchronously, after answering with the old frame)
    private(set) var lastTarget: Rect? = nil
    /// When the write in flight was sent. A write can go unanswered for good — closing the window,
    /// or toggling native fullscreen/minimize, cancels the job before it runs — and a record left
    /// `.writing` swallowed every later move as "our own" and kept answering reads with a stale target
    private(set) var writeSentAt: TimeInterval? = nil
    static let writeAnswerTimeout: TimeInterval = 1
    /// Consecutive `.missed` answers for the same target. Re-sending is bounded: an app that
    /// genuinely won't take a frame is not fought forever
    private(set) var misses: Misses? = nil

    struct Misses: Equatable {
        let target: Rect
        let count: Int
    }

    static let maxResends = 2

    /// The last write missed and may be re-sent
    var shouldResend: Bool { (1 ... Self.maxResends).contains(misses?.count ?? 0) }

    struct LastAnswer: Equatable {
        let from: Rect?
        let at: TimeInterval
    }

    /// How long after an answer WindowServer may still report the pre-write frame
    static let windowServerLagSeconds: TimeInterval = 0.5
    static let tolerance: CGFloat = 2

    /// The best answer to "where is the window" that doesn't ask macOS
    var bestKnown: Rect? {
        switch phase {
            case .unknown: nil
            case .known(let r): r
            case .writing(let target, _, _): target
            case .appSized(_, let actual): actual
        }
    }

    var isWriting: Bool { if case .writing = phase { true } else { false } }

    /// A write is in flight and could still be answered
    func isAwaitingAnswer(now: TimeInterval) -> Bool {
        isWriting && (writeSentAt.map { now - $0 < Self.writeAnswerTimeout } ?? true)
    }

    /// An unanswered write past its timeout is lost: what we knew before it no longer holds either
    private mutating func expireLostWrite(now: TimeInterval) {
        guard isWriting, !isAwaitingAnswer(now: now) else { return }
        phase = .unknown
        writeSentAt = nil
    }

    /// The app's own-size answer, once it has stood long enough to trust (`nil` otherwise). An app
    /// that resizes asynchronously answers with its OLD size and gets there later — taking that first
    /// answer as a cap latched bogus caps (a lone Slack tile centred at 2053 of 2528 px)
    func settledAppSize(now: TimeInterval) -> (target: Rect, actual: Rect)? {
        guard case .appSized(let target, let actual) = phase, let lastAnswer,
              now - lastAnswer.at >= Self.appSizeSettleSeconds
        else { return nil }
        return (target, actual)
    }

    nonisolated(unsafe) static var appSizeSettleSeconds: TimeInterval = 1

    /// WindowServer may not show the latest frame yet: a write is in flight or was answered moments ago
    func windowServerMayLag(now: TimeInterval) -> Bool {
        if isWriting { return isAwaitingAnswer(now: now) }
        guard let lastAnswer else { return false }
        return now - lastAnswer.at < Self.windowServerLagSeconds
    }

    // MARK: - Inputs

    /// We submitted `target`. Returns the write's sequence number (its answer carries it back).
    mutating func wrote(_ target: Rect, now: TimeInterval) -> UInt64 {
        writeSentAt = now
        lastSeq &+= 1
        // A write replacing one still in flight keeps the ORIGINAL "from": the replaced one may
        // never have shown, so WindowServer can still be reporting the frame before either
        let from: Rect? = if case .writing(_, let from, _) = phase { from } else { bestKnown }
        phase = .writing(target: target, from: from, seq: lastSeq)
        lastTarget = target
        return lastSeq
    }

    /// The app's answer to write `seq`: the frame it reports right after applying it (nil: it
    /// couldn't be read)
    mutating func appAnswered(seq: UInt64, reported: Rect?, now: TimeInterval) -> WriteOutcome {
        guard case .writing(let target, let from, let current) = phase, current == seq else { return .stale }
        lastAnswer = LastAnswer(from: from, at: now)
        guard let reported else {
            phase = .unknown // don't believe a target nobody confirmed
            noteMiss(target)
            return .missed
        }
        if Self.near(reported, target) {
            phase = .known(reported)
            misses = nil
            return .landed
        }
        if Self.samePosition(reported, target) {
            phase = .appSized(target: target, actual: reported)
            misses = nil
            return .appSized(actual: reported)
        }
        phase = .known(reported)
        noteMiss(target)
        return .missed
    }

    /// WindowServer's view of the window. `isParkedOffScreen`: the window is parked in the hide
    /// corner and `live` is still off every screen (macOS pulls parked windows back a few dozen px,
    /// so a park never matches the corner exactly)
    mutating func windowServerReported(_ live: Rect, now: TimeInterval, isParkedOffScreen: Bool = false) -> Report {
        expireLostWrite(now: now)
        switch phase {
            case .writing:
                return .ownWrite // an intermediate step of our write (size, position, size)
            default:
                break
        }
        if isParkedOffScreen {
            phase = .known(live)
            return .ownWrite
        }
        if let known = bestKnown, Self.near(live, known) { return .ownWrite }
        // The app got there after answering: an asynchronous resize, not an outside change
        if let lastTarget, Self.near(live, lastTarget) {
            phase = .known(live)
            return .ownWrite
        }
        if let lastAnswer, now - lastAnswer.at < Self.windowServerLagSeconds, let known = bestKnown,
           Self.isMix(live, of: lastAnswer.from, and: known)
        {
            return .lagging // WindowServer still showing (part of) the pre-write frame?
        }
        phase = .known(live)
        lastAnswer = nil
        return .external
    }

    /// A frame the app reported for a write we couldn't express as a target (position or size
    /// alone, with nothing known to merge it with)
    mutating func adopt(_ reported: Rect) {
        phase = .known(reported)
    }

    private mutating func noteMiss(_ target: Rect) {
        misses = Misses(target: target, count: misses?.target == target ? (misses?.count ?? 0) + 1 : 1)
    }

    /// Knowledge no longer holds (native fullscreen/minimize changed the window behind our back)
    mutating func forget() {
        phase = .unknown
        lastAnswer = nil
    }

    // MARK: - Geometry

    static func near(_ a: Rect, _ b: Rect) -> Bool {
        samePosition(a, b) && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func samePosition(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.topLeftX - b.topLeftX) <= tolerance && abs(a.topLeftY - b.topLeftY) <= tolerance
    }

    /// Position from one frame and size from the other: AX sets them separately, so a lagging
    /// WindowServer can show either half updated
    static func isMix(_ live: Rect, of from: Rect?, and to: Rect) -> Bool {
        guard let from else { return false }
        let position = samePosition(live, from) || samePosition(live, to)
        let size = (abs(live.width - from.width) <= tolerance && abs(live.height - from.height) <= tolerance)
            || (abs(live.width - to.width) <= tolerance && abs(live.height - to.height) <= tolerance)
        return position && size
    }
}
