import Common
import Foundation

/// What AeroSpace knows about macOS's focus, kept next to what the model wants (`focus`).
///
/// Before this, focus lived in five places and was pushed to macOS only when a light session saw
/// its model focus change between start and end; a focus set anywhere else (window close,
/// a fullscreen rule, a heavy session) either sent its own effect or none. Now one reconcile step
/// compares the model with this record at the end of every session.
struct FocusRecord: Equatable {
    /// The window macOS last reported focused
    private(set) var observed: UInt32?
    /// A focus we asked macOS for (or expect it to make on its own) not yet reported back
    private(set) var requested: Request?
    /// The model's focus right after it last took macOS's report into account. macOS leads when
    /// the model hasn't moved since: it may hold something the model can't (no window — the
    /// desktop, a just-launched app whose window isn't registered yet, a Space switch in progress —
    /// or a window the model doesn't manage). Pushing the model's focus then stole focus back from
    /// the user. Only a focus change AeroSpace made (a command, a closed window) goes out.
    private(set) var modelAfterReport: UInt32?
    private(set) var hasReport = false

    struct Request: Equatable {
        let windowId: UInt32
        let at: TimeInterval
    }

    /// An unconfirmed request older than this was refused (or lost)
    static let requestExpirySeconds: TimeInterval = 1

    enum Report: Equatable {
        /// Nothing new
        case unchanged
        /// macOS did what we asked
        case confirmsRequest
        /// The user (or an app) focused something else: the model should follow
        case changedByUser(UInt32?)
    }

    /// macOS reports `windowId` focused
    mutating func macosReported(_ windowId: UInt32?, now: TimeInterval) -> Report {
        defer { observed = windowId }
        if let requested, windowId == requested.windowId {
            self.requested = nil
            return .confirmsRequest
        }
        // Still the old focus: our request may simply not have landed yet — unless it is too old,
        // then macOS refused it and the model follows what macOS actually has
        if windowId == observed {
            guard let requested, now - requested.at >= Self.requestExpirySeconds else { return .unchanged }
            self.requested = nil
            return .changedByUser(windowId)
        }
        requested = nil
        return .changedByUser(windowId)
    }

    /// After a report: where the model's focus now stands (having followed macOS, or not)
    mutating func noteModelAfterReport(_ modelFocus: UInt32?) {
        modelAfterReport = modelFocus
        hasReport = true
    }

    /// The model wants `modelFocus`: does macOS have to be asked?
    func needsRequest(for modelFocus: UInt32?, now: TimeInterval) -> Bool {
        guard let modelFocus, modelFocus != observed else { return false }
        // The model didn't move since macOS last spoke: macOS's focus is the user's
        if hasReport, modelFocus == modelAfterReport { return false }
        if let requested, requested.windowId == modelFocus, now - requested.at < Self.requestExpirySeconds { return false }
        return true
    }

    /// We asked macOS to focus `windowId` — or expect it to on its own (closing a window focuses
    /// another of the same app)
    mutating func noteRequested(_ windowId: UInt32, now: TimeInterval) {
        requested = Request(windowId: windowId, at: now)
    }
}
