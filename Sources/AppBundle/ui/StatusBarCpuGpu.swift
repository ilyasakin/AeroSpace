import Darwin
import Foundation
import IOKit

// MARK: - Per-core CPU sampling + short history

/// Busy fraction 0...1 for each logical CPU at one sample instant.
struct CpuCoreLoads: Equatable, Sendable {
    var cores: [Double]
}

/// Ring buffer of per-core samples. `samples[t][core]` is load at time t (oldest first).
struct CpuHistory: Equatable, Sendable {
    /// Oldest → newest; each entry is one sample of all cores.
    var samples: [[Double]]
    var coreCount: Int { samples.last?.count ?? 0 }
    var length: Int { samples.count }
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

/// Append `sample` to `history`, dropping the oldest when over capacity. Pure helper for tests.
func appendHistorySample(_ history: [[Double]], sample: [Double], capacity: Int) -> [[Double]] {
    guard capacity > 0 else { return [] }
    var next = history
    // Core count changed — restart history so columns stay aligned.
    if let last = next.last, last.count != sample.count {
        next = []
    }
    next.append(sample)
    if next.count > capacity {
        next.removeFirst(next.count - capacity)
    }
    return next
}

/// Process-wide sampler: previous Mach ticks + ring buffer of recent per-core loads.
@MainActor
final class StatusBarCpuSampler {
    static let shared = StatusBarCpuSampler()
    /// ~30s of history at 1 Hz.
    static let historyCapacity = 30
    /// Don't sample faster than this even if refresh() is called spammed (e.g. old FFM path).
    static let minSampleInterval: TimeInterval = 0.9

    private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private(set) var lastLoads: [Double] = []
    /// Oldest → newest samples.
    private(set) var history: [[Double]] = []
    private var lastSampleAt: TimeInterval = 0

    private init() {}

    /// Latest history without taking a new Mach sample (for redraws that must not burn CPU).
    var currentHistory: CpuHistory { CpuHistory(samples: history) }

    @discardableResult
    func sample(force: Bool = false) -> CpuHistory {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, lastSampleAt > 0, now - lastSampleAt < Self.minSampleInterval {
            return CpuHistory(samples: history)
        }
        lastSampleAt = now
        guard let ticks = readCpuTicks() else {
            return CpuHistory(samples: history)
        }
        if previousTicks.count == ticks.count, !previousTicks.isEmpty {
            lastLoads = cpuCoreLoads(previous: previousTicks, current: ticks)
            history = appendHistorySample(history, sample: lastLoads, capacity: Self.historyCapacity)
        } else if lastLoads.count != ticks.count {
            lastLoads = Array(repeating: 0, count: ticks.count)
            history = []
        }
        previousTicks = ticks
        return CpuHistory(samples: history)
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

    let stride = Int(CPU_STATE_MAX)
    let totalInts = Int(infoCount)
    let cores = min(Int(cpuCount), totalInts / stride)
    var result: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    result.reserveCapacity(cores)
    for i in 0 ..< cores {
        let base = i * stride
        let user = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])
        let system = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])
        let idle = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])
        let nice = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
        result.append((user, system, idle, nice))
    }
    return result
}

// MARK: - GPU sampling + history

struct GpuLoad: Equatable, Sendable {
    var utilization: Double?
    var name: String?
}

struct GpuHistory: Equatable, Sendable {
    /// Oldest → newest utilization samples (0...1). Missing samples stored as 0 when dimmed.
    var samples: [Double]
    var lastKnown: Double?
}

@MainActor
final class StatusBarGpuSampler {
    static let shared = StatusBarGpuSampler()
    static let historyCapacity = 30
    static let minSampleInterval: TimeInterval = 0.9

    private(set) var last: GpuLoad = GpuLoad(utilization: nil, name: nil)
    private(set) var history: [Double] = []
    private var lastSampleAt: TimeInterval = 0
    private init() {}

    var currentHistory: GpuHistory { GpuHistory(samples: history, lastKnown: last.utilization) }

    @discardableResult
    func sample(force: Bool = false) -> GpuHistory {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, lastSampleAt > 0, now - lastSampleAt < Self.minSampleInterval {
            return GpuHistory(samples: history, lastKnown: last.utilization)
        }
        lastSampleAt = now
        last = readGpuLoad() ?? last
        if let u = last.utilization {
            history.append(u)
            if history.count > Self.historyCapacity {
                history.removeFirst(history.count - Self.historyCapacity)
            }
        }
        // When unavailable, don't push fake zeros that look like idle — keep prior history.
        return GpuHistory(samples: history, lastKnown: last.utilization)
    }
}

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

        let stats = dict["PerformanceStatistics"] as? [String: Any] ?? dict
        var util: Double?
        for key in ["Device Utilization %", "Renderer Utilization %", "GPU Activity(%)", "Hardware utilization %"] {
            if let n = stats[key] as? NSNumber {
                let v = n.doubleValue
                util = v > 1.0 ? min(1, v / 100.0) : min(1, max(0, v))
                break
            }
            if let i = stats[key] as? Int {
                util = min(1, Double(i) / 100.0)
                break
            }
        }
        if let util {
            if best?.utilization ?? -1 < util {
                best = GpuLoad(utilization: util, name: name)
            }
        } else if best == nil, name != nil {
            best = GpuLoad(utilization: nil, name: name)
        }
    }
    return best
}

// MARK: - Sparkline geometry (pure, testable)

/// Mean load across cores for one sample instant (0...1).
func cpuSampleAverage(_ cores: [Double]) -> Double {
    guard !cores.isEmpty else { return 0 }
    return cores.reduce(0, +) / Double(cores.count)
}

/// Peak core load for one sample instant (0...1).
func cpuSamplePeak(_ cores: [Double]) -> Double {
    cores.max() ?? 0
}

/// Single-series sparkline: X = time (oldest → newest), bar height = utilization.
/// Designed for a ~28pt status strip — not a per-core heatmap.
struct SparklineLayout: Equatable {
    var sampleCount: Int
    var columnWidth: CGFloat
    var paddingX: CGFloat
    var paddingY: CGFloat
    /// Trailing text (e.g. "42%") after the chart.
    var trailingWidth: CGFloat

    var chartWidth: CGFloat {
        CGFloat(max(1, sampleCount)) * columnWidth
    }

    var totalWidth: CGFloat {
        paddingX * 2 + chartWidth + (trailingWidth > 0 ? 4 + trailingWidth : 0)
    }

    func trackFrame(viewHeight: CGFloat) -> CGRect {
        let h = max(1, viewHeight - paddingY * 2)
        return CGRect(x: paddingX, y: paddingY, width: chartWidth, height: h)
    }

    /// Vertical bar for one sample, growing upward from the track bottom.
    func barFrame(sampleIndex: Int, load: Double, viewHeight: CGFloat) -> CGRect {
        let track = trackFrame(viewHeight: viewHeight)
        let clamped = min(1, max(0, load))
        let gap: CGFloat = 0.6
        let barW = max(1, columnWidth - gap)
        let x = track.minX + CGFloat(sampleIndex) * columnWidth + (columnWidth - barW) / 2
        let h: CGFloat = {
            if clamped <= 0 { return 0 }
            return max(1.5, track.height * CGFloat(clamped))
        }()
        return CGRect(x: x, y: track.minY, width: barW, height: h)
    }

    func trailingLabelFrame(viewHeight: CGFloat) -> CGRect {
        guard trailingWidth > 0 else { return .zero }
        let x = paddingX + chartWidth + 4
        return CGRect(x: x, y: 0, width: trailingWidth, height: viewHeight)
    }
}

func defaultSparklineLayout(
    sampleCount: Int,
    columnWidth: CGFloat = 3,
    trailingWidth: CGFloat = 0,
) -> SparklineLayout {
    SparklineLayout(
        sampleCount: max(1, sampleCount),
        columnWidth: columnWidth,
        paddingX: 3,
        paddingY: 3,
        trailingWidth: trailingWidth,
    )
}

/// Fixed width for "100%" / "  0%" monospaced-ish trailing label in the sparkline.
func sparklinePercentTrailingWidth(fontSize: CGFloat = 11) -> CGFloat {
    // Digits + % ; slightly generous so 100% doesn't clip.
    max(28, fontSize * 2.6)
}
