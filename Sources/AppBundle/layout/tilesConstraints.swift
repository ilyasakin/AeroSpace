import CoreGraphics
import Foundation

/// Constraint-aware span distribution for tiles ("water-filling").
///
/// A tiled window can have a hard max size (e.g. System Settings caps at ~723px wide). macOS
/// exposes no max-size AX attribute, so the cap is *learned* by observing the window refuse to grow
/// (see `Window.learnedMaxSize`). Given per-child weights, an optional per-child cap, and the total
/// span, this returns each child's final span: capped children get exactly their cap, and the space
/// they can't use is redistributed to the uncapped children by weight — iteratively, because giving
/// a sibling more can push it past its own cap.
///
/// Pure and allocation-light so it can be unit-tested without a live layout. `caps[i] == nil` (or
/// `.infinity`) means "no cap". Weights ≤ 0 are treated as a tiny positive so a zero-weight child
/// still gets a sliver rather than NaN.
///
/// When every child is capped and the caps sum to less than `span`, the leftover is unavoidable
/// (nothing can grow) and is left as a trailing gap — the same outcome you'd get from the windows
/// clamping anyway.
///
/// `floors` are the mirror image (a learned min size): a child gets at least its floor, and its
/// siblings give up the difference. Floors that can't all fit in `span` are ignored — the windows
/// overflow either way, and proportional spans at least keep everyone visible.
func waterfillTileSpans(weights: [CGFloat], caps: [CGFloat?], floors: [CGFloat?] = [], span: CGFloat) -> [CGFloat] {
    let n = weights.count
    guard n > 0 else { return [] }
    guard n == caps.count else { return weights } // misuse guard; caller passes matching arrays

    let w = weights.map { max($0, 0.0001) }
    var cap = caps.map { $0 ?? .greatestFiniteMagnitude }
    let floorsFit = floors.count == n && floors.reduce(CGFloat(0)) { $0 + ($1 ?? 0) } <= max(span, 0)
    let floor: [CGFloat] = floorsFit ? floors.map { $0 ?? 0 } : Array(repeating: 0, count: n)
    for i in 0 ..< n where cap[i] < floor[i] { cap[i] = floor[i] } // a floor beats a cap

    var result = [CGFloat](repeating: 0, count: n)
    var settled = [Bool](repeating: false, count: n)
    var remaining = max(span, 0)

    // Iterate: allocate proportionally among unsettled children; any that exceed their cap get
    // pinned to the cap and removed from the pool, freeing their overflow for the next round.
    while true {
        let activeWeight = (0 ..< n).reduce(CGFloat(0)) { $0 + (settled[$1] ? 0 : w[$1]) }
        guard activeWeight > 0 else { break } // everything settled
        var cappedThisRound = false
        // Floors first: a child below its floor is pinned to it, and the rest share what's left
        for i in 0 ..< n where !settled[i] && floor[i] > 0 && remaining * (w[i] / activeWeight) < floor[i] {
            result[i] = floor[i]
            settled[i] = true
            cappedThisRound = true
        }
        if cappedThisRound {
            remaining = max(span, 0) - (0 ..< n).reduce(CGFloat(0)) { $0 + (settled[$1] ? result[$1] : 0) }
            continue
        }
        for i in 0 ..< n where !settled[i] {
            let share = remaining * (w[i] / activeWeight)
            if share >= cap[i] {
                result[i] = cap[i]
                settled[i] = true
                cappedThisRound = true
            }
        }
        if cappedThisRound {
            // Reclaim the capped children's fixed spans before the next round.
            remaining = max(span, 0) - (0 ..< n).reduce(CGFloat(0)) { $0 + (settled[$1] ? result[$1] : 0) }
        } else {
            // No one exceeds their cap — split the remainder proportionally and finish.
            for i in 0 ..< n where !settled[i] {
                result[i] = max(remaining, 0) * (w[i] / activeWeight)
                settled[i] = true
            }
            break
        }
    }
    return result
}

/// True when any child carries a finite cap below the span it would otherwise receive — i.e. the
/// cheap `nil` fast-path in the layout can be skipped only when a constraint actually bites.
func tileCapsAreActive(_ caps: [CGFloat?]) -> Bool {
    caps.contains { $0 != nil }
}
