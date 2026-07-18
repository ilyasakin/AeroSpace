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

// MARK: - History graph geometry (pure, testable)

/// Layout for a multi-core *time-history* chart: X = time, each row = one core.
struct HistoryGraphLayout: Equatable {
    var sampleCount: Int
    var coreCount: Int
    var columnWidth: CGFloat
    var rowGap: CGFloat
    var paddingX: CGFloat
    var paddingY: CGFloat
    var labelWidth: CGFloat

    var totalWidth: CGFloat {
        let cols = max(1, sampleCount)
        return paddingX * 2 + labelWidth + CGFloat(cols) * columnWidth
    }

    /// Rectangle for one sample column on one core row (AppKit coords, origin bottom-left).
    /// `load` fills from the bottom of the row upward.
    func cellFrame(
        sampleIndex: Int,
        coreIndex: Int,
        load: Double,
        viewHeight: CGFloat,
    ) -> CGRect {
        let cores = max(1, coreCount)
        let usableH = max(1, viewHeight - paddingY * 2)
        let rowH = (usableH - CGFloat(cores - 1) * rowGap) / CGFloat(cores)
        // Core 0 at top of the chart (Activity Monitor style)
        let rowFromTop = CGFloat(coreIndex)
        let rowBottom = paddingY + (CGFloat(cores - 1) - rowFromTop) * (rowH + rowGap)
        let x = paddingX + labelWidth + CGFloat(sampleIndex) * columnWidth
        let h = max(0.5, rowH * CGFloat(min(1, max(0, load))))
        return CGRect(x: x, y: rowBottom, width: max(1, columnWidth - 0.5), height: h)
    }

    /// Full row track background.
    func rowTrackFrame(coreIndex: Int, viewHeight: CGFloat) -> CGRect {
        let cores = max(1, coreCount)
        let usableH = max(1, viewHeight - paddingY * 2)
        let rowH = (usableH - CGFloat(cores - 1) * rowGap) / CGFloat(cores)
        let rowFromTop = CGFloat(coreIndex)
        let rowBottom = paddingY + (CGFloat(cores - 1) - rowFromTop) * (rowH + rowGap)
        let x = paddingX + labelWidth
        let w = CGFloat(max(1, sampleCount)) * columnWidth
        return CGRect(x: x, y: rowBottom, width: w, height: rowH)
    }
}

func defaultHistoryGraphLayout(
    sampleCount: Int,
    coreCount: Int,
    columnWidth: CGFloat = 2.5,
    labelWidth: CGFloat = 0,
) -> HistoryGraphLayout {
    HistoryGraphLayout(
        sampleCount: max(1, sampleCount),
        coreCount: max(1, coreCount),
        columnWidth: columnWidth,
        rowGap: coreCount > 12 ? 0.5 : 1,
        paddingX: 3,
        paddingY: 2,
        labelWidth: labelWidth,
    )
}
