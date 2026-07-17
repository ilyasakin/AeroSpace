/// How new windows are inserted into the tiling tree
public enum TilingPolicy: String, CaseIterable, Equatable, Sendable {
    /// AeroSpace's classic behavior: new windows join the most recent window's container as siblings.
    /// The tree is shaped manually with the split/join-with commands (i3 style)
    case manual
    /// Hyprland/bspwm style dynamic tiling: every new window binary-splits the focused window's
    /// tile, orientation chosen by the tile's aspect ratio (wider -> horizontal)
    case dwindle
}
