import Foundation

/// Pure geometry helpers for the window-border dirty/occlusion hot path.
///
/// Kept free of AppKit / CA so they can be unit-tested and microbenchmarked without a live overlay.
/// Hot-path APIs are **zero-heap**: callers pass reusable buffers. Cost target is **nanoseconds**
/// (a few rect compares per border), not microseconds from `Set`/`Array` allocation.
enum WindowBordersMath {
    @inline(__always)
    static func rectsIntersect(_ a: Rect, _ b: Rect) -> Bool {
        a.topLeftX < b.topLeftX + b.width && b.topLeftX < a.topLeftX + a.width &&
            a.topLeftY < b.topLeftY + b.height && b.topLeftY < a.topLeftY + a.height
    }

    /// Painted region of a border: window rect outset by stroke width (stack-only; no heap).
    @inline(__always)
    static func region(rect: Rect, width: Int) -> Rect {
        let w = CGFloat(width)
        return Rect(topLeftX: rect.topLeftX - w, topLeftY: rect.topLeftY - w,
                    width: rect.width + 2 * w, height: rect.height + 2 * w)
    }

    /// True if `rect` intersects any bordered region's painted area. Early-outs on first hit —
    /// the common case for an unrelated app animation is "no". Zero heap.
    static func overlapsAnyBorder(regions: [(id: UInt32, region: Rect)], rect: Rect) -> Bool {
        for item in regions {
            if rectsIntersect(item.region, rect) { return true }
        }
        return false
    }

    /// Append border ids whose stroke and/or occlusion mask can change because `mover` moved.
    /// - The mover itself, if bordered
    /// - Any other border whose painted region intersects the mover's old or new frame
    ///
    /// Does **not** clear `out` (caller owns capacity). Zero heap beyond `out`'s growth.
    static func appendAffectedBorderIds(
        mover: UInt32,
        moverIsBordered: Bool,
        borderRegions: [(id: UInt32, region: Rect)],
        oldRect: Rect?,
        newRect: Rect,
        into out: inout ContiguousArray<UInt32>,
    ) {
        if moverIsBordered { out.append(mover) }
        for item in borderRegions {
            if item.id == mover { continue }
            if let old = oldRect, rectsIntersect(item.region, old) {
                out.append(item.id)
                continue
            }
            if rectsIntersect(item.region, newRect) {
                out.append(item.id)
            }
        }
    }

    /// Test/bench convenience: builds a Set (allocating). Prefer `appendAffectedBorderIds` on the
    /// live path.
    static func affectedBorderIds(
        mover: UInt32,
        moverIsBordered: Bool,
        borderRegions: [(id: UInt32, region: Rect)],
        oldRect: Rect?,
        newRect: Rect,
    ) -> Set<UInt32> {
        var ids = ContiguousArray<UInt32>()
        ids.reserveCapacity(4)
        appendAffectedBorderIds(
            mover: mover,
            moverIsBordered: moverIsBordered,
            borderRegions: borderRegions,
            oldRect: oldRect,
            newRect: newRect,
            into: &ids,
        )
        return Set(ids)
    }

}
