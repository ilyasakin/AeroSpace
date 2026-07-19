import Darwin
import Foundation
import IOKit.ps
import ISSoundAdditions

// MARK: - Catalog

/// Built-in module ids (order is the default catalog order in Settings).
enum StatusBarBuiltinModule: String, CaseIterable, Sendable {
    case workspaces
    case mode
    case focused
    case clock
    case battery
    case cpu
    case gpu
    case memory
    case volume
    case network

    var title: String {
        switch self {
            case .workspaces: "Workspaces"
            case .mode: "Binding mode"
            case .focused: "Focused app"
            case .clock: "Clock"
            case .battery: "Battery"
            case .cpu: "CPU (sparkline)"
            case .gpu: "GPU (sparkline)"
            case .memory: "Memory"
            case .volume: "Volume"
            case .network: "Network"
        }
    }

    /// Default placement suggestion for new installs / Settings add list grouping.
    var defaultSide: Side {
        switch self {
            case .workspaces, .mode, .focused: .left
            default: .right
        }
    }

    enum Side { case left, right }

    static var allIds: [String] { allCases.map(\.rawValue) }
}

/// Whether the workspaces module should list a workspace. Pure for unit tests.
/// Focused workspace is always shown so the bar still reflects the current space when empty.
func statusBarShouldShowWorkspace(isEmpty: Bool, isFocused: Bool, hideEmpty: Bool) -> Bool {
    if !hideEmpty { return true }
    if isFocused { return true }
    return !isEmpty
}

// MARK: - Pure module text builders (unit-testable)

enum StatusBarClock {
    /// Format local time with a `strftime`-style pattern (Sketchybar-compatible).
    /// Supported tokens: `%H` `%M` `%S` `%d` `%m` `%Y` `%y` `%%`. Unknown tokens pass through.
    static func text(
        date: Date = Date(),
        calendar: Calendar = .current,
        format: String = "%H:%M",
    ) -> String {
        statusBarFormatClock(date: date, calendar: calendar, format: format)
    }
}

/// Pure clock formatter for unit tests.
func statusBarFormatClock(date: Date, calendar: Calendar, format: String) -> String {
    var out = ""
    var i = format.startIndex
    while i < format.endIndex {
        let ch = format[i]
        if ch == "%", format.index(after: i) < format.endIndex {
            let next = format[format.index(after: i)]
            switch next {
                case "H": out += String(format: "%02d", calendar.component(.hour, from: date))
                case "M": out += String(format: "%02d", calendar.component(.minute, from: date))
                case "S": out += String(format: "%02d", calendar.component(.second, from: date))
                case "d": out += String(format: "%02d", calendar.component(.day, from: date))
                case "m": out += String(format: "%02d", calendar.component(.month, from: date))
                case "Y": out += String(format: "%04d", calendar.component(.year, from: date))
                case "y": out += String(format: "%02d", calendar.component(.year, from: date) % 100)
                case "%": out += "%"
                default:
                    out.append(ch)
                    out.append(next)
            }
            i = format.index(i, offsetBy: 2)
            continue
        }
        out.append(ch)
        i = format.index(after: i)
    }
    return out
}

/// How a built-in module renders in the bar: plain text with an optional SF Symbol icon, or a
/// filled meter (memory). `symbols` are fallback candidates — first name that resolves wins,
/// because symbol names drift across macOS releases.
enum StatusBarModuleRender: Equatable {
    case text(String, symbols: [String])
    case meter(fraction: Double, label: String, symbols: [String], tooltip: String)
}

enum StatusBarBattery {
    /// Snapshot for tests / live IOKit.
    struct Snapshot: Equatable {
        var percent: Int?
        var isCharging: Bool
        var isPresent: Bool
    }

    static func text(from snap: Snapshot) -> String? {
        guard snap.isPresent, let p = snap.percent else { return nil }
        let icon = snap.isCharging ? "⚡" : "🔋"
        return "\(icon)\(p)%"
    }

    static func render(from snap: Snapshot) -> StatusBarModuleRender? {
        guard snap.isPresent, let p = snap.percent else { return nil }
        let symbols: [String] = if snap.isCharging {
            ["battery.100percent.bolt", "battery.100.bolt", "bolt.fill"]
        } else if p >= 85 {
            ["battery.100percent", "battery.100"]
        } else if p >= 60 {
            ["battery.75percent", "battery.75"]
        } else if p >= 35 {
            ["battery.50percent", "battery.50"]
        } else if p >= 10 {
            ["battery.25percent", "battery.25"]
        } else {
            ["battery.0percent", "battery.0"]
        }
        return .text("\(p)%", symbols: symbols)
    }

    static func liveSnapshot() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return Snapshot(percent: nil, isCharging: false, isPresent: false)
        }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let present = (desc[kIOPSIsPresentKey] as? Bool) ?? true
            guard present else { continue }
            let percent = desc[kIOPSCurrentCapacityKey] as? Int
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let charging = state == kIOPSACPowerValue
                || (desc[kIOPSIsChargingKey] as? Bool) == true
            return Snapshot(percent: percent, isCharging: charging, isPresent: true)
        }
        return Snapshot(percent: nil, isCharging: false, isPresent: false)
    }
}

enum StatusBarCpuMem {
    struct MemorySnapshot: Equatable {
        /// Used fraction 0...1 of physical memory.
        var usedFraction: Double
        var usedBytes: UInt64
        var totalBytes: UInt64
    }

    static func cpuText() -> String {
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == -1 {
            return "CPU ?"
        }
        return String(format: "CPU %.2f", load[0])
    }

    static func memoryText(from snap: MemorySnapshot? = nil) -> String {
        let s = snap ?? liveMemorySnapshot()
        guard let s else { return "MEM ?" }
        let pct = Int((s.usedFraction * 100).rounded())
        return "MEM \(pct)%"
    }

    /// Memory as a fill meter: capsule gauge + used-GB label (replaces the bare "MEM 62%" text).
    static func memoryRender(from snap: MemorySnapshot? = nil) -> StatusBarModuleRender {
        guard let s = snap ?? liveMemorySnapshot() else {
            return .text("MEM ?", symbols: ["memorychip"])
        }
        let usedGb = Double(s.usedBytes) / 1_073_741_824
        let totalGb = Double(s.totalBytes) / 1_073_741_824
        let pct = Int((s.usedFraction * 100).rounded())
        return .meter(
            fraction: s.usedFraction,
            label: String(format: "%.1fG", usedGb),
            symbols: ["memorychip"],
            tooltip: String(format: "Memory %.1f GB used of %.0f GB (%d%%)", usedGb, totalGb, pct),
        )
    }

    static func liveMemorySnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size,
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSizeU: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeU)
        let pageSize = UInt64(pageSizeU == 0 ? 4096 : pageSizeU)
        // "Used" ≈ active + wired + compressor (common status-bar definition).
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * pageSize
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }
        let frac = min(1.0, Double(usedBytes) / Double(totalBytes))
        return MemorySnapshot(usedFraction: frac, usedBytes: usedBytes, totalBytes: totalBytes)
    }
}

enum StatusBarVolume {
    struct Snapshot: Equatable {
        var percent: Int // 0...100
        var isMuted: Bool
    }

    static func text(from snap: Snapshot) -> String {
        if snap.isMuted { return "🔇 mute" }
        let icon = snap.percent == 0 ? "🔈" : (snap.percent < 50 ? "🔉" : "🔊")
        return "\(icon) \(snap.percent)%"
    }

    static func render(from snap: Snapshot) -> StatusBarModuleRender {
        if snap.isMuted { return .text("mute", symbols: ["speaker.slash.fill"]) }
        let symbols: [String] = switch snap.percent {
            case 0: ["speaker.fill"]
            case ..<34: ["speaker.wave.1.fill"]
            case ..<67: ["speaker.wave.2.fill"]
            default: ["speaker.wave.3.fill"]
        }
        return .text("\(snap.percent)%", symbols: symbols)
    }

    static func liveSnapshot() -> Snapshot {
        do {
            let muted = Sound.output.isMuted
            let vol = muted ? 0 : Int((try Sound.output.readVolume() * 100).rounded())
            return Snapshot(percent: max(0, min(100, vol)), isMuted: muted)
        } catch {
            return Snapshot(percent: 0, isMuted: true)
        }
    }
}

/// Interface byte-counter sampler for live ↓/↑ rates. Counters come from getifaddrs AF_LINK
/// if_data (32-bit, wrap-safe delta); summed over en* (physical Wi-Fi/Ethernet — VPN utun traffic
/// is counted on the underlying en* anyway, so tunnels don't double-count).
@MainActor
final class StatusBarNetSampler {
    static let shared = StatusBarNetSampler()
    /// Don't recompute rates faster than this even if refresh() is spammed.
    static let minSampleInterval: TimeInterval = 0.9
    /// A per-tick delta above this is a 32-bit counter wrap glitch, not traffic — skip the update.
    private static let wrapGlitchThreshold: UInt64 = 4 << 30

    private var lastTotals: (rx: UInt64, tx: UInt64)?
    private var lastAt: TimeInterval = 0
    private(set) var rxPerSec: Double = 0
    private(set) var txPerSec: Double = 0

    private init() {}

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        if lastAt > 0, now - lastAt < Self.minSampleInterval { return }
        // Flow-level counters (ntstat) first: interface counters miss inbound bytes when VPNs /
        // content filters / Skywalk carry the flow (downlink reads 0). See NetworkFlowStats.
        guard let totals = NetworkFlowStats.shared.poll() ?? Self.readTotals() else { return }
        if let last = lastTotals, lastAt > 0 {
            let dt = now - lastAt
            let dRx = totals.rx &- last.rx
            let dTx = totals.tx &- last.tx
            if dt > 0, dRx < Self.wrapGlitchThreshold, dTx < Self.wrapGlitchThreshold {
                rxPerSec = Double(dRx) / dt
                txPerSec = Double(dTx) / dt
            }
        }
        lastTotals = totals
        lastAt = now
    }

    private static func readTotals() -> (rx: UInt64, tx: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var found = false
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = current.pointee.ifa_data
            else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            rx &+= UInt64(data.ifi_ibytes)
            tx &+= UInt64(data.ifi_obytes)
            found = true
        }
        return found ? (rx, tx) : nil
    }
}

/// Compact rate label: "0K" → "999K" → "1.2M" → "1.2G" (bytes/s, 1024 base). Pure for tests.
func statusBarFormatRate(bytesPerSec: Double) -> String {
    let kb = max(0, bytesPerSec) / 1024
    if kb < 1000 { return String(format: "%.0fK", kb) }
    let mb = kb / 1024
    if mb < 1000 { return String(format: "%.1fM", mb) }
    return String(format: "%.1fG", mb / 1024)
}

enum StatusBarNetwork {
    struct Snapshot: Equatable {
        var interface: String
        var address: String? // IPv4 or IPv6 display
        var isUp: Bool
    }

    static func text(from snap: Snapshot) -> String {
        if !snap.isUp { return "🌐 offline" }
        if let address = snap.address {
            return "🌐 \(snap.interface) \(address)"
        }
        return "🌐 \(snap.interface)"
    }

    /// Live throughput instead of the static interface/IP line. Pure for tests.
    static func render(isUp: Bool, rxPerSec: Double, txPerSec: Double) -> StatusBarModuleRender {
        guard isUp else { return .text("offline", symbols: ["wifi.slash"]) }
        let down = statusBarFormatRate(bytesPerSec: rxPerSec)
        let up = statusBarFormatRate(bytesPerSec: txPerSec)
        return .text("↓\(down) ↑\(up)", symbols: ["network"])
    }

    static func liveSnapshot() -> Snapshot {
        // Prefer a non-loopback interface with an IPv4 address (typical en0 / en1).
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return Snapshot(interface: "?", address: nil, isUp: false)
        }
        defer { freeifaddrs(ifaddr) }

        var best: Snapshot?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoop = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoop, let addr = current.pointee.ifa_addr else { continue }

            let name = String(cString: current.pointee.ifa_name)
            // Skip link-local utun / awdl noise when we already have a better candidate
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") { continue }

            let family = addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(addr, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    // Prefer en* (Wi‑Fi/Ethernet) over others
                    let candidate = Snapshot(interface: name, address: ip, isUp: true)
                    if name.hasPrefix("en") {
                        return candidate
                    }
                    if best == nil { best = candidate }
                }
            } else if family == UInt8(AF_INET6), best == nil {
                // Keep IPv6 only as weak fallback
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(addr, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    var ip = String(cString: hostname)
                    if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                    best = Snapshot(interface: name, address: ip, isUp: true)
                }
            }
        }
        return best ?? Snapshot(interface: "—", address: nil, isUp: false)
    }
}

/// Resolve a built-in system module to display text (nil = hide this tick).
@MainActor
func statusBarSystemModuleText(_ id: String) -> String? {
    switch id {
        case "clock": return StatusBarClock.text(format: config.statusBar.clockFormat)
        case "battery": return StatusBarBattery.text(from: StatusBarBattery.liveSnapshot())
        // cpu / gpu render as graphs — optional text fallback for tests / external use
        case "cpu":
            let cores = StatusBarCpuSampler.shared.lastLoads
            if cores.isEmpty { return "CPU …" }
            let avg = cores.reduce(0, +) / Double(cores.count)
            return String(format: "CPU %d%%×%d", Int((avg * 100).rounded()), cores.count)
        case "gpu":
            if let u = StatusBarGpuSampler.shared.last.utilization {
                return String(format: "GPU %d%%", Int((u * 100).rounded()))
            }
            return "GPU —"
        case "memory": return StatusBarCpuMem.memoryText()
        case "volume": return StatusBarVolume.text(from: StatusBarVolume.liveSnapshot())
        case "network": return StatusBarNetwork.text(from: StatusBarNetwork.liveSnapshot())
        default: return nil
    }
}

/// Resolve a built-in system module to its bar rendering (nil = hide this tick).
@MainActor
func statusBarSystemModuleRender(_ id: String) -> StatusBarModuleRender? {
    switch id {
        case "battery": StatusBarBattery.render(from: StatusBarBattery.liveSnapshot())
        case "memory": StatusBarCpuMem.memoryRender()
        case "volume": StatusBarVolume.render(from: StatusBarVolume.liveSnapshot())
        case "network": StatusBarNetwork.render(
            isUp: StatusBarNetwork.liveSnapshot().isUp,
            rxPerSec: StatusBarNetSampler.shared.rxPerSec,
            txPerSec: StatusBarNetSampler.shared.txPerSec,
        )
        default: statusBarSystemModuleText(id).map { .text($0, symbols: []) }
    }
}

/// True when this module needs a faster refresh (~1s) for live graphs / rates.
func statusBarModuleNeedsFastRefresh(_ id: String) -> Bool {
    id == "cpu" || id == "gpu" || id == "network"
}
