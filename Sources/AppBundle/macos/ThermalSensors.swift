import Foundation

/// Temperature sensors through the HID event system (no root, no SMC keys). Apple Silicon exposes
/// them by generic names, verified on an M3 Pro (macOS 27.2):
/// - `PMU tdie1…N`: SoC die sensors (CPU and GPU clusters; Apple publishes no per-core mapping)
/// - `PMU tdev1…N`: other on-package sensors
/// - `NAND CH0 temp`: SSD, `gas gauge battery`: battery
/// Each sensor is listed twice (two PMUs report it); duplicates are averaged by name.
enum ThermalSensors {
    struct Reading: Equatable, Sendable {
        let name: String
        let celsius: Double
    }

    private typealias CreateFun = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFun = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFun = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFun = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFun = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFun = @convention(c) (AnyObject, Int32) -> Double

    private struct Impl: @unchecked Sendable {
        let client: AnyObject
        let copyServices: CopyServicesFun
        let copyProperty: CopyPropertyFun
        let copyEvent: CopyEventFun
        let floatValue: FloatValueFun
    }

    private static let impl: Impl? = {
        guard let iokit = unsafe dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = unsafe dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let setMatching = unsafe dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copyServices = unsafe dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = unsafe dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let copyEvent = unsafe dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let floatValue = unsafe dlsym(iokit, "IOHIDEventGetFloatValue"),
              let client = unsafe unsafeBitCast(create, to: CreateFun.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // Apple vendor page, temperature usage
        _ = unsafe unsafeBitCast(setMatching, to: SetMatchingFun.self)(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        return unsafe Impl(
            client: client,
            copyServices: unsafeBitCast(copyServices, to: CopyServicesFun.self),
            copyProperty: unsafeBitCast(copyProperty, to: CopyPropertyFun.self),
            copyEvent: unsafeBitCast(copyEvent, to: CopyEventFun.self),
            floatValue: unsafeBitCast(floatValue, to: FloatValueFun.self),
        )
    }()

    private static let temperatureEventType: Int64 = 15

    /// All sensors, duplicates averaged, sorted by name. Empty when unavailable. ~1 ms.
    static func read() -> [Reading] {
        guard let impl = unsafe impl,
              let services = unsafe impl.copyServices(impl.client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }
        var sums: [String: (total: Double, count: Int)] = [:]
        for service in services {
            let name = unsafe impl.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            guard let event = unsafe impl.copyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = unsafe impl.floatValue(event, Int32(temperatureEventType << 16))
            guard value.isFinite, value > -40, value < 150 else { continue }
            sums[name, default: (0, 0)].total += value
            sums[name, default: (0, 0)].count += 1
        }
        return sums.map { Reading(name: $0.key, celsius: $0.value.total / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The panel's summary of the sensors: SoC die (average and hottest), the rest of the package, SSD,
/// battery. nil fields = no such sensor.
struct ThermalSummary: Equatable, Sendable {
    var dieAverage: Double?
    var dieMax: Double?
    var packageMax: Double?
    var ssd: Double?
    var battery: Double?
    var dieSensors: [ThermalSensors.Reading] = []

    init(_ readings: [ThermalSensors.Reading]) {
        let die = readings.filter { $0.name.contains("tdie") }
        dieSensors = die
        if !die.isEmpty {
            dieAverage = die.map(\.celsius).reduce(0, +) / Double(die.count)
            dieMax = die.map(\.celsius).max()
        }
        packageMax = readings.filter { $0.name.contains("tdev") }.map(\.celsius).max()
        ssd = readings.filter { $0.name.contains("NAND") }.map(\.celsius).max()
        battery = readings.filter { $0.name.lowercased().contains("battery") }.map(\.celsius).max()
    }

    var isEmpty: Bool { dieAverage == nil && packageMax == nil && ssd == nil && battery == nil }
}
