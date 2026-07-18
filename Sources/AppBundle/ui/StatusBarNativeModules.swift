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
            case .cpu: "CPU (per-core history)"
            case .gpu: "GPU (history)"
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

// MARK: - Pure module text builders (unit-testable)

enum StatusBarClock {
    /// `HH:mm` local time.
    static func text(date: Date = Date(), calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", h, m)
    }
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
        case "clock": return StatusBarClock.text()
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

/// True when this module needs a faster refresh (~1s) for live graphs.
func statusBarModuleNeedsFastRefresh(_ id: String) -> Bool {
    id == "cpu" || id == "gpu"
}
