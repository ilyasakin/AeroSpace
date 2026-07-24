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
func waterfillTileSpans(weights: [CGFloat], caps: [CGFloat?], span: CGFloat) -> [CGFloat] {
    let n = weights.count
    guard n > 0 else { return [] }
    guard n == caps.count else { return weights } // misuse guard; caller passes matching arrays

    let w = weights.map { max($0, 0.0001) }
    let cap = caps.map { $0 ?? .greatestFiniteMagnitude }

    var result = [CGFloat](repeating: 0, count: n)
    var settled = [Bool](repeating: false, count: n)
    var remaining = max(span, 0)

    // Iterate: allocate proportionally among unsettled children; any that exceed their cap get
    // pinned to the cap and removed from the pool, freeing their overflow for the next round.
    while true {
        let activeWeight = (0 ..< n).reduce(CGFloat(0)) { $0 + (settled[$1] ? 0 : w[$1]) }
        guard activeWeight > 0 else { break } // everything settled
        var cappedThisRound = false
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
