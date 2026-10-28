import Common
import Foundation

/// Keeps macOS's focus and the model's focus in line (see `FocusRecord`). Two points in every
/// session: at the start macOS's report comes in (the model follows the user's own changes); at
/// the end the model's focus goes out if macOS doesn't have it yet.
@MainActor
enum FocusReconciler {
    private(set) static var record = FocusRecord()

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Session start: macOS says `nativeFocused` has focus
    static func macosReported(_ nativeFocused: Window?) {
        // A popup taking focus is not a focus change of the model
        if nativeFocused?.parent is MacosPopupWindowsContainer { return }
        let report = record.macosReported(nativeFocused?.windowId, now: now)
        FrameTrace.log("focus-report native=\(nativeFocused?.windowId.description ?? "nil") \(report) model=\(focus.windowOrNil?.windowId.description ?? "nil") ws=\(focus.workspace.name)")
        switch report {
            case .unchanged:
                // Nothing new from macOS, so nothing the model took into account: recording the
                // model's focus here marked a model that had moved since (a session restore, a
                // command whose request never went out) as "macOS leads" — no request was ever
                // sent, the model never followed either, and keys went to a window parked on a
                // hidden workspace until the user clicked something
                return noteNative(nativeFocused)
            case .confirmsRequest:
                break
            case .changedByUser:
                if let nativeFocused, now < handoffUntil, nativeFocused.nodeWorkspace?.isVisible == false {
                    // Right after a close/minimize/hide macOS hands focus to another window of the
                    // app by its own z-order — possibly one parked on a hidden workspace. That is
                    // not the user going there: don't follow; the model's choice (i3: the next
                    // window on this workspace) goes out at the end of the session
                    FrameTrace.log("focus-handoff ignored \(nativeFocused.windowId) on hidden \(nativeFocused.nodeWorkspace?.name ?? "?")")
                    record.noteModelAfterReport(nil)
                    return noteNative(nativeFocused)
                }
                if let nativeFocused, let fullscreen = nativeFocused.fullscreenWindowKeepingFocus {
                    // A new tiled window opened behind a fullscreen one: i3 keeps focus on the
                    // fullscreen window and puts the new one right after it in the focus stack.
                    // The end of the session hands focus back to it (the model moved on purpose).
                    nativeFocused.markAsMostRecentChild()
                    record.noteModelAfterReport(nativeFocused.windowId)
                    _ = fullscreen.focusWindow()
                    return noteNative(nativeFocused)
                }
                _ = nativeFocused?.focusWindow()
        }
        record.noteModelAfterReport(focus.windowOrNil?.windowId)
        noteNative(nativeFocused)
    }

    private static func noteNative(_ nativeFocused: Window?) {
        if let nativeFocused { MacOS.current.noteObservedNativeFocus(nativeFocused.windowId) }
    }

    /// Session end: ask macOS for the model's focus if it doesn't have it and wasn't asked yet
    static func reconcile() {
        guard let window = focus.windowOrNil, record.needsRequest(for: window.windowId, now: now) else { return }
        record.noteRequested(window.windowId, now: now)
        FrameTrace.log("focus-request \(window.windowId) observed=\(record.observed?.description ?? "nil")")
        window.nativeFocusRespectingFloats()
    }

    /// Until when macOS's next focus pick is its automatic hand-off (see `noteFocusHandoff`)
    private static var handoffUntil: TimeInterval = 0

    /// The focused window closed, minimized or hid: macOS is about to pick another one itself
    static func noteFocusHandoff() { handoffUntil = now + 1 }

    /// A focus effect sent with its own policy (hover focuses without raising)
    static func noteRequested(_ windowId: UInt32) { record.noteRequested(windowId, now: now) }

    /// macOS is expected to focus `windowId` on its own (closing an app's window focuses another
    /// window of the same app): don't ask; if it chooses differently the model follows it
    static func expect(_ windowId: UInt32) { record.noteRequested(windowId, now: now) }

    static func resetForTests() {
        record = FocusRecord()
        handoffUntil = 0
    }
}
