import AppKit
import Darwin

/// One process at one sample: CPU since the previous sample, memory footprint (what Activity
/// Monitor calls "Memory"), and the app responsible for it when that is a different process
/// (Safari for its WebKit content processes).
struct ProcessUsage: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let owner: String?
    /// Percent of one core (Activity Monitor convention: 250 = two and a half cores)
    let cpuPercent: Double
    let memoryBytes: UInt64
}

/// Samples every process this user can read. Not thread-safe; use from one queue. A sample walks
/// ~600 processes in a few ms, so it only runs while the detail panel is open.
final class ProcessSampler: @unchecked Sendable {
    private var lastCpuNanos: [pid_t: UInt64] = [:]
    private var lastAt: UInt64 = 0
    private var names: [pid_t: (name: String, owner: String?)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    private typealias ResponsibleFun = @convention(c) (pid_t) -> pid_t
    private let responsible: ResponsibleFun? = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafe unsafeBitCast($0, to: ResponsibleFun.self) }

    /// All readable processes. CPU is 0 on the first call (no previous sample yet).
    func sample() -> [ProcessUsage] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let now = mach_absolute_time()
        let wallNanos = lastAt == 0 ? 0 : (now - lastAt) * timebase.numer / timebase.denom
        var out: [ProcessUsage] = []
        out.reserveCapacity(count)
        var seen = Set<pid_t>()
        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v4()
            let ok = unsafe withUnsafeMutablePointer(to: &info) { ptr in
                unsafe ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    unsafe proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { continue } // other users' processes: not readable
            seen.insert(pid)
            let cpuNanos = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            let previous = lastCpuNanos[pid]
            lastCpuNanos[pid] = cpuNanos
            let percent: Double = if let previous, wallNanos > 0, cpuNanos >= previous {
                Double(cpuNanos - previous) / Double(wallNanos) * 100
            } else { 0 }
            let label = name(of: pid)
            out.append(ProcessUsage(pid: pid, name: label.name, owner: label.owner, cpuPercent: percent, memoryBytes: info.ri_phys_footprint))
        }
        lastAt = now
        // Forget exited processes (pids are reused)
        for pid in lastCpuNanos.keys where !seen.contains(pid) {
            lastCpuNanos.removeValue(forKey: pid)
            names.removeValue(forKey: pid)
        }
        return out
    }

    /// A display name (the app's name for app bundles, else the executable's) and, for helpers,
    /// the app responsible for them
    private func name(of pid: pid_t) -> (name: String, owner: String?) {
        if let cached = names[pid] { return cached }
        let own = appName(pid) ?? executableName(pid) ?? "pid \(pid)"
        var owner: String? = nil
        if let responsible, case let r = responsible(pid), r > 0, r != pid {
            owner = appName(r) ?? executableName(r)
            if owner == own { owner = nil }
        }
        names[pid] = (own, owner)
        return (own, owner)
    }

    private func appName(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private func executableName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.split(separator: "/").last.map(String.init)
    }
}

/// Physical memory in use and swap, for the memory panel
struct MemoryTotals: Equatable, Sendable {
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64

    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    static func read() -> MemoryTotals? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = unsafe withUnsafeMutablePointer(to: &stats) { ptr in
            unsafe ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                unsafe host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        // Activity Monitor: App Memory = internal - purgeable
        let app = (UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))) * page
        return MemoryTotals(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: app,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total,
        )
    }
}

/// Performance (P) and efficiency (E) core counts. Apple Silicon numbers the E cores first
/// (verified on an M3 Pro: background-QoS load lands on CPUs 0–5 of 6 E + 5 P). Intel: all P.
struct CpuTopology: Equatable, Sendable {
    let performance: Int
    let efficiency: Int

    static let current: CpuTopology = {
        func int(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        let total = ProcessInfo.processInfo.processorCount
        guard let p = int("hw.perflevel0.logicalcpu"), let e = int("hw.perflevel1.logicalcpu"), p + e == total else {
            return CpuTopology(performance: total, efficiency: 0)
        }
        return CpuTopology(performance: p, efficiency: e)
    }()

    /// "E" or "P" for logical CPU `index`
    func kind(ofCore index: Int) -> String { index < efficiency ? "E" : "P" }
}
