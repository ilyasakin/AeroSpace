import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceMutable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    /// i3 tree normalization (only redundant split pairs collapse; `split` works). Overrides the
    /// two `enable-normalization-*` options. The i3 importer turns it on.
    var i3Normalization: Bool = false
    /// i3 `smart_gaps on`: no gaps while a workspace shows a single tile
    var smartGaps: Bool = false
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var tilingPolicy: TilingPolicy = .dwindle
    /// i3 `focus_wrapping` for directional `focus` without explicit --boundaries flags
    var focusWrapping: FocusWrapping = .yes
    /// i3 `mouse_warping`. `none` by default here: the default config already warps via
    /// on-focused-monitor-changed; the i3 importer emits i3's default (`output`)
    var mouseWarping: MouseWarping = .none
    /// i3 `workspace_auto_back_and_forth`: `workspace X` while on X goes back to the previous one
    var workspaceAutoBackAndForth: Bool = false
    /// Percentage of the tile the existing window keeps when dwindle splits it (10-90).
    /// 50 = even split; 62 approximates the golden-ratio spiral
    var dwindleSplitPercent: Int = 50
    /// Experimental: answer window frame reads from WindowServer (SkyLight) instead of the
    /// AX API. Faster and immune to busy apps; falls back to AX when unavailable
    var skyLightReads: Bool = false
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    /// `peek` (AeroSpace): accordion members overlap with `accordion-padding` peeks.
    /// `i3`: tabbed (h_accordion) / stacked (v_accordion) — each member gets the full container
    /// below a title band (one tab row / one row per member) drawn by the group tab bar.
    var accordionMode: AccordionMode = .peek
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()
    var floating: FloatingConfig = FloatingConfig()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var windowBorders: WindowBorders = .disabled
    var statusBar: StatusBarConfig = .disabled
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var windowDetectionRules: [WindowDetectionRule] = []
    var onModeChanged: Shell<any Command> = .empty
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
    /// Raise the hovered window. Default false (i3 / OmniWM): a tile under a floating window is
    /// focused without covering the float. Floating windows are always raised.
    var raise: Bool = false
}

/// Floating-window interaction (SIP-on approximations of i3 float layer).
struct FloatingConfig: ConvenienceMutable {
    /// Experimental: CGEventTap intercepts clicks on *exposed* tiling windows when the
    /// workspace has floats, applies private focus-without-raise, and redelivers the click
    /// to the target app so macOS does not raise the tile over floats.
    /// Only affects clicks where the topmost window under the cursor is a managed tile.
    var clickWithoutRaise: Bool = true
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
