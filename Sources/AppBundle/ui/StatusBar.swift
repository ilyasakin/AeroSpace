import AppKit
import Common
import Foundation

/// First-party status bar: per-monitor strip below the system menu bar.
/// Opt-in via `[bar] enabled = true`. Reuses NSPanelHud + hitTest passthrough from GroupTabBar.
@MainActor
final class StatusBarManager {
    static let shared = StatusBarManager()

    /// Keyed by monitor top-left (stable for the session; matches workspace monitor identity).
    private var panels: [String: StatusBarPanel] = [:]
    private var externalBlocks: [I3barBlock] = []
    private var externalProcess: Process?
    private var externalOutHandle: FileHandle?
    private var externalParser = I3barProtocolParser()
    private var externalStdin: FileHandle?
    private var clockTimer: Timer?
    private var lastCfgEnabled = false
    /// Last launched status-command argv (for reload change detection).
    private var lastStatusCommand: [String] = []
    private var externalFailCount = 0
    private var externalRespawnWork: DispatchWorkItem?

    private init() {}

    func refresh() {
        let cfg = config.statusBar
        guard cfg.enabled, TrayMenuModel.shared.isEnabled else {
            tearDown()
            return
        }
        if !lastCfgEnabled {
            lastCfgEnabled = true
            startClockTimer()
            startExternalModuleIfNeeded(cfg)
        } else {
            syncTimerCadence(cfg)
            if cfg.statusCommand != lastStatusCommand {
                restartExternal(cfg)
            } else if !cfg.statusCommand.isEmpty, externalProcess?.isRunning != true {
                // Module exited — respawn with backoff (avoid spawn-storm on instant failure).
                scheduleExternalRespawn(cfg)
            }
        }

        let mons = sortedMonitors
        var seen = Set<String>()
        for mon in mons {
            let key = "\(mon.name)@\(Int(mon.rect.topLeftX)),\(Int(mon.rect.topLeftY))"
            seen.insert(key)
            let panel = panels[key] ?? StatusBarPanel()
            panels[key] = panel
            panel.update(monitor: mon, config: cfg, externalBlocks: externalBlocks)
        }
        for (key, panel) in panels where !seen.contains(key) {
            panel.orderOut(nil)
            panels.removeValue(forKey: key)
        }
    }

    private func tearDown() {
        lastCfgEnabled = false
        clockTimer?.invalidate()
        clockTimer = nil
        stopExternal()
        lastStatusCommand = []
        externalFailCount = 0
        for (_, p) in panels { p.orderOut(nil) }
        panels.removeAll()
        externalBlocks = []
    }

    private var timerIsFast = false

    private func startClockTimer() {
        syncTimerCadence(config.statusBar)
    }

    private func syncTimerCadence(_ cfg: StatusBarConfig) {
        let needsFast = (cfg.modulesLeft + cfg.modulesRight).contains(where: statusBarModuleNeedsFastRefresh)
        if clockTimer != nil, timerIsFast == needsFast { return }
        clockTimer?.invalidate()
        timerIsFast = needsFast
        let interval: TimeInterval = needsFast ? 1.0 : 15.0
        clockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.timerIsFast == true {
                    _ = StatusBarCpuSampler.shared.sample()
                    _ = StatusBarGpuSampler.shared.sample()
                }
                self?.refresh()
            }
        }
        if needsFast {
            _ = StatusBarCpuSampler.shared.sample()
            _ = StatusBarGpuSampler.shared.sample()
        }
    }

    private func restartExternal(_ cfg: StatusBarConfig) {
        stopExternal()
        externalFailCount = 0
        startExternalModuleIfNeeded(cfg)
    }

    private func stopExternal() {
        externalRespawnWork?.cancel()
        externalRespawnWork = nil
        externalOutHandle?.readabilityHandler = nil
        externalOutHandle = nil
        if let p = externalProcess, p.isRunning {
            p.terminate()
        }
        externalProcess = nil
        externalStdin = nil
        externalParser.reset()
        externalBlocks = []
    }

    private func scheduleExternalRespawn(_ cfg: StatusBarConfig) {
        guard externalRespawnWork == nil else { return }
        externalFailCount += 1
        let delay = min(30.0, pow(2.0, Double(min(externalFailCount, 5))))
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.externalRespawnWork = nil
                guard config.statusBar.enabled, config.statusBar.statusCommand == cfg.statusCommand else { return }
                self.startExternalModuleIfNeeded(cfg)
            }
        }
        externalRespawnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startExternalModuleIfNeeded(_ cfg: StatusBarConfig) {
        lastStatusCommand = cfg.statusCommand
        guard let exe = cfg.statusCommand.first, !exe.isEmpty else { return }
        if externalProcess?.isRunning == true { return }

        let process = Process()
        process.executableURL = URL(filePath: exe)
        process.arguments = Array(cfg.statusCommand.dropFirst())
        var env = config.execConfig.envVariables
        env["I3SOCK"] = i3IpcSocketPath
        process.environment = env

        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice
        externalStdin = inPipe.fileHandleForWriting
        externalParser.reset()
        externalOutHandle = outPipe.fileHandleForReading

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF — clear handler to avoid busy-spin, mark process dead.
                handle.readabilityHandler = nil
                Task { @MainActor in
                    guard let self else { return }
                    self.externalOutHandle = nil
                    self.externalProcess = nil
                    self.externalStdin = nil
                    self.scheduleExternalRespawn(config.statusBar)
                }
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                let lines = self.externalParser.feed(text)
                if let last = lines.last {
                    self.externalBlocks = last
                    self.externalFailCount = 0 // healthy output
                    self.refresh()
                }
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.externalOutHandle?.readabilityHandler = nil
                self.externalOutHandle = nil
                self.externalProcess = nil
                self.externalStdin = nil
            }
        }

        do {
            try process.run()
            externalProcess = process
        } catch {
            externalProcess = nil
            scheduleExternalRespawn(cfg)
        }
    }

    func sendClick(_ event: I3barClickEvent) {
        guard externalParser.header?.clickEvents == true, let stdin = externalStdin else { return }
        let line = event.jsonLine() + "\n"
        if let data = line.data(using: .utf8) {
            try? stdin.write(contentsOf: data)
        }
    }
}

// MARK: - Panel

@MainActor
private final class StatusBarPanel: NSPanelHud {
    private let content = StatusBarContentView()
    private var monitorName: String = ""

    override init() {
        super.init()
        ignoresMouseEvents = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        contentView = content
        // Window level must stay:
        //   above normal app windows (0),
        //   below Notification Center banners / alerts (modal ≈ 8 and up),
        //   well below main menu (24) and status items (25).
        // Using mainMenu-1 (23) put the bar *above* system notifications — not acceptable.
        // `.floating` (3) is the standard always-on-top HUD tier for this.
        level = .floating
        // Don't use fullScreenAuxiliary stacking quirks that can elevate over system UI.
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    /// AX hit-testing (focus-follows-mouse → AXUIElementCopyElementAtPosition) can run off the
    /// main actor. Returning nil here keeps the bar invisible to AX so real app windows underneath
    /// are focused; mouse clicks still use the normal hitTest path on the main thread.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

    func update(monitor: Monitor, config: StatusBarConfig, externalBlocks: [I3barBlock]) {
        monitorName = monitor.name
        // Geometry: when the menu bar is *shown*, visibleRect is inset and we sit just under it.
        // When auto-hidden, visibleRect fills the screen — occupy the top strip (the freed menu-bar
        // zone). Native menu bar still paints above us thanks to window level.
        let full = monitor.rect
        let visible = monitor.visibleRect
        let menuBarInset = max(0, visible.topLeftY - full.topLeftY)
        let barTopY = menuBarInset > 1 ? full.topLeftY + menuBarInset : full.topLeftY
        let barH = CGFloat(config.height)
        let barRect = Rect(topLeftX: full.topLeftX, topLeftY: barTopY, width: full.width, height: barH)
        let ak = barRect.toAppKitFrame()
        setFrame(ak, display: true)

        content.rebuild(
            config: config,
            monitor: monitor,
            externalBlocks: externalBlocks,
            onWorkspaceClick: { name in
                // Same path as the tray menu — focus must run inside a light session.
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        _ = Workspace.get(byName: name).focusWorkspace()
                    }
                }
            },
            onExternalClick: { event in
                StatusBarManager.shared.sendClick(event)
            },
        )
        // Only front when hidden — re-orderFront every timer tick can restack the bar over
        // same-or-lower-level system UI (including notification banners).
        if !isVisible {
            orderFront(nil)
        }
    }
}

// MARK: - Content

@MainActor
private final class StatusBarContentView: NSView {
    private var buttons: [NSView] = []

    /// Must be nonisolated: AX hit-tests can invoke this off MainActor (Swift 6 traps otherwise).
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        // Off-main = AX path only; stay invisible so focus-follows-mouse sees windows below.
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit // empty region passthrough for mouse
        }
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

    func rebuild(
        config: StatusBarConfig,
        monitor: Monitor,
        externalBlocks: [I3barBlock],
        onWorkspaceClick: @escaping (String) -> Void,
        onExternalClick: @escaping (I3barClickEvent) -> Void,
    ) {
        for b in buttons { b.removeFromSuperview() }
        buttons.removeAll()

        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: config.background)?.cgColor
            ?? NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor

        let font = NSFont.systemFont(ofSize: CGFloat(config.fontSize))
        let fg = NSColor(hex: config.foreground) ?? .white
        let focusBg = NSColor(hex: config.focusedBackground) ?? .systemBlue
        let focusFg = NSColor(hex: config.focusedForeground) ?? .black

        var leftX: CGFloat = 8
        let height = bounds.height > 0 ? bounds.height : CGFloat(config.height)

        // Use last timer sample — do not Mach-sample on every redraw (FFM used to spam refresh()).
        let cpuHistory = StatusBarCpuSampler.shared.currentHistory
        let gpuHistory = StatusBarGpuSampler.shared.currentHistory

        enum Placeable {
            case text(String, bg: NSColor?, fg: NSColor, action: (() -> Void)?, icon: NSImage?)
            /// Per-sample core loads (averaged into a sparkline): samples[t][core], oldest → newest.
            case cpuHistory([[Double]], fg: NSColor)
            /// Single-series GPU history, oldest → newest.
            case gpuHistory([Double], last: Double?, fg: NSColor)
        }

        let sparkTrail = sparklinePercentTrailingWidth(fontSize: CGFloat(max(10, config.fontSize - 1)))
        let iconSide = max(12, min(height - 8, 18))

        func width(of item: Placeable) -> CGFloat {
            switch item {
                case .text(let t, _, let color, _, let icon):
                    let attr = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color])
                    let isChip = t.count <= 2 && icon == nil
                    var w = max(attr.size().width + (isChip ? 0 : 12), isChip ? height : 0)
                    if icon != nil {
                        w += iconSide + 6 // icon + gap before label
                        if t.count <= 2 { w += 8 } // keep padding when short labels sit next to icons
                    }
                    return w
                case .cpuHistory:
                    let n = StatusBarCpuSampler.historyCapacity
                    return defaultSparklineLayout(sampleCount: n, trailingWidth: sparkTrail).totalWidth
                case .gpuHistory:
                    let n = StatusBarGpuSampler.historyCapacity
                    return defaultSparklineLayout(sampleCount: n, trailingWidth: sparkTrail).totalWidth
            }
        }

        func place(_ item: Placeable, x: CGFloat) {
            let w = width(of: item)
            let frame = NSRect(x: x, y: 0, width: w, height: height)
            switch item {
                case .text(let t, let bg, let color, let action, let icon):
                    if let action {
                        let btn = StatusBarButton(
                            frame: frame,
                            title: t,
                            font: font,
                            fg: color,
                            bg: bg,
                            icon: icon,
                            iconSide: iconSide,
                            onClick: action,
                        )
                        addSubview(btn)
                        buttons.append(btn)
                    } else {
                        let chip = StatusBarChipView(
                            frame: frame,
                            title: t,
                            font: font,
                            fg: color,
                            bg: bg,
                            icon: icon,
                            iconSide: iconSide,
                        )
                        addSubview(chip)
                        buttons.append(chip)
                    }
                case .cpuHistory(let samples, let color):
                    let graph = StatusBarSparklineView(
                        frame: frame,
                        series: samples.map(cpuSampleAverage),
                        peaks: samples.map(cpuSamplePeak),
                        accent: color,
                        kind: .cpu,
                        lastCoreLoads: samples.last,
                    )
                    addSubview(graph)
                    buttons.append(graph)
                case .gpuHistory(let samples, let last, let color):
                    let graph = StatusBarSparklineView(
                        frame: frame,
                        series: samples,
                        peaks: nil,
                        accent: color,
                        kind: .gpu,
                        dimmed: last == nil && samples.isEmpty,
                    )
                    addSubview(graph)
                    buttons.append(graph)
            }
        }

        func items(for modules: [String]) -> [Placeable] {
            var out: [Placeable] = []
            let focus = focus
            for mod in modules {
                switch mod {
                    case "workspaces":
                        for ws in Workspace.all {
                            let active = ws.name == focus.workspace.name
                            if !statusBarShouldShowWorkspace(
                                isEmpty: ws.isEffectivelyEmpty,
                                isFocused: active,
                                hideEmpty: config.hideEmptyWorkspaces,
                            ) {
                                continue
                            }
                            let visibleHere = ws.isVisible
                                && ws.workspaceMonitor.rect.topLeftCorner == monitor.rect.topLeftCorner
                            let label = statusBarWorkspaceLabel(name: ws.name, symbols: config.workspaceSymbols)
                            out.append(.text(
                                label,
                                bg: active ? focusBg : (visibleHere ? focusBg.withAlphaComponent(0.35) : nil),
                                fg: active ? focusFg : fg,
                                action: { onWorkspaceClick(ws.name) },
                                icon: nil,
                            ))
                        }
                    case "mode":
                        if let mode = activeMode, mode != mainModeId {
                            out.append(.text("[\(mode)]", bg: nil, fg: fg, action: nil, icon: nil))
                        }
                    case "focused":
                        let window = focus.windowOrNil
                        // Empty workspace: show the same symbol/label as the workspaces module.
                        let title = window?.app.name
                            ?? statusBarWorkspaceLabel(name: focus.workspace.name, symbols: config.workspaceSymbols)
                        let icon = config.focusedShowIcon ? statusBarAppIcon(for: window) : nil
                        out.append(.text(title, bg: nil, fg: fg, action: nil, icon: icon))
                    case "cpu":
                        // Prefer ring buffer; until the second tick, show latest core sample once.
                        let effective: [[Double]] = {
                            if !cpuHistory.samples.isEmpty { return cpuHistory.samples }
                            let cores = StatusBarCpuSampler.shared.lastLoads
                            return cores.isEmpty ? [[0]] : [cores]
                        }()
                        out.append(.cpuHistory(effective, fg: fg))
                    case "gpu":
                        out.append(.gpuHistory(gpuHistory.samples, last: gpuHistory.lastKnown, fg: fg))
                    default:
                        if let text = statusBarSystemModuleText(mod) {
                            out.append(.text(text, bg: nil, fg: fg, action: nil, icon: nil))
                        }
                }
            }
            return out
        }

        // Left cluster
        for item in items(for: config.modulesLeft) {
            place(item, x: leftX)
            leftX += width(of: item) + 4
        }

        // External i3bar blocks after left modules
        for block in externalBlocks {
            let color = block.color.flatMap { NSColor(hex: $0) } ?? fg
            let bg = block.background.flatMap { NSColor(hex: $0) }
            let name = block.name
            let instance = block.instance
            let text = block.fullText
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let w = max(attr.size().width + 12, CGFloat(block.minWidth ?? 0))
            let frameX = leftX
            let item: Placeable = .text(text, bg: bg, fg: color, action: name == nil ? nil : {
                onExternalClick(I3barClickEvent(
                    name: name,
                    instance: instance,
                    button: 1,
                    x: Int(frameX.rounded()),
                    y: Int((height / 2).rounded()),
                ))
            }, icon: nil)
            place(item, x: leftX)
            leftX += w + 4
        }

        // Right cluster — pack from the right edge, preserving modules-right order L→R.
        let right = items(for: config.modulesRight)
        var rightX = bounds.width > 0 ? bounds.width - 8 : CGFloat(monitor.width) - 8
        if bounds.width <= 0 {
            rightX = CGFloat(monitor.width) - 8
            setFrameSize(NSSize(width: CGFloat(monitor.width), height: height))
        }
        for item in right.reversed() {
            let w = width(of: item)
            rightX -= w
            place(item, x: rightX)
            rightX -= 4
        }
    }
}

// MARK: - Utilization sparkline (X = time, height = load)

enum StatusBarSparklineKind {
    case cpu
    case gpu
}

/// Compact utilization history: one bar per second, height = load (0…100%).
/// CPU uses average across cores (peak shown as a faint tip); per-core detail is in the tooltip.
@MainActor
final class StatusBarSparklineView: NSView {
    /// Average (or single-series) load per sample, oldest → newest, 0...1.
    private let series: [Double]
    /// Optional peak-core load per sample (CPU); drawn as a faint tip above the average bar.
    private let peaks: [Double]?
    private let accent: NSColor
    private let kind: StatusBarSparklineKind
    private let dimmed: Bool
    private let lastCoreLoads: [Double]?

    init(
        frame: NSRect,
        series: [Double],
        peaks: [Double]?,
        accent: NSColor,
        kind: StatusBarSparklineKind,
        dimmed: Bool = false,
        lastCoreLoads: [Double]? = nil,
    ) {
        self.series = series
        self.peaks = peaks
        self.accent = accent
        self.kind = kind
        self.dimmed = dimmed
        self.lastCoreLoads = lastCoreLoads
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = tooltipString()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func tooltipString() -> String {
        switch kind {
            case .gpu:
                if let last = series.last, !dimmed {
                    return String(format: "GPU %.0f%% · last %ds", last * 100, series.count)
                }
                return "GPU utilization unavailable"
            case .cpu:
                guard let last = series.last else { return "CPU" }
                var s = String(format: "CPU avg %.0f%% · last %ds", last * 100, series.count)
                if let peak = peaks?.last {
                    s += String(format: " · peak core %.0f%%", peak * 100)
                }
                if let cores = lastCoreLoads, !cores.isEmpty {
                    let parts = cores.enumerated().map { i, v in String(format: "C%d %.0f%%", i, v * 100) }
                    s += " — " + parts.joined(separator: "  ")
                }
                return s
        }
    }

    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
    nonisolated override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let capacity = kind == .cpu ? StatusBarCpuSampler.historyCapacity : StatusBarGpuSampler.historyCapacity
        let trail = sparklinePercentTrailingWidth()
        let layout = defaultSparklineLayout(sampleCount: capacity, trailingWidth: trail)

        let track = layout.trackFrame(viewHeight: bounds.height)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        accent.withAlphaComponent(dimmed ? 0.08 : 0.14).setFill()
        trackPath.fill()

        // Midline (50%) for scale
        if !dimmed {
            accent.withAlphaComponent(0.12).setStroke()
            let mid = NSBezierPath()
            let y = track.minY + track.height * 0.5
            mid.move(to: NSPoint(x: track.minX + 1, y: y))
            mid.line(to: NSPoint(x: track.maxX - 1, y: y))
            mid.lineWidth = 1
            mid.stroke()
        }

        // Right-align history: empty pad on the left until the ring is full.
        let pad = max(0, capacity - series.count)
        let peakColor = accent.withAlphaComponent(dimmed ? 0.2 : 0.35)
        let barColor = accent.withAlphaComponent(dimmed ? 0.35 : 0.95)

        for (si, load) in series.enumerated() {
            let col = pad + si
            guard col < capacity else { continue }

            if let peaks, si < peaks.count {
                let peak = peaks[si]
                if peak > load + 0.02 {
                    let tip = layout.barFrame(sampleIndex: col, load: peak, viewHeight: bounds.height)
                    peakColor.setFill()
                    NSBezierPath(roundedRect: tip, xRadius: 0.8, yRadius: 0.8).fill()
                }
            }

            let bar = layout.barFrame(sampleIndex: col, load: load, viewHeight: bounds.height)
            if bar.height > 0 {
                barColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            }
        }

        // Live percent (right of chart)
        let last = series.last ?? 0
        let text: String = {
            if dimmed, series.isEmpty { return "—" }
            return String(format: "%.0f%%", last * 100)
        }()
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: accent.withAlphaComponent(dimmed ? 0.45 : 0.95),
            .paragraphStyle: para,
        ]
        let labelFrame = layout.trailingLabelFrame(viewHeight: bounds.height)
        let size = (text as NSString).size(withAttributes: attrs)
        let y = ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero) - 0.5
        (text as NSString).draw(
            in: NSRect(x: labelFrame.minX, y: y, width: labelFrame.width, height: size.height),
            withAttributes: attrs,
        )
    }
}

/// Chip with true center alignment (NSTextField is unreliable for single glyphs).
/// Optional leading app icon (used by the `focused` module when `focused-show-icon` is on).
@MainActor
private class StatusBarChipView: NSView {
    private let title: String
    private let font: NSFont
    private let fg: NSColor
    private let icon: NSImage?
    private let iconSide: CGFloat
    var onClick: (() -> Void)?

    init(
        frame: NSRect,
        title: String,
        font: NSFont,
        fg: NSColor,
        bg: NSColor?,
        icon: NSImage? = nil,
        iconSide: CGFloat = 16,
        onClick: (() -> Void)? = nil,
    ) {
        self.title = title
        self.font = font
        self.fg = fg
        self.icon = icon
        self.iconSide = iconSide
        self.onClick = onClick
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = bg?.cgColor
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let hasIcon = icon != nil
        var textOriginX: CGFloat = 0
        var textWidth = bounds.width

        if let icon {
            let side = min(iconSide, max(10, bounds.height - 6))
            let ix: CGFloat = 6
            let iy = ((bounds.height - side) / 2).rounded(.toNearestOrAwayFromZero)
            let iconRect = NSRect(x: ix, y: iy, width: side, height: side)
            // Template-ish: keep full-color Dock icons (don't apply tint).
            icon.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high],
            )
            textOriginX = ix + side + 4
            textWidth = max(0, bounds.width - textOriginX - 4)
        }

        let para = NSMutableParagraphStyle()
        para.alignment = hasIcon ? .left : .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: para,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        // Optical vertical center: AppKit text metrics sit slightly high for digits/letters.
        let y = ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero) - 0.5
        let rect = NSRect(x: textOriginX, y: y, width: textWidth, height: size.height)
        (title as NSString).draw(in: rect, withAttributes: attrs)
    }

    /// Claim the whole chip so nothing steals mouseDown (same lesson as GroupTabBar).
    /// nonisolated: AX may hit-test off MainActor under focus-follows-mouse.
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            guard onClick != nil else {
                let hit = super.hitTest(point)
                return hit === self ? nil : hit
            }
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    nonisolated override func isAccessibilityElement() -> Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
private final class StatusBarButton: StatusBarChipView {
    init(
        frame: NSRect,
        title: String,
        font: NSFont,
        fg: NSColor,
        bg: NSColor?,
        icon: NSImage? = nil,
        iconSide: CGFloat = 16,
        onClick: @escaping () -> Void,
    ) {
        super.init(
            frame: frame,
            title: title,
            font: font,
            fg: fg,
            bg: bg,
            icon: icon,
            iconSide: iconSide,
            onClick: onClick,
        )
    }
}

/// Dock icon for the window's app (for the `focused` module).
@MainActor
func statusBarAppIcon(for window: Window?) -> NSImage? {
    guard let window else { return nil }
    if let mac = window.app as? MacApp {
        if let icon = mac.nsApp.icon {
            return icon
        }
        if let path = mac.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
    }
    return nil
}

// MARK: - Color helper

extension NSColor {
    /// Parse `#RRGGBB` or i3bar `#RRGGBBAA` (8-digit alpha last, not AARRGGBB).
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let a, r, g, b: UInt64
        if s.count == 8 {
            // i3bar protocol: RRGGBBAA
            r = (value >> 24) & 0xFF
            g = (value >> 16) & 0xFF
            b = (value >> 8) & 0xFF
            a = value & 0xFF
        } else {
            a = 255
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        }
        self.init(
            calibratedRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255,
        )
    }

    /// Serialize to `#RRGGBB` or `#RRGGBBAA` (alpha omitted when fully opaque).
    func statusBarHexString() -> String {
        guard let rgb = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) else {
            return "#808080"
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return statusBarHexFromComponents(
            r: Int((r * 255).rounded().clamped(to: 0 ... 255)),
            g: Int((g * 255).rounded().clamped(to: 0 ... 255)),
            b: Int((b * 255).rounded().clamped(to: 0 ... 255)),
            a: Int((a * 255).rounded().clamped(to: 0 ... 255)),
        )
    }
}

/// Pure hex encoder for bar config / Settings color well (unit-testable).
func statusBarHexFromComponents(r: Int, g: Int, b: Int, a: Int = 255) -> String {
    let r = min(255, max(0, r))
    let g = min(255, max(0, g))
    let b = min(255, max(0, b))
    let a = min(255, max(0, a))
    if a >= 255 {
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    return String(format: "#%02X%02X%02X%02X", r, g, b, a)
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
