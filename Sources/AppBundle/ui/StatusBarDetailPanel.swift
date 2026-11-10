import AppKit
import SwiftUI

/// What a click on a bar module opens: live detail for that module, refreshed every second while
/// open. Sampling (processes, sensors, per-process network) runs only while the panel shows.
enum StatusBarDetailKind: String, Equatable, Sendable {
    case cpu, gpu, memory, network, clock

    init?(module: String) { self.init(rawValue: module) }
}

/// One process row with the network rate it had since the previous sample
struct NetworkProcessRate: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let owner: String?
    let downBytesPerSecond: Double
    let upBytesPerSecond: Double
}

struct StatusBarDetailSnapshot: Equatable, Sendable {
    var cores: [Double] = []
    var topology = CpuTopology.current
    var thermal: ThermalSummary? = nil
    var topCpu: [ProcessUsage] = []
    var gpu: GpuDetails? = nil
    var memory: MemoryTotals? = nil
    var topMemory: [ProcessUsage] = []
    var downBytesPerSecond: Double? = nil
    var upBytesPerSecond: Double? = nil
    var topNetwork: [NetworkProcessRate] = []
    var now = Date()
}

/// The background half: everything that walks processes or asks the kernel, on its own queue
final class StatusBarDetailSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bobko.aerospace.bar-detail", qos: .utility)
    private let processes = ProcessSampler()
    private var lastNetTotals: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private var lastNetByPid: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    private var lastNetPerPidAt: TimeInterval = 0
    private var names: [pid_t: (name: String, owner: String?)] = [:]

    func sample(_ kind: StatusBarDetailKind, done: @escaping @Sendable (StatusBarDetailSnapshot) -> Void) {
        queue.async { [self] in
            var s = StatusBarDetailSnapshot()
            switch kind {
                case .cpu:
                    let all = processes.sample()
                    remember(all)
                    s.topCpu = Array(all.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(7))
                    s.thermal = ThermalSummary(ThermalSensors.read())
                case .gpu:
                    s.gpu = readGpuDetails()
                    s.thermal = ThermalSummary(ThermalSensors.read())
                case .memory:
                    let all = processes.sample()
                    remember(all)
                    s.memory = MemoryTotals.read()
                    s.topMemory = Array(all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(8))
                case .network:
                    sampleNetwork(into: &s)
                case .clock:
                    break
            }
            done(s)
        }
    }

    private func remember(_ all: [ProcessUsage]) {
        for p in all { names[p.pid] = (p.name, p.owner) }
    }

    private func sampleNetwork(into s: inout StatusBarDetailSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        if let totals = NetworkFlowStats.shared.poll() {
            if let last = lastNetTotals, now > last.at {
                s.downBytesPerSecond = Double(totals.rx &- last.rx) / (now - last.at)
                s.upBytesPerSecond = Double(totals.tx &- last.tx) / (now - last.at)
            }
            lastNetTotals = (totals.rx, totals.tx, now)
        }
        let byPid = NetworkFlowStats.shared.pollPerProcess()
        // Names for pids we have not seen (a cheap process walk only when needed)
        if byPid.keys.contains(where: { names[$0] == nil }) { remember(processes.sample()) }
        let dt = now - lastNetPerPidAt
        if lastNetPerPidAt > 0, dt > 0 {
            var rates: [NetworkProcessRate] = []
            for (pid, totals) in byPid {
                let old = lastNetByPid[pid] ?? (0, 0)
                // A flow appearing for a pid since last time counts from its first sighting only
                guard lastNetByPid[pid] != nil else { continue }
                let down = Double(totals.rx >= old.rx ? totals.rx - old.rx : 0) / dt
                let up = Double(totals.tx >= old.tx ? totals.tx - old.tx : 0) / dt
                guard down + up > 0 else { continue }
                let label = names[pid] ?? ("pid \(pid)", nil)
                rates.append(NetworkProcessRate(pid: pid, name: label.name, owner: label.owner, downBytesPerSecond: down, upBytesPerSecond: up))
            }
            s.topNetwork = Array(rates.sorted { $0.downBytesPerSecond + $0.upBytesPerSecond > $1.downBytesPerSecond + $1.upBytesPerSecond }.prefix(8))
        }
        lastNetByPid = byPid
        lastNetPerPidAt = now
    }
}

@MainActor
final class StatusBarDetailModel: ObservableObject {
    @Published var kind: StatusBarDetailKind = .cpu
    @Published var snapshot = StatusBarDetailSnapshot()
    @Published var worldClocks: [WorldClock] = []
}

// MARK: - Panel

@MainActor
final class StatusBarDetailPanel {
    static let shared = StatusBarDetailPanel()
    private var panel: NSPanelHud?
    private var hosting: NSHostingView<StatusBarDetailView>?
    private let model = StatusBarDetailModel()
    private var sampler = StatusBarDetailSampler()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var anchor: NSRect = .zero
    private var screenFrame: NSRect = .zero
    private(set) var openKind: StatusBarDetailKind?

    private init() {}

    /// Open `kind` under `anchor` (screen coordinates of the clicked module), or close it if it is
    /// already the one showing
    func toggle(_ kind: StatusBarDetailKind, anchor: NSRect, screen: NSScreen?) {
        if openKind == kind {
            close()
            return
        }
        guard Headless.permits(.onScreenPanel) else { return }
        if openKind == nil { sampler = StatusBarDetailSampler() } // fresh deltas per opening
        openKind = kind
        self.anchor = anchor
        screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        model.kind = kind
        model.worldClocks = config.statusBar.worldClocks.compactMap(WorldClock.init(spec:))
        model.snapshot = StatusBarDetailSnapshot()
        model.snapshot.cores = StatusBarCpuSampler.shared.lastLoads
        let panel = self.panel ?? makePanel()
        self.panel = panel
        refresh()
        layout()
        panel.orderFrontRegardless()
        startTimer()
        installMonitors()
    }

    func close() {
        openKind = nil
        timer?.invalidate()
        timer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanelHud {
        let panel = NSPanelHud()
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: StatusBarDetailView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        hosting = host
        return panel
    }

    /// Size to the content, top-left under the clicked module, kept on screen
    private func layout() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        var x = anchor.minX
        x = min(x, screenFrame.maxX - size.width - 6)
        x = max(x, screenFrame.minX + 6)
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: max(y, screenFrame.minY + 6), width: size.width, height: size.height), display: true)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in StatusBarDetailPanel.shared.refresh() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let kind = openKind else { return }
        model.snapshot.now = Date()
        model.snapshot.cores = StatusBarCpuSampler.shared.lastLoads
        sampler.sample(kind) { snapshot in
            Task { @MainActor in
                let panel = StatusBarDetailPanel.shared
                guard panel.openKind == kind else { return }
                var s = snapshot
                s.cores = StatusBarCpuSampler.shared.lastLoads
                panel.model.snapshot = s
                panel.layout()
            }
        }
    }

    /// A click anywhere else, or Esc, closes it. Clicks on the bar itself are left to the bar,
    /// so clicking the same module toggles and another module switches
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            Task { @MainActor in StatusBarDetailPanel.shared.close() }
        }) { monitors.append(global) }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return } // Esc
            Task { @MainActor in StatusBarDetailPanel.shared.close() }
        }) { monitors.append(keys) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            MainActor.assumeIsolated {
                let me = StatusBarDetailPanel.shared
                if event.window !== me.panel, !(event.window is StatusBarPanelMarker) { me.close() }
            }
            return event
        }) { monitors.append(local) }
    }
}

/// Lets the panel tell a click on the bar (which toggles) from a click elsewhere in AeroSpace
protocol StatusBarPanelMarker: AnyObject {}

// MARK: - World clocks

struct WorldClock: Equatable, Identifiable, Sendable {
    let name: String
    let timeZone: TimeZone
    var id: String { name + timeZone.identifier }

    /// `"Europe/Istanbul"` or `"San Francisco=America/Los_Angeles"`
    init?(spec: String) {
        let parts = spec.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let zoneId = parts.count == 2 ? parts[1] : parts[0]
        guard let zone = TimeZone(identifier: zoneId) else { return nil }
        timeZone = zone
        name = parts.count == 2 ? parts[0] : (zoneId.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zoneId)
    }

    /// "+3h", "−8h", "+5h30m" relative to `local` at `date`; "" when the same
    func offset(from local: TimeZone, at date: Date) -> String {
        let minutes = (timeZone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)) / 60
        if minutes == 0 { return "" }
        let sign = minutes > 0 ? "+" : "−"
        let h = abs(minutes) / 60, m = abs(minutes) % 60
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h\(m)m"
    }
}

// MARK: - Formatting

func formatBytes(_ bytes: UInt64) -> String {
    let b = Double(bytes)
    let mb = 1_048_576.0, gb = 1_073_741_824.0
    if b >= gb { return String(format: "%.1f GB", b / gb) }
    if b >= mb { return String(format: "%.0f MB", b / mb) }
    return String(format: "%.0f KB", b / 1024)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    let mb = 1_048_576.0
    if bytesPerSecond >= mb { return String(format: "%.1f MB/s", bytesPerSecond / mb) }
    if bytesPerSecond >= 1024 { return String(format: "%.0f KB/s", bytesPerSecond / 1024) }
    return String(format: "%.0f B/s", bytesPerSecond)
}

// MARK: - Views

struct StatusBarDetailView: View {
    @ObservedObject var model: StatusBarDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.kind {
                case .cpu: CpuDetail(s: model.snapshot)
                case .gpu: GpuDetail(s: model.snapshot)
                case .memory: MemoryDetail(s: model.snapshot)
                case .network: NetworkDetail(s: model.snapshot)
                case .clock: ClockDetail(clocks: model.worldClocks, now: model.snapshot.now)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .font(.system(size: 12))
        .foregroundStyle(.primary)
    }
}

private struct Title: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 13, weight: .semibold).monospacedDigit()) }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct Meter: View {
    let label: String
    let fraction: Double?
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1).frame(width: 84, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction ?? 0)))
                }
            }.frame(height: 6)
            Text(detail ?? fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                .monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
    private var color: Color {
        let f = fraction ?? 0
        return f > 0.85 ? .red : f > 0.6 ? .orange : .accentColor
    }
}

private struct ProcessRow: View {
    let name: String
    let owner: String?
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let owner { Text("via \(owner)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
    }
}

private struct Temperature: View {
    let label: String
    let value: Double?
    var body: some View {
        if let value {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f °C", value)).monospacedDigit()
                    .foregroundStyle(value > 90 ? .red : value > 75 ? .orange : .primary)
            }
        }
    }
}

private struct CpuDetail: View {
    let s: StatusBarDetailSnapshot
    var body: some View {
        let avg = s.cores.isEmpty ? nil : s.cores.reduce(0, +) / Double(s.cores.count)
        Title(text: "CPU", trailing: avg.map { String(format: "%.0f%%", $0 * 100) })
        if s.topology.efficiency > 0 {
            Text("\(s.topology.performance) performance + \(s.topology.efficiency) efficiency cores")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(s.cores.enumerated()), id: \.offset) { i, load in
                let kind = s.topology.kind(ofCore: i)
                let number = kind == "E" ? i + 1 : i - s.topology.efficiency + 1
                VStack(spacing: 3) {
                    Text(String(format: "%.0f", load * 100)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(kind == "P" ? Color.accentColor : Color.teal)
                            .frame(height: 44 * min(1, max(0.02, load)))
                    }.frame(width: 18, height: 44)
                    Text("\(kind)\(number)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        if let t = s.thermal, !t.isEmpty {
            SectionLabel(text: "Temperature")
            if let avg = t.dieAverage, let max = t.dieMax {
                HStack {
                    Text("Chip (\(t.dieSensors.count) die sensors)")
                    Spacer()
                    Text(String(format: "%.0f °C · max %.0f", avg, max)).monospacedDigit()
                        .foregroundStyle(max > 90 ? .red : max > 75 ? .orange : .primary)
                }
            }
            Temperature(label: "Package", value: t.packageMax)
            Temperature(label: "SSD", value: t.ssd)
            Temperature(label: "Battery", value: t.battery)
        }
        SectionLabel(text: "Top processes")
        if s.topCpu.isEmpty { Text("Measuring…").foregroundStyle(.secondary) }
        ForEach(s.topCpu, id: \.pid) { p in
            ProcessRow(name: p.name, owner: p.owner, value: String(format: "%.1f%%", p.cpuPercent))
        }
    }
}

private struct GpuDetail: View {
    let s: StatusBarDetailSnapshot
    var body: some View {
        Title(text: s.gpu?.name ?? "GPU", trailing: s.gpu?.device.map { String(format: "%.0f%%", $0 * 100) })
        if let g = s.gpu {
            Meter(label: "Device", fraction: g.device)
            Meter(label: "Renderer", fraction: g.renderer)
            Meter(label: "Tiler", fraction: g.tiler)
            if let used = g.memoryInUseBytes {
                SectionLabel(text: "Memory")
                HStack {
                    Text("In use")
                    Spacer()
                    Text(formatBytes(used) + (g.memoryAllocatedBytes.map { " of \(formatBytes($0)) allocated" } ?? "")).monospacedDigit()
                }
            }
        } else {
            Text("GPU statistics unavailable").foregroundStyle(.secondary)
        }
        if let t = s.thermal, let max = t.dieMax {
            SectionLabel(text: "Temperature")
            Temperature(label: "Chip (hottest die sensor)", value: max)
        }
    }
}

private struct MemoryDetail: View {
    let s: StatusBarDetailSnapshot
    var body: some View {
        if let m = s.memory {
            Title(text: "Memory", trailing: "\(formatBytes(m.usedBytes)) / \(formatBytes(m.totalBytes))")
            Meter(label: "Used", fraction: Double(m.usedBytes) / Double(max(m.totalBytes, 1)))
            Meter(label: "App", fraction: Double(m.appBytes) / Double(max(m.totalBytes, 1)), detail: formatBytes(m.appBytes))
            Meter(label: "Wired", fraction: Double(m.wiredBytes) / Double(max(m.totalBytes, 1)), detail: formatBytes(m.wiredBytes))
            Meter(label: "Compressed", fraction: Double(m.compressedBytes) / Double(max(m.totalBytes, 1)), detail: formatBytes(m.compressedBytes))
            if m.swapTotalBytes > 0 {
                HStack {
                    Text("Swap")
                    Spacer()
                    Text(formatBytes(m.swapUsedBytes)).monospacedDigit()
                        .foregroundStyle(m.swapUsedBytes > 8 * 1_073_741_824 ? .orange : .primary)
                }
            }
        } else {
            Title(text: "Memory")
        }
        SectionLabel(text: "Top processes")
        if s.topMemory.isEmpty { Text("Measuring…").foregroundStyle(.secondary) }
        ForEach(s.topMemory, id: \.pid) { p in
            ProcessRow(name: p.name, owner: p.owner, value: formatBytes(p.memoryBytes))
        }
    }
}

private struct NetworkDetail: View {
    let s: StatusBarDetailSnapshot
    var body: some View {
        Title(text: "Network")
        HStack {
            Label(s.downBytesPerSecond.map(formatRate) ?? "—", systemImage: "arrow.down")
            Spacer()
            Label(s.upBytesPerSecond.map(formatRate) ?? "—", systemImage: "arrow.up")
        }.monospacedDigit()
        SectionLabel(text: "Top processes")
        if s.topNetwork.isEmpty { Text("Measuring… (only processes with traffic are listed)").foregroundStyle(.secondary) }
        ForEach(s.topNetwork, id: \.pid) { p in
            ProcessRow(name: p.name, owner: p.owner, value: "↓\(formatRate(p.downBytesPerSecond))  ↑\(formatRate(p.upBytesPerSecond))")
        }
    }
}

private struct ClockDetail: View {
    let clocks: [WorldClock]
    let now: Date
    var body: some View {
        Title(text: "World clock")
        if clocks.isEmpty { Text("Set bar.world-clocks in the config").foregroundStyle(.secondary) }
        ForEach(clocks) { c in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 13, weight: .medium))
                    Text(dayAndOffset(c)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(time(c)).font(.system(size: 20, weight: .medium).monospacedDigit())
            }
        }
    }

    private func time(_ c: WorldClock) -> String {
        let f = DateFormatter()
        f.timeZone = c.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: now)
    }

    private func dayAndOffset(_ c: WorldClock) -> String {
        let f = DateFormatter()
        f.timeZone = c.timeZone
        f.dateFormat = "EEE d MMM"
        let offset = c.offset(from: .current, at: now)
        return offset.isEmpty ? f.string(from: now) : "\(f.string(from: now)) · \(offset)"
    }
}
