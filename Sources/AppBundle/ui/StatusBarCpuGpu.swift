import Darwin
import Foundation
import IOKit

// MARK: - Per-core CPU sampling

/// Busy fraction 0...1 for each logical CPU, derived from two `host_processor_info` snapshots.
struct CpuCoreLoads: Equatable, Sendable {
    /// One entry per logical core (P-cores + E-cores all appear as separate CPUs on Apple Silicon).
    var cores: [Double]
}

/// Pure delta between two CPU tick samples → busy fractions. Unit-testable without Mach APIs.
func cpuCoreLoads(
    previous: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)],
    current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)],
) -> [Double] {
    let n = min(previous.count, current.count)
    guard n > 0 else { return [] }
    var out = [Double]()
    out.reserveCapacity(n)
    for i in 0 ..< n {
        let p = previous[i]
        let c = current[i]
        let dUser = UInt64(c.user &- p.user)
        let dSystem = UInt64(c.system &- p.system)
        let dNice = UInt64(c.nice &- p.nice)
        let dIdle = UInt64(c.idle &- p.idle)
        let busy = dUser + dSystem + dNice
        let total = busy + dIdle
        if total == 0 {
            out.append(0)
        } else {
            out.append(min(1, Double(busy) / Double(total)))
        }
    }
    return out
}

/// Process-wide sampler: keeps the previous tick snapshot so each `sample()` returns a real rate.
@MainActor
final class StatusBarCpuSampler {
    static let shared = StatusBarCpuSampler()

    private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private(set) var lastLoads: [Double] = []

    private init() {}

    /// Take a sample. First call seeds ticks and returns zeros (or last known); subsequent calls
    /// return per-core busy fractions since the previous sample.
    @discardableResult
    func sample() -> CpuCoreLoads {
        guard let ticks = readCpuTicks() else {
            return CpuCoreLoads(cores: lastLoads)
        }
        if previousTicks.count == ticks.count, !previousTicks.isEmpty {
            lastLoads = cpuCoreLoads(previous: previousTicks, current: ticks)
        } else if lastLoads.count != ticks.count {
            lastLoads = Array(repeating: 0, count: ticks.count)
        }
        previousTicks = ticks
        return CpuCoreLoads(cores: lastLoads)
    }
}

private func readCpuTicks() -> [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]? {
    var cpuCount: natural_t = 0
    var infoArray: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let kr = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &cpuCount,
        &infoArray,
        &infoCount,
    )
    guard kr == KERN_SUCCESS, let infoArray, cpuCount > 0 else { return nil }
    defer {
        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), size)
    }

    // Each processor contributes CPU_STATE_MAX integers (user, system, idle, nice).
    let stride = Int(CPU_STATE_MAX)
    let totalInts = Int(infoCount)
    let cores = min(Int(cpuCount), totalInts / stride)
    var result: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    result.reserveCapacity(cores)
    for i in 0 ..< cores {
        let base = i * stride
        // CPU_STATE_USER=0, SYSTEM=1, IDLE=2, NICE=3
        let user = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])
        let system = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])
        let idle = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])
        let nice = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
        result.append((user, system, idle, nice))
    }
    return result
}

// MARK: - GPU sampling (best-effort via IOAccelerator)

struct GpuLoad: Equatable, Sendable {
    /// 0...1 device utilization when known.
    var utilization: Double?
    var name: String?
}

@MainActor
final class StatusBarGpuSampler {
    static let shared = StatusBarGpuSampler()
    private(set) var last: GpuLoad = GpuLoad(utilization: nil, name: nil)
    private init() {}

    @discardableResult
    func sample() -> GpuLoad {
        last = readGpuLoad() ?? last
        return last
    }
}

/// Walks IOAccelerator services for "Device Utilization %" / "Renderer Utilization %".
/// Not guaranteed on every Mac / OS version — returns nil when unavailable.
func readGpuLoad() -> GpuLoad? {
    let matching = IOServiceMatching("IOAccelerator")
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    var best: GpuLoad?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { continue }

        let name = dict["model"] as? String
            ?? dict["CFBundleIdentifier"] as? String
            ?? dict["IOClass"] as? String

        // PerformanceStatistics is the usual home for utilization percentages.
        let stats = dict["PerformanceStatistics"] as? [String: Any] ?? dict
        var util: Double?
        for key in ["Device Utilization %", "Renderer Utilization %", "GPU Activity(%)", "Hardware utilization %"] {
            if let n = stats[key] as? NSNumber {
                let v = n.doubleValue
                // Values are typically 0...100
                util = v > 1.0 ? min(1, v / 100.0) : min(1, max(0, v))
                break
            }
            if let i = stats[key] as? Int {
                util = min(1, Double(i) / 100.0)
                break
            }
        }
        if let util {
            // Prefer the highest utilization among accelerators (discrete + integrated).
            if best?.utilization ?? -1 < util {
                best = GpuLoad(utilization: util, name: name)
            }
        } else if best == nil, name != nil {
            best = GpuLoad(utilization: nil, name: name)
        }
    }
    return best
}

// MARK: - Graph geometry (pure, testable)

/// Layout for a multi-core sparkline inside a status-bar chip.
struct CoreGraphLayout: Equatable {
    var barWidth: CGFloat
    var gap: CGFloat
    var paddingX: CGFloat
    var paddingY: CGFloat
    var coreCount: Int

    var totalWidth: CGFloat {
        guard coreCount > 0 else { return paddingX * 2 }
        return paddingX * 2 + CGFloat(coreCount) * barWidth + CGFloat(max(0, coreCount - 1)) * gap
    }

    /// Bar rect in local view coordinates (origin bottom-left, AppKit).
    func barFrame(index: Int, load: Double, height: CGFloat) -> CGRect {
        let x = paddingX + CGFloat(index) * (barWidth + gap)
        let usable = max(1, height - paddingY * 2)
        let h = max(1, usable * CGFloat(min(1, max(0, load))))
        let y = paddingY
        return CGRect(x: x, y: y, width: barWidth, height: h)
    }
}

func defaultCoreGraphLayout(coreCount: Int, barHeight: CGFloat) -> CoreGraphLayout {
    // Keep readable on dense chips: thin bars, 1pt gaps, scale width with core count but cap.
    let barW: CGFloat = coreCount > 16 ? 2 : (coreCount > 8 ? 3 : 4)
    let gap: CGFloat = 1
    return CoreGraphLayout(
        barWidth: barW,
        gap: gap,
        paddingX: 4,
        paddingY: 3,
        coreCount: coreCount,
    )
}
