import AppKit
import Common

/// Runtime gap changes made with the `gaps` command (i3 `gaps inner current plus 5`). nil fields
/// fall through to the config. Reset by `reload-config`, like i3.
struct GapsOverride: Equatable, Sendable {
    var innerHorizontal: Int? = nil
    var innerVertical: Int? = nil
    var top: Int? = nil
    var left: Int? = nil
    var bottom: Int? = nil
    var right: Int? = nil

    func applied(to base: ResolvedGaps) -> ResolvedGaps {
        ResolvedGaps(
            inner: .init(vertical: innerVertical ?? base.inner.vertical, horizontal: innerHorizontal ?? base.inner.horizontal),
            outer: .init(left: left ?? base.outer.left, bottom: bottom ?? base.outer.bottom, top: top ?? base.outer.top, right: right ?? base.outer.right),
        )
    }
}

@MainActor var globalGapsOverride = GapsOverride()

@MainActor func resetRuntimeGapsOverrides() {
    globalGapsOverride = GapsOverride()
    for ws in Workspace.allUnsorted { ws.gapsOverride = GapsOverride() }
}

extension Workspace {
    /// The gaps this workspace is laid out with: config (per monitor) → runtime `gaps all` →
    /// runtime `gaps current` → i3 `smart_gaps` (none at all while a single tile is shown).
    /// Config + runtime overrides, before smart gaps (what `gaps plus|minus` counts from)
    @MainActor var configuredGaps: ResolvedGaps {
        let base = ResolvedGaps(gaps: config.gaps, monitor: workspaceMonitor)
        return gapsOverride.applied(to: globalGapsOverride.applied(to: base))
    }

    @MainActor var resolvedGaps: ResolvedGaps {
        let tuned = configuredGaps
        if config.smartGaps, rootTilingContainer.allLeafWindowsRecursive.count <= 1 {
            return ResolvedGaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
        }
        return tuned
    }

    /// The monitor's visible area minus this workspace's outer gaps — where its tiles go
    @MainActor var tilingRect: Rect {
        let visible = workspaceMonitor.visibleRect
        let g = resolvedGaps.outer
        return Rect(
            topLeftX: visible.topLeftX + CGFloat(g.left),
            topLeftY: visible.topLeftY + CGFloat(g.top),
            width: visible.width - CGFloat(g.left) - CGFloat(g.right),
            height: visible.height - CGFloat(g.top) - CGFloat(g.bottom),
        )
    }
}

/// i3 `gaps inner|outer|horizontal|vertical|top|right|bottom|left current|all set|plus|minus|toggle <px>`
struct GapsCommand: Command {
    let args: GapsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let ws = target.workspace
        let current = ws.configuredGaps
        let fields: [WritableKeyPath<GapsOverride, Int?>] = switch args.type.val {
            case .inner: [\.innerHorizontal, \.innerVertical]
            case .outer: [\.top, \.left, \.bottom, \.right]
            case .horizontal: [\.left, \.right]
            case .vertical: [\.top, \.bottom]
            case .top: [\.top]
            case .left: [\.left]
            case .bottom: [\.bottom]
            case .right: [\.right]
        }
        func currentValue(_ f: WritableKeyPath<GapsOverride, Int?>) -> Int {
            switch f {
                case \GapsOverride.innerHorizontal: current.inner.horizontal
                case \GapsOverride.innerVertical: current.inner.vertical
                case \GapsOverride.top: current.outer.top
                case \GapsOverride.left: current.outer.left
                case \GapsOverride.bottom: current.outer.bottom
                default: current.outer.right
            }
        }
        // toggle acts on the group: any edge on → all off, else all to <px>
        let groupIsOn = fields.contains { currentValue($0) != 0 }
        for f in fields {
            let now = currentValue(f)
            let px = Int(args.pixels.val)
            let new = switch args.operation.val {
                case .set: px
                case .plus: now + px
                case .minus: now - px
                case .toggle: groupIsOn ? 0 : px
            }
            switch args.scope.val {
                case .current: ws.gapsOverride[keyPath: f] = max(0, new)
                case .all:
                    globalGapsOverride[keyPath: f] = max(0, new)
                    for w in Workspace.allUnsorted { w.gapsOverride[keyPath: f] = nil }
            }
        }
        return .succ
    }
}
