import AppKit
import Common
import CoreGraphics

/// One raw WindowServer (SkyLight) border window per managed window, ordered directly above its
/// target — JankyBorders' model. The compositor then guarantees occlusion: anything covering the
/// target covers the border too, so there is no mask to keep in sync and nothing to leak over
/// floats. Raw SLS windows (not AppKit NSWindows) can be ordered arbitrarily in the global stack;
/// AppKit panels cannot, which is why the previous single-overlay-plus-mask design existed.
///
/// Symbols resolve at runtime (dlsym) so drift degrades to "no borders" instead of a launch crash.
enum BorderSkyLight {
    static let orderAbove: Int32 = 1
    static let backingBuffered: Int32 = 2

    fileprivate typealias ConnFun = @convention(c) () -> Int32
    fileprivate typealias NewRegionFun = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CFTypeRef?>) -> Int32
    fileprivate typealias NewWindowFun = @convention(c)
        (Int32, Int32, Float, Float, CFTypeRef, UnsafeMutablePointer<UInt32>) -> Int32
    fileprivate typealias ReleaseWindowFun = @convention(c) (Int32, UInt32) -> Int32
    fileprivate typealias CtxCreateFun = @convention(c) (Int32, UInt32, CFDictionary?) -> Unmanaged<CGContext>?
    fileprivate typealias SetResFun = @convention(c) (Int32, UInt32, Double) -> Int32
    fileprivate typealias SetOpacityFun = @convention(c) (Int32, UInt32, Bool) -> Int32
    fileprivate typealias SetEventShapeFun = @convention(c) (Int32, UInt32, CFTypeRef?) -> Int32
    fileprivate typealias MoveWindowFun = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32
    fileprivate typealias SetShapeFun = @convention(c) (Int32, UInt32, Float, Float, CFTypeRef) -> Int32
    fileprivate typealias GetLevelFun = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int64>) -> Int32
    fileprivate typealias GetSubLevelFun = @convention(c) (Int32, UInt32) -> Int32
    fileprivate typealias TxnCreateFun = @convention(c) (Int32) -> CFTypeRef?
    fileprivate typealias TxnCommitFun = @convention(c) (CFTypeRef, Int32) -> Int32
    fileprivate typealias TxnOrderFun = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
    fileprivate typealias TxnLevelFun = @convention(c) (CFTypeRef, UInt32, Int32) -> Int32

    @unsafe fileprivate struct Impl {
        let cid: Int32
        let newRegion: NewRegionFun
        let newWindow: NewWindowFun
        let releaseWindow: ReleaseWindowFun
        let ctxCreate: CtxCreateFun
        let setRes: SetResFun
        let setOpacity: SetOpacityFun
        let setEventShape: SetEventShapeFun
        let moveWindow: MoveWindowFun
        let setShape: SetShapeFun
        let getLevel: GetLevelFun
        let getSubLevel: GetSubLevelFun
        let txnCreate: TxnCreateFun
        let txnCommit: TxnCommitFun
        let txnOrder: TxnOrderFun
        let txnSetLevel: TxnLevelFun
        let txnSetSubLevel: TxnLevelFun
    }

    fileprivate static let impl: Impl? = {
        guard let h = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        else { return nil }
        func s<T>(_ name: String, _ type: T.Type) -> T? {
            unsafe dlsym(h, name).map { unsafe unsafeBitCast($0, to: type) }
        }
        guard let conn = s("SLSMainConnectionID", ConnFun.self),
              let newRegion = s("CGSNewRegionWithRect", NewRegionFun.self),
              let newWindow = s("SLSNewWindow", NewWindowFun.self),
              let releaseWindow = s("SLSReleaseWindow", ReleaseWindowFun.self),
              let ctxCreate = s("SLWindowContextCreate", CtxCreateFun.self),
              let setRes = s("SLSSetWindowResolution", SetResFun.self),
              let setOpacity = s("SLSSetWindowOpacity", SetOpacityFun.self),
              let setEventShape = s("SLSSetWindowEventShape", SetEventShapeFun.self),
              let moveWindow = s("SLSMoveWindow", MoveWindowFun.self),
              let setShape = s("SLSSetWindowShape", SetShapeFun.self),
              let getLevel = s("SLSGetWindowLevel", GetLevelFun.self),
              let getSubLevel = s("SLSGetWindowSubLevel", GetSubLevelFun.self),
              let txnCreate = s("SLSTransactionCreate", TxnCreateFun.self),
              let txnCommit = s("SLSTransactionCommit", TxnCommitFun.self),
              let txnOrder = s("SLSTransactionOrderWindow", TxnOrderFun.self),
              let txnSetLevel = s("SLSTransactionSetWindowLevel", TxnLevelFun.self),
              let txnSetSubLevel = s("SLSTransactionSetWindowSubLevel", TxnLevelFun.self)
        else { return nil }
        return unsafe Impl(
            cid: conn(),
            newRegion: newRegion,
            newWindow: newWindow,
            releaseWindow: releaseWindow,
            ctxCreate: ctxCreate,
            setRes: setRes,
            setOpacity: setOpacity,
            setEventShape: setEventShape,
            moveWindow: moveWindow,
            setShape: setShape,
            getLevel: getLevel,
            getSubLevel: getSubLevel,
            txnCreate: txnCreate,
            txnCommit: txnCommit,
            txnOrder: txnOrder,
            txnSetLevel: txnSetLevel,
            txnSetSubLevel: txnSetSubLevel,
        )
    }()

    static var isAvailable: Bool { unsafe impl != nil }
}

extension RgbaColor {
    var cg: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// One managed window's border, backed by a raw SkyLight window ordered above its target.
///
/// Geometry is in the unified top-left global space (same as `Rect.topLeftX/Y` and
/// `SLSGetWindowBounds`), which is exactly what `SLSNewWindow`/`SLSMoveWindow` expect. The
/// window's `CGContext` is bottom-left y-up (standard CoreGraphics); a centered ring stroke is
/// symmetric so no y-flip is needed.
@MainActor
final class BorderWindow {
    let targetWid: UInt32
    private var wid: UInt32 = 0
    private var context: CGContext?
    /// Border window frame in global top-left coords (target outset by width + style padding).
    private var frame: CGRect = .zero
    private var scale: Double = 2

    // Last painted style inputs — skip redraw when nothing visual changed.
    private var appliedStyle: BorderStyle?
    private var appliedWidth = -1
    private var appliedRadius = -1
    private var appliedFrameSize: CGSize = .zero

    init(targetWid: UInt32) {
        self.targetWid = targetWid
    }

    var isCreated: Bool { wid != 0 }

    /// Breathing room between the stroke's outer edge and the border window's own edge. Without
    /// it the ring sits flush with the window boundary and fractional tile sizes / retina rounding
    /// clip the far (right/bottom) edges to a hairline.
    private static let edgeMargin: CGFloat = 1

    /// Total outset of the border window beyond the target, past the stroke width: edge margin
    /// plus a glow's blur radius so the blur isn't clipped.
    private static func extraOutset(_ style: BorderStyle) -> CGFloat {
        if case .glow(_, let blur) = style { return edgeMargin + CGFloat(blur) * 2 }
        return edgeMargin
    }

    /// Create-or-update the border window for `rect` and paint `style`. `reorder` re-asserts the
    /// z-placement above the target — needed on create and on focus/raise/layout changes, but NOT
    /// on a plain move/resize (a window keeps its level and z-order while dragging), which is the
    /// hot path: skipping the reorder there drops ~225µs of WindowServer IPC per frame.
    func update(rect: Rect, width: Int, radius: Int, style: BorderStyle, scale: Double, reorder: Bool) {
        guard let impl = unsafe BorderSkyLight.impl else { return }
        self.scale = scale
        let pad = CGFloat(width) + Self.extraOutset(style)
        let ak = rect
        // .integral snaps to whole pixels so the backing never falls a fraction short of the
        // stroke on the far edges (another source of right/bottom hairlines).
        let newFrame = CGRect(
            x: CGFloat(ak.topLeftX) - pad,
            y: CGFloat(ak.topLeftY) - pad,
            width: CGFloat(ak.width) + 2 * pad,
            height: CGFloat(ak.height) + 2 * pad,
        ).integral
        guard newFrame.width > 0, newFrame.height > 0 else { return }

        let sizeChanged = newFrame.size != frame.size
        let originChanged = newFrame.origin != frame.origin
        frame = newFrame

        let justCreated = wid == 0
        if justCreated {
            createWindow(impl, frame: newFrame)
        } else if sizeChanged {
            resizeWindow(impl, frame: newFrame)
        } else if originChanged {
            var origin = CGPoint(x: newFrame.origin.x, y: newFrame.origin.y)
            _ = unsafe impl.moveWindow(impl.cid, wid, &origin)
        }
        guard wid != 0 else { return }

        let styleChanged = appliedStyle != style || appliedWidth != width
            || appliedRadius != radius || appliedFrameSize != newFrame.size
        if styleChanged || sizeChanged {
            appliedStyle = style
            appliedWidth = width
            appliedRadius = radius
            appliedFrameSize = newFrame.size
            draw(width: width, radius: radius, style: style)
        }
        // A fresh window has no z-placement yet; otherwise only re-order when asked.
        if justCreated || reorder {
            orderAboveTarget(impl)
        }
    }

    func release() {
        guard let impl = unsafe BorderSkyLight.impl, wid != 0 else { return }
        _ = unsafe impl.releaseWindow(impl.cid, wid)
        wid = 0
        context = nil
        appliedStyle = nil
    }

    // MARK: - Window lifecycle

    private func createWindow(_ impl: BorderSkyLight.Impl, frame: CGRect) {
        var local = CGRect(origin: .zero, size: frame.size)
        var region: CFTypeRef?
        guard unsafe impl.newRegion(&local, &region) == 0, let region else { return }
        var newId: UInt32 = 0
        let err = unsafe impl.newWindow(
            impl.cid, BorderSkyLight.backingBuffered,
            Float(frame.origin.x), Float(frame.origin.y), region, &newId,
        )
        guard err == 0, newId != 0 else { return }
        wid = newId
        _ = unsafe impl.setRes(impl.cid, wid, scale)
        _ = unsafe impl.setOpacity(impl.cid, wid, false)
        // Empty event shape → fully click-through, so the border ring never intercepts a click
        // meant for the window it surrounds (AppKit's ignoresMouseEvents equivalent for raw SLS).
        var empty = CGRect.zero
        var emptyRegion: CFTypeRef?
        if unsafe impl.newRegion(&empty, &emptyRegion) == 0 {
            _ = unsafe impl.setEventShape(impl.cid, wid, emptyRegion)
        }
        context = unsafe impl.ctxCreate(impl.cid, wid, nil)?.takeRetainedValue()
        appliedStyle = nil // force a paint
    }

    /// Resize in place: reshape the window and rebuild the context (the backing changed).
    private func resizeWindow(_ impl: BorderSkyLight.Impl, frame: CGRect) {
        var local = CGRect(origin: .zero, size: frame.size)
        var region: CFTypeRef?
        guard unsafe impl.newRegion(&local, &region) == 0, let region else { return }
        _ = unsafe impl.setShape(impl.cid, wid, 0, 0, region)
        var origin = CGPoint(x: frame.origin.x, y: frame.origin.y)
        _ = unsafe impl.moveWindow(impl.cid, wid, &origin)
        context = unsafe impl.ctxCreate(impl.cid, wid, nil)?.takeRetainedValue()
    }

    /// Match the target's level + sublevel, then order directly above it. Re-run on every update
    /// so a restack (focus/raise) keeps the border glued just above its window.
    private func orderAboveTarget(_ impl: BorderSkyLight.Impl) {
        var level: Int64 = 0
        _ = unsafe impl.getLevel(impl.cid, targetWid, &level)
        let sub = unsafe impl.getSubLevel(impl.cid, targetWid)
        guard let txn = unsafe impl.txnCreate(impl.cid) else { return }
        _ = unsafe impl.txnSetLevel(txn, wid, Int32(truncatingIfNeeded: level))
        _ = unsafe impl.txnSetSubLevel(txn, wid, sub)
        _ = unsafe impl.txnOrder(txn, wid, BorderSkyLight.orderAbove, targetWid)
        _ = unsafe impl.txnCommit(txn, 0)
    }

    // MARK: - Drawing

    private func draw(width: Int, radius: Int, style: BorderStyle) {
        guard let ctx = context else { return }
        let w = CGFloat(width)
        let bounds = CGRect(origin: .zero, size: frame.size)
        ctx.clear(bounds)
        guard w > 0 else { ctx.flush(); return }

        // Ring sits just outside the target, inset from the window edge by `extraOutset` so its
        // outer edge never touches the window boundary (no far-edge hairline).
        let pad = CGFloat(width) + Self.extraOutset(style)
        let strokeRect = bounds.insetBy(dx: pad - w / 2, dy: pad - w / 2)
        guard strokeRect.width > 0, strokeRect.height > 0 else { ctx.flush(); return }
        let r = CGFloat(radius) + w / 2
        let path = CGPath(roundedRect: strokeRect, cornerWidth: r, cornerHeight: r, transform: nil)

        switch style {
            case .solid(let c):
                ctx.setLineWidth(w)
                ctx.setStrokeColor(c.cg)
                ctx.addPath(path)
                ctx.strokePath()
            case .glow(let c, let blur):
                ctx.setShadow(offset: .zero, blur: CGFloat(blur), color: c.cg)
                ctx.setLineWidth(w)
                ctx.setStrokeColor(c.cg)
                ctx.addPath(path)
                ctx.strokePath()
            case .gradient(let angle, let stops):
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(w)
                ctx.replacePathWithStrokedPath() // stroke → fillable ring region
                ctx.clip()
                let colors = stops.map(\.cg) as CFArray
                let space = CGColorSpaceCreateDeviceRGB()
                let locations: [CGFloat] = stops.count <= 1
                    ? [0]
                    : (0 ..< stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) {
                    let (start, end) = gradientEndpoints(angleDegrees: angle, in: bounds)
                    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
                }
                ctx.restoreGState()
        }
        ctx.flush()
    }
}

/// Linear-gradient endpoints across `bounds` for an angle in degrees (0 = left→right, CCW).
private func gradientEndpoints(angleDegrees: Double, in bounds: CGRect) -> (CGPoint, CGPoint) {
    let rad = angleDegrees * .pi / 180
    let dx = cos(rad) * 0.5
    let dy = sin(rad) * 0.5
    let start = CGPoint(x: bounds.midX - dx * bounds.width, y: bounds.midY - dy * bounds.height)
    let end = CGPoint(x: bounds.midX + dx * bounds.width, y: bounds.midY + dy * bounds.height)
    return (start, end)
}
