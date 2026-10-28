import Common
import CoreGraphics

/// i3 `focus_wrapping` (src/tree.c get_tree_next). What directional focus does when there is no
/// neighbour in the requested direction.
enum FocusWrapping: String, Sendable, Equatable {
    /// Leave to the adjacent monitor if there is one, else wrap inside the innermost container
    /// running in that direction (i3 default)
    case yes
    /// Leave to the adjacent monitor if there is one, else do nothing
    case no
    /// Always wrap inside the innermost container running in that direction; never leave it
    case force
    /// Wrap like `yes`, but never leave the workspace
    case workspace
}

/// How accordion containers present their members (see `accordion-mode`)
enum AccordionMode: String, Sendable, Equatable {
    case peek, i3
}

/// Height of one title row of an i3-style tabbed / stacked container
let i3TitleBandRowHeight: CGFloat = 22

/// i3 title band height for an accordion: one row of tabs (tabbed = horizontal), or one row per
/// member (stacked = vertical)
func i3TitleBandHeight(orientation: Orientation, childCount: Int) -> CGFloat {
    orientation == .h ? i3TitleBandRowHeight : i3TitleBandRowHeight * CGFloat(max(childCount, 1))
}
