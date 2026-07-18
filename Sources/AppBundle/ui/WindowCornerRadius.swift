import AppKit
import Foundation

/// Corner radius for window borders **without Screen Recording**.
///
/// ## Out-of-the-box approach (what actually works)
/// Apple's real formula lives on private `NSThemeFrame` (`_cornerRadius`). That only
/// exists for windows **we own** — but the value depends on chrome (plain titlebar vs
/// toolbar), not on which app owns the window. So we:
/// 1. Keep tiny off-screen probe `NSWindow`s (plain / toolbar) in *our* process
/// 2. Read `_cornerRadius` from their theme frames → true system numbers (e.g. Tahoe
///    plain **16**, toolbar **26**)
/// 3. Classify each foreign window's chrome (AX toolbar when available) and pick the
///    matching probe radius
///
/// Also respects global `defaults write -g NSConvolutionOverride1` because probe windows
/// pick up the same system knobs.
///
/// ## What does *not* work (researched)
/// - Public API / `CGWindowList` fields — none
/// - `SLSCopyWindowShape` — rectangular bounds only (rounding is visual, not shape)
/// - Pixel screenshots — Screen Recording permission (rejected for product)
/// - `NSThemeFrame` on *other* processes — needs injection
enum WindowCornerRadius {
    /// Largest radius we search when fitting synthetic alpha (tests only).
    static let defaultMaxRadius = 64
    static let defaultAlphaThreshold: UInt8 = 40

    /// Undocumented global defaults key some power users set to force window radii.
    static let systemOverrideDefaultsKey = "NSConvolutionOverride1"

    /// Chrome class that maps to a system corner radius on modern macOS.
    enum Chrome: Equatable, Sendable {
        /// Standard titled window (TextEdit-like)
        case plain
        /// Window with a toolbar (Safari / Calculator-like on Tahoe → larger radius)
        case toolbar
        /// Utility / floating panel style
        case utility
    }

    // MARK: - Production API

    /// Radius for borders: app override is handled by `WindowBorders`; this is the
    /// auto path — probe-derived system radius for `chrome`, with pure OS-table fallback.
    @MainActor
    static func radius(for chrome: Chrome) -> Int {
        if let probed = SystemCornerRadiusProbes.shared.radius(for: chrome) {
            return probed
        }
        return builtinRadius(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            chrome: chrome,
        )
    }

    /// Convenience when chrome is unknown — prefer plain (smaller); slightly-small is rarer
    /// than cutting inside a large Tahoe corner when misclassified.
    @MainActor
    static func radiusForUnknownChrome() -> Int { radius(for: .plain) }

    /// Live detect path used by config `detect-corner-radius` without per-window chrome:
    /// returns plain probe radius (and still tracks system override via probes).
    @MainActor
    static func heuristicRadiusForCurrentOS() -> Int { radius(for: .plain) }

    /// Built-in table when AppKit probes are unavailable (tests / early startup).
    /// Tahoe values match measured `NSThemeFrame._cornerRadius` on macOS 26.
    static func builtinRadius(osMajorVersion: Int, chrome: Chrome = .plain) -> Int {
        switch osMajorVersion {
            case ...12:
                return 5
            case 13 ... 15:
                // Ventura … Sequoia — little plain/toolbar split in practice
                return chrome == .utility ? 8 : 10
            default:
                // Tahoe 26+
                switch chrome {
                    case .plain: return 16
                    case .toolbar: return 26
                    case .utility: return 15
                }
        }
    }

    /// Pure function for tests: optional system override wins, else builtin table.
    static func heuristicRadius(
        osMajorVersion: Int,
        systemOverride: Double? = nil,
        chrome: Chrome = .plain,
    ) -> Int {
        if let override = systemOverride, override.isFinite, override > 0 {
            return max(1, Int(override.rounded()))
        }
        return builtinRadius(osMajorVersion: osMajorVersion, chrome: chrome)
    }

    static func readSystemCornerRadiusOverride() -> Double? {
        let key = systemOverrideDefaultsKey as CFString
        let value = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication)
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        return nil
    }

    // MARK: - Alpha fit (unit tests / experimental only)

    static func estimateFromAlpha(
        size: Int,
        maxRadius: Int = defaultMaxRadius,
        threshold: UInt8 = defaultAlphaThreshold,
        alphaAt: (Int, Int) -> UInt8,
    ) -> Int? {
        guard size >= 4 else { return nil }
        let maxR = min(max(maxRadius, 1), size - 1)
        var edgeX = [Int](repeating: size, count: size)
        var anyOpaque = false
        var anyTransparentNearCorner = false
        for y in 0 ..< size {
            var x = 0
            while x < size, alphaAt(x, y) < threshold { x += 1 }
            edgeX[y] = x
            if x < size { anyOpaque = true }
            if y < maxR, x > 0 { anyTransparentNearCorner = true }
        }
        guard anyOpaque else { return nil }
        if !anyTransparentNearCorner { return 0 }

        var bestR = 1
        var bestErr = Double.greatestFiniteMagnitude
        for r in 1 ... maxR {
            var err = 0.0
            var samples = 0
            for y in 0 ..< size {
                if y > r + 2 { continue }
                let got = edgeX[y]
                if got >= size { continue }
                let d = Double(got - expectedEdgeX(radius: r, y: y))
                err += d * d
                samples += 1
            }
            guard samples > 0 else { continue }
            let mean = err / Double(samples)
            if mean < bestErr {
                bestErr = mean
                bestR = r
            }
        }
        return bestR
    }

    static func expectedEdgeX(radius r: Int, y: Int) -> Int {
        if y >= r { return 0 }
        let dy = Double(r) - (Double(y) + 0.5)
        let r2 = Double(r) * Double(r)
        let inside = r2 - dy * dy
        guard inside > 0 else { return r }
        return max(0, Int((Double(r) - inside.squareRoot()).rounded()))
    }

    static func circularCornerAlpha(radius r: Int, size: Int, x: Int, y: Int) -> UInt8 {
        if x < 0 || y < 0 || x >= size || y >= size { return 0 }
        if x >= r || y >= r { return 255 }
        let dx = Double(r) - (Double(x) + 0.5)
        let dy = Double(r) - (Double(y) + 0.5)
        return (dx * dx + dy * dy) <= Double(r * r) ? 255 : 0
    }
}

// MARK: - Own-process NSThemeFrame probes

/// Tiny off-screen windows so we can call private `NSThemeFrame._cornerRadius` safely
/// (same-process only). Reflects real system / `NSConvolutionOverride1` without capturing
/// other apps' pixels.
@MainActor
final class SystemCornerRadiusProbes {
    static let shared = SystemCornerRadiusProbes()

    private var plain: Int?
    private var toolbar: Int?
    private var utility: Int?
    private var didProbe = false

    func radius(for chrome: WindowCornerRadius.Chrome) -> Int? {
        ensureProbed()
        switch chrome {
            case .plain: return plain
            case .toolbar: return toolbar
            case .utility: return utility
        }
    }

    /// Force re-read (e.g. after config reload if user changed system defaults).
    func invalidate() {
        didProbe = false
        plain = nil
        toolbar = nil
        utility = nil
    }

    private func ensureProbed() {
        if didProbe { return }
        didProbe = true
        plain = Self.readThemeCornerRadius(makeProbeWindow(style: .plain))
        toolbar = Self.readThemeCornerRadius(makeProbeWindow(style: .toolbar))
        utility = Self.readThemeCornerRadius(makeProbeWindow(style: .utility))
    }

    private enum ProbeStyle { case plain, toolbar, utility }

    private func makeProbeWindow(style: ProbeStyle) -> NSWindow {
        let rect = NSRect(x: -10_000, y: -10_000, width: 400, height: 300)
        let mask: NSWindow.StyleMask
        let window: NSWindow
        switch style {
            case .plain:
                mask = [.titled, .closable, .miniaturizable, .resizable]
                window = NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: true)
            case .toolbar:
                mask = [.titled, .closable, .miniaturizable, .resizable]
                window = NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: true)
                let tb = NSToolbar(identifier: "aerospace.cornerRadius.probe")
                tb.displayMode = .iconOnly
                window.toolbar = tb
            case .utility:
                mask = [.titled, .closable, .utilityWindow]
                window = NSPanel(contentRect: rect, styleMask: mask, backing: .buffered, defer: true)
        }
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderBack(nil)
        window.displayIfNeeded()
        return window
    }

    /// Walk to `NSThemeFrame` and invoke private `_cornerRadius` / cache getter.
    private static func readThemeCornerRadius(_ window: NSWindow) -> Int? {
        defer {
            window.orderOut(nil)
            window.close()
        }
        let themeClass = NSClassFromString("NSThemeFrame") as? AnyClass
        var view: NSView? = window.contentView
        while let v = view {
            if let themeClass, v.isKind(of: themeClass) {
                if let r = invokeCornerRadius(on: v) { return r }
                break
            }
            view = v.superview
        }
        // Fallback: contentView.superview is often the theme frame
        if let superV = window.contentView?.superview, let r = invokeCornerRadius(on: superV) {
            return r
        }
        return nil
    }

    private static func invokeCornerRadius(on view: NSView) -> Int? {
        for name in ["_getCachedWindowCornerRadius", "_cornerRadius"] {
            let sel = NSSelectorFromString(name)
            guard view.responds(to: sel) else { continue }
            guard let imp = view.method(for: sel) else { continue }
            // CGFloat is Double on arm64 macOS
            typealias Fn = @convention(c) (AnyObject, Selector) -> CGFloat
            let fn = unsafeBitCast(imp, to: Fn.self)
            let value = fn(view, sel)
            if value.isFinite, value > 0 {
                return max(1, Int(value.rounded()))
            }
        }
        return nil
    }
}
