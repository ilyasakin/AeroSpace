import Foundation

/// Pure geometry helpers for the window-border dirty/occlusion hot path.
///
/// Kept free of AppKit / CA so they can be unit-tested and microbenchmarked without a live overlay.
/// The live manager only supplies ids/rects; all correctness and cost of "what to repaint" lives here.
enum WindowBordersMath {
    static func rectsIntersect(_ a: Rect, _ b: Rect) -> Bool {
        a.topLeftX < b.topLeftX + b.width && b.topLeftX < a.topLeftX + a.width &&
            a.topLeftY < b.topLeftY + b.height && b.topLeftY < a.topLeftY + a.height
    }

    /// Painted region of a border: window rect outset by stroke width
    static func region(rect: Rect, width: Int) -> Rect {
        let w = CGFloat(width)
        return Rect(topLeftX: rect.topLeftX - w, topLeftY: rect.topLeftY - w,
                    width: rect.width + 2 * w, height: rect.height + 2 * w)
    }

    /// True if `rect` intersects any bordered region's painted area. Early-outs on first hit —
    /// the common case for an unrelated app animation is "no"
    static func overlapsAnyBorder(regions: [(id: UInt32, region: Rect)], rect: Rect) -> Bool {
        for item in regions {
            if rectsIntersect(item.region, rect) { return true }
        }
        return false
    }

    /// Borders whose stroke and/or occlusion mask can change because `mover` moved between old/new.
    /// - The mover itself, if bordered
    /// - Any other border whose painted region intersects the mover's old or new frame (gain/lose occluder)
    static func affectedBorderIds(
        mover: UInt32,
        moverIsBordered: Bool,
        borderRegions: [(id: UInt32, region: Rect)],
        oldRect: Rect?,
        newRect: Rect,
    ) -> Set<UInt32> {
        var ids = Set<UInt32>()
        if moverIsBordered { ids.insert(mover) }
        for item in borderRegions {
            if item.id == mover { continue }
            if let old = oldRect, rectsIntersect(item.region, old) {
                ids.insert(item.id)
                continue
            }
            if rectsIntersect(item.region, newRect) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    /// Top-left-global rects of windows that cover `id`'s (outset) border region.
    /// Front-to-back stack: lower indices are above higher ones. Active window is forced frontmost
    /// for managed borders (never masked by another managed window; always clips inactive ones).
    static func occluders(
        id: UInt32,
        region: Rect,
        isActive: Bool,
        activeId: UInt32?,
        activeRect: Rect?,
        stack: [(id: UInt32, rect: Rect)],
        stackIndex: Int?,
        managedIds: Set<UInt32>,
    ) -> [Rect] {
        var result: [Rect] = []
        var included = Set<UInt32>()
        if let idx = stackIndex {
            for i in 0 ..< idx where rectsIntersect(region, stack[i].rect) {
                if isActive, managedIds.contains(stack[i].id) { continue }
                result.append(stack[i].rect)
                included.insert(stack[i].id)
            }
        }
        if !isActive, let activeId, !included.contains(activeId),
           let activeRect, rectsIntersect(region, activeRect)
        {
            result.append(activeRect)
        }
        return result
    }
}
