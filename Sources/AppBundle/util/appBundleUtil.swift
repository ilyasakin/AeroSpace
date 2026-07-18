import AppKit
import Common
import Foundation
import os

let signposter = OSSignposter(subsystem: aeroSpaceAppId, category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"
let zoomAppBundleId = "us.zoom.xos"

func interceptTermination(_ _signal: Int32) {
    // SIGKILL cannot be caught — only install for signals that can (SIGINT, SIGTERM).
    signal(_signal, { (signal: Int32) in
        // Run restore on the main actor synchronously so parked windows are centered
        // before the process actually exits (async Task here used to race with exit).
        MainActor.runSync {
            terminationHandler?.beforeTermination()
        }
        exit(signal)
    } as sig_t)
}

@MainActor
func initTerminationHandler() {
    unsafe _terminationHandler = AppServerTerminationHandler()
    // Any quit path (menu, Cmd+Q via AppKit, terminate()) — not only our tray button.
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main,
    ) { _ in
        MainActor.assumeIsolated {
            terminationHandler?.beforeTermination()
        }
    }
    // Catchable process signals (debug *and* release). SIGKILL is uncatchable.
    interceptTermination(SIGINT)
    interceptTermination(SIGTERM)
}

/// Center `windowSize` inside `visibleRect` (AeroSpace top-left coords, +y down).
/// Pure helper so quit-restore math stays unit-testable.
func centeredTopLeft(windowSize: CGSize, in visibleRect: Rect) -> CGPoint {
    let w = min(max(windowSize.width, 1), visibleRect.width)
    let h = min(max(windowSize.height, 1), visibleRect.height)
    return CGPoint(
        x: visibleRect.topLeftX + (visibleRect.width - w) / 2,
        y: visibleRect.topLeftY + (visibleRect.height - h) / 2,
    )
}

/// Clamp a preferred size so it fits the visible monitor area.
func terminationRestoreSize(preferred: CGSize?, visibleRect: Rect) -> CGSize {
    let fallback = CGSize(width: visibleRect.width * 0.7, height: visibleRect.height * 0.7)
    let raw = preferred.flatMap { s -> CGSize? in
        (s.width > 1 && s.height > 1) ? s : nil
    } ?? fallback
    return CGSize(
        width: min(raw.width, visibleRect.width),
        height: min(raw.height, visibleRect.height),
    )
}

private struct AppServerTerminationHandler: TerminationHandler {
    @MainActor
    private static var didRun = false

    @MainActor
    func beforeTermination() {
        // Menu + willTerminate + signals can all fire; only restore once.
        if Self.didRun { return }
        Self.didRun = true

        // Persist tiling before we start moving windows for quit.
        SessionLayoutStore.saveNow()

        // Invisible workspaces park windows off-screen (hide-in-corner). On quit/crash-signal
        // we must put every managed window back on a visible, centered place so users can
        // find them without hunting the Dock-edge pixel strip.
        for window in MacWindow.allWindowsMap.values {
            // Prefer tree monitor (workspace home). AX center of a corner-parked window can
            // be off-screen and pick the wrong display under multi-monitor.
            // Avoid `.parent` when the tree may be mid-teardown — nodeMonitor is fine.
            let axRect = window.macApp.getAxRectForTermination(window.windowId)
            let monitor = window.nodeMonitor
                ?? axRect.map { $0.center.monitorApproximation }
                ?? mainMonitor
            let visible = monitor.visibleRect
            let preferredSize = axRect?.size ?? window.lastFloatingSize
            let windowSize = terminationRestoreSize(preferred: preferredSize, visibleRect: visible)
            let point = centeredTopLeft(windowSize: windowSize, in: visible)
            window.macApp.setAxFrameForTermination(window.windowId, point, windowSize)
        }
        if isDebug {
            let semaphore = DispatchSemaphore(value: 0)
            // Use Task.detached to avoid inheriting @MainActor.
            // If @MainActor was inherited, it would cause a deadlock
            Task.detached {
                await toggleReleaseServerIfDebug(.on)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }
}

@MainActor
func terminateApp() -> Never {
    // Belt-and-suspenders: restore even if willTerminate is skipped somehow.
    terminationHandler?.beforeTermination()
    NSApplication.shared.terminate(nil)
    die("Unreachable code")
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(self, forType: .string)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: ConvenienceMutable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        // Subtract 1 from maxX/maxY because the right/bottom bounds are
        // exclusive.
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    var monitorApproximation: Monitor { monitors.minByOrDie { distance(toOuterFrame: $0.rect) } }

    var withYAxisFlipped: CGPoint {
        consuming get {
            self.y = mainMonitor.height - self.y
            return self
        }
    }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

extension CGPoint: @retroactive Hashable { // todo migrate to self written Point
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

#if DEBUG
    let isDebug = true
#else
    let isDebug = false
#endif

@inlinable
func checkCancellation(_ cm: CancellationMode = .cancellable) throws(CancellationError) {
    if cm == .cancellable && Task.isCancelled {
        throw CancellationError()
    }
}

public enum CancellationMode: Equatable, Sendable {
    case cancellable
    case nonCancellable
}
