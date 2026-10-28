import Foundation

/// Values the built-in system modules display, read OFF the main thread.
///
/// Every one of these is a blocking call into another subsystem — IOKit power sources (powerd),
/// CoreAudio (can stall 100ms+ while an audio device switches, e.g. Bluetooth headphones
/// connecting), getifaddrs, host_statistics64, the IOAccelerator registry, and the ntstat flow
/// queue. They used to run on the main thread for every monitor on EVERY session (each hotkey) and
/// again on the 1 Hz tick, so a hotkey landing on a tick waited behind them. Now the tick samples
/// them on a utility queue and the bar renders from the latest readings; a session-driven redraw
/// does no system calls at all.
struct StatusBarSystemReadings: Sendable {
    var battery: StatusBarBattery.Snapshot?
    var volume: StatusBarVolume.Snapshot?
    var network: StatusBarNetwork.Snapshot?
    var memory: StatusBarCpuMem.MemorySnapshot?
    var gpu: GpuLoad?
    var netTotals: NetTotals?
    var at: TimeInterval
}

struct NetTotals: Sendable, Equatable {
    var rx: UInt64
    var tx: UInt64
}

@MainActor
final class StatusBarSystemSampler {
    static let shared = StatusBarSystemSampler()
    private init() {}

    /// Latest readings (nil until the first sample completes)
    private(set) var latest: StatusBarSystemReadings? = nil
    /// Bumps on every completed sample — part of the bar's redraw fingerprint
    private(set) var version = 0
    private var inFlight = false
    private let queue = DispatchQueue(label: "bobko.aerospace.statusbar-sampler", qos: .utility)

    /// Sample the modules in `modules` in the background, then call `completion` on the main actor.
    /// A tick that arrives while the previous sample is still running is dropped (never queued up).
    func sampleAsync(modules: Set<String>, completion: @escaping @MainActor () -> Void) {
        if inFlight { return }
        inFlight = true
        queue.async {
            let readings = StatusBarSystemReadings(
                battery: modules.contains("battery") ? StatusBarBattery.liveSnapshot() : nil,
                volume: modules.contains("volume") ? StatusBarVolume.liveSnapshot() : nil,
                network: modules.contains("network") ? StatusBarNetwork.liveSnapshot() : nil,
                memory: modules.contains("memory") ? StatusBarCpuMem.liveMemorySnapshot() : nil,
                gpu: modules.contains("gpu") ? readGpuLoad() : nil,
                netTotals: modules.contains("network") ? StatusBarNetSampler.readFlowOrInterfaceTotals() : nil,
                at: ProcessInfo.processInfo.systemUptime,
            )
            Task.startUnstructured { @MainActor in
                self.inFlight = false
                self.latest = readings
                self.version &+= 1
                if modules.contains("gpu") { StatusBarGpuSampler.shared.ingest(readings.gpu) }
                if let totals = readings.netTotals { StatusBarNetSampler.shared.ingest(totals, at: readings.at) }
                // A sample that was already running when the bar (or its network module) went away
                // re-created the machine-wide flow subscription inside poll(); drop it again
                if modules.contains("network"), !(config.statusBar.enabled && statusBarUsesNetworkModule(config.statusBar)) {
                    NetworkFlowStats.shared.stop()
                }
                completion()
            }
        }
    }

    /// Background resample when the latest readings are older than `maxAge` seconds
    func resampleIfStale(modules: Set<String>, maxAge: TimeInterval, completion: @escaping @MainActor () -> Void) {
        let age = latest.map { ProcessInfo.processInfo.systemUptime - $0.at } ?? .infinity
        if age > maxAge { sampleAsync(modules: modules, completion: completion) }
    }

    func resetForTests() {
        latest = nil
        version = 0
        inFlight = false
    }
}
