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
        // Stay *below* the system menu bar. `.statusBar` is CG level 25 and `.mainMenu` is 24,
        // so a statusBar-level panel covers the native menu bar (including auto-hide peeks).
        // Most tiling users auto-hide the menu bar; the menu chrome must win when it appears.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        // Don't float above the menu bar layer via fullScreenAuxiliary stacking quirks.
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
        // orderFront is enough; orderFrontRegardless can race above higher-level system windows
        // on some macOS versions when combined with aggressive levels.
        orderFront(nil)
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
            case text(String, bg: NSColor?, fg: NSColor, action: (() -> Void)?)
            /// Per-core short-time history: samples[t][core], oldest → newest.
            case cpuHistory([[Double]], fg: NSColor)
            /// Single-series GPU history, oldest → newest.
            case gpuHistory([Double], last: Double?, fg: NSColor)
        }

        func width(of item: Placeable) -> CGFloat {
            switch item {
                case .text(let t, _, let color, _):
                    let attr = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color])
                    let isChip = t.count <= 2
                    return max(attr.size().width + (isChip ? 0 : 12), isChip ? height : 0)
                case .cpuHistory(let samples, _):
                    let cores = samples.last?.count ?? 1
                    let n = max(samples.count, StatusBarCpuSampler.historyCapacity)
                    return defaultHistoryGraphLayout(sampleCount: n, coreCount: max(1, cores)).totalWidth
                case .gpuHistory:
                    let n = max(gpuHistory.samples.count, StatusBarGpuSampler.historyCapacity)
                    return defaultHistoryGraphLayout(sampleCount: n, coreCount: 1, labelWidth: 10).totalWidth
            }
        }

        func place(_ item: Placeable, x: CGFloat) {
            let w = width(of: item)
            let frame = NSRect(x: x, y: 0, width: w, height: height)
            switch item {
                case .text(let t, let bg, let color, let action):
                    if let action {
                        let btn = StatusBarButton(frame: frame, title: t, font: font, fg: color, bg: bg, onClick: action)
                        addSubview(btn)
                        buttons.append(btn)
                    } else {
                        let chip = StatusBarChipView(frame: frame, title: t, font: font, fg: color, bg: bg)
                        addSubview(chip)
                        buttons.append(chip)
                    }
                case .cpuHistory(let samples, let color):
                    let graph = StatusBarHistoryGraphView(
                        frame: frame,
                        samples: samples,
                        accent: color,
                        mode: .cpu,
                    )
                    addSubview(graph)
                    buttons.append(graph)
                case .gpuHistory(let samples, let last, let color):
                    let graph = StatusBarHistoryGraphView(
                        frame: frame,
                        samples: samples.map { [$0] },
                        accent: color,
                        mode: .gpu,
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
                            out.append(.text(
                                ws.name,
                                bg: active ? focusBg : (visibleHere ? focusBg.withAlphaComponent(0.35) : nil),
                                fg: active ? focusFg : fg,
                                action: { onWorkspaceClick(ws.name) },
                            ))
                        }
                    case "mode":
                        if let mode = activeMode, mode != mainModeId {
                            out.append(.text("[\(mode)]", bg: nil, fg: fg, action: nil))
                        }
                    case "focused":
                        let title = focus.windowOrNil?.app.name ?? focus.workspace.name
                        out.append(.text(title, bg: nil, fg: fg, action: nil))
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
                            out.append(.text(text, bg: nil, fg: fg, action: nil))
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
            })
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

// MARK: - Short-time history graph (X = time, row = core)

enum StatusBarHistoryGraphMode {
    case cpu
    case gpu
}

/// Scrolling multi-core (or single GPU) history chart.
/// Each column is one sample (~1s); each row is one logical core. Newest is on the right.
@MainActor
final class StatusBarHistoryGraphView: NSView {
    /// samples[time][core], oldest → newest
    private var samples: [[Double]]
    private let accent: NSColor
    private let mode: StatusBarHistoryGraphMode
    private let dimmed: Bool

    init(
        frame: NSRect,
        samples: [[Double]],
        accent: NSColor,
        mode: StatusBarHistoryGraphMode,
        dimmed: Bool = false,
    ) {
        self.samples = samples
        self.accent = accent
        self.mode = mode
        self.dimmed = dimmed
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = tooltipString()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func tooltipString() -> String {
        switch mode {
            case .gpu:
                if let last = samples.last?.first, !dimmed {
                    return String(format: "GPU %.0f%% (last %ds)", last * 100, samples.count)
                }
                return "GPU utilization unavailable"
            case .cpu:
                guard let last = samples.last, !last.isEmpty else { return "CPU" }
                let avg = last.reduce(0, +) / Double(last.count)
                let parts = last.enumerated().map { i, v in String(format: "C%d: %.0f%%", i, v * 100) }
                return String(format: "CPU avg %.0f%% · %ds history — ", avg * 100, samples.count)
                    + parts.joined(separator: "  ")
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
        let coreCount = max(1, samples.last?.count ?? 1)
        let capacity = mode == .cpu ? StatusBarCpuSampler.historyCapacity : StatusBarGpuSampler.historyCapacity
        // Right-align history so growth fills from the right (scrolling feel as capacity fills).
        let sampleCount = max(samples.count, 1)
        let labelW: CGFloat = mode == .gpu ? 10 : 0
        let layout = defaultHistoryGraphLayout(
            sampleCount: capacity,
            coreCount: coreCount,
            columnWidth: 2.5,
            labelWidth: labelW,
        )

        // Chart background
        let chart = layout.rowTrackFrame(coreIndex: 0, viewHeight: bounds.height)
            .union(layout.rowTrackFrame(coreIndex: coreCount - 1, viewHeight: bounds.height))
        let bg = NSBezierPath(roundedRect: chart.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2)
        accent.withAlphaComponent(dimmed ? 0.08 : 0.12).setFill()
        bg.fill()

        if mode == .gpu {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: accent.withAlphaComponent(0.85),
                .paragraphStyle: para,
            ]
            ("G" as NSString).draw(
                in: NSRect(x: 0, y: (bounds.height - 11) / 2, width: labelW, height: 11),
                withAttributes: attrs,
            )
        }

        // Pad left with empty columns so the series sits flush right (scrolling window).
        let pad = max(0, capacity - sampleCount)
        let trackColor = accent.withAlphaComponent(0.14)
        let fillColor = accent.withAlphaComponent(dimmed ? 0.35 : 0.92)

        for core in 0 ..< coreCount {
            // Track under each core row
            trackColor.setFill()
            NSBezierPath(rect: layout.rowTrackFrame(coreIndex: core, viewHeight: bounds.height)).fill()

            for (si, sample) in samples.enumerated() {
                let load = core < sample.count ? sample[core] : 0
                let col = pad + si
                guard col < capacity else { continue }
                let cell = layout.cellFrame(
                    sampleIndex: col,
                    coreIndex: core,
                    load: load,
                    viewHeight: bounds.height,
                )
                fillColor.setFill()
                NSBezierPath(rect: cell).fill()
            }
        }
    }
}

/// Chip with true center alignment (NSTextField is unreliable for single glyphs).
@MainActor
private class StatusBarChipView: NSView {
    private let title: String
    private let font: NSFont
    private let fg: NSColor
    var onClick: (() -> Void)?

    init(frame: NSRect, title: String, font: NSFont, fg: NSColor, bg: NSColor?, onClick: (() -> Void)? = nil) {
        self.title = title
        self.font = font
        self.fg = fg
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
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: para,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        // Optical vertical center: AppKit text metrics sit slightly high for digits/letters.
        let y = ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero) - 0.5
        let rect = NSRect(x: 0, y: y, width: bounds.width, height: size.height)
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
    init(frame: NSRect, title: String, font: NSFont, fg: NSColor, bg: NSColor?, onClick: @escaping () -> Void) {
        super.init(frame: frame, title: title, font: font, fg: fg, bg: bg, onClick: onClick)
    }
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
}
