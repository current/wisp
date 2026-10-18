import Foundation

/// Die temperatures and fan speeds from the SMC, thermal pressure from the OS.
///
/// The key list differs between every Mac model, so it is discovered once by
/// walking the SMC's key index (a few hundred ms, done off the main thread the first
/// time temperatures are needed) and a spread-out sample of each group is kept. Fans
/// are read only; changing their speed needs a privileged helper.
final class ThermalCollector {
    private struct Sensor {
        let key: UInt32
        let info: SMC.KeyInfo
        let name: String
        let group: Group
    }

    private struct Fan {
        let index: Int
        let key: UInt32
        let info: SMC.KeyInfo
        let min: Double?
        let max: Double?
    }

    enum Group: String { case cpu, gpu, memory, battery, storage, ambient }

    private var smc: SMC?
    private var sensors: [Sensor] = []
    private var fans: [Fan] = []
    private var discovered = false

    static let prefixes: [(String, Group)] = [
        ("Tp", .cpu), ("Te", .cpu), ("Tg", .gpu), ("Tm", .memory), ("TB", .battery), ("TH", .storage), ("Ts", .ambient),
        ("TC0", .cpu), ("TG0", .gpu), ("TA0", .ambient),
    ]
    static let limits: [Group: Int] = [.cpu: 4, .gpu: 2, .memory: 2, .battery: 2, .storage: 1, .ambient: 2]

    func close() {
        smc = nil
        discovered = false
        sensors = []
        fans = []
    }

    /// Without `detail` only the CPU and GPU sensors are read: each SMC read is a
    /// round trip to a coprocessor (about 0.2 ms), and the menu bar shows one number.
    func sample(detail: Bool) -> ThermalReading {
        let pressure: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .fair: pressure = .fair
        case .serious: pressure = .serious
        case .critical: pressure = .critical
        default: pressure = .nominal
        }
        if !discovered { discover() }
        guard let smc else {
            return ThermalReading(pressure: pressure, sensors: [], fans: [])
        }

        var readings: [TemperatureSensor] = []
        readings.reserveCapacity(sensors.count)
        var cpu = (0.0, 0), gpu = (0.0, 0)
        for sensor in sensors {
            if !detail, sensor.group != .cpu, sensor.group != .gpu { continue }
            guard let value = smc.read(sensor.key, sensor.info) else { continue }
            // Power-gated domains report 0 or small negative sentinels instead of failing.
            let floor = sensor.group == .cpu || sensor.group == .gpu ? 10.0 : 1.0
            guard value >= floor, value < 130 else { continue }
            readings.append(TemperatureSensor(key: SMC.string(sensor.key), name: sensor.name, celsius: value))
            if sensor.group == .cpu { cpu.0 += value; cpu.1 += 1 }
            if sensor.group == .gpu { gpu.0 += value; gpu.1 += 1 }
        }
        let fanReadings = !detail ? [] : fans.compactMap { fan -> FanReading? in
            guard let rpm = smc.read(fan.key, fan.info), rpm >= 0, rpm < 50_000 else { return nil }
            return FanReading(index: fan.index, rpm: rpm, minRPM: fan.min, maxRPM: fan.max)
        }
        return ThermalReading(pressure: pressure,
                              cpuCelsius: cpu.1 > 0 ? cpu.0 / Double(cpu.1) : nil,
                              gpuCelsius: gpu.1 > 0 ? gpu.0 / Double(gpu.1) : nil,
                              sensors: readings, fans: fanReadings)
    }

    private func discover() {
        discovered = true
        guard let smc = SMC(), let count = smc.keyCount else { return }
        self.smc = smc

        var byGroup: [Group: [UInt32]] = [:]
        for index in 0..<min(count, 8192) {
            guard let key = smc.key(at: index) else { continue }
            let name = SMC.string(key)
            guard name.hasPrefix("T"), let group = Self.prefixes.first(where: { name.hasPrefix($0.0) })?.1 else { continue }
            byGroup[group, default: []].append(key)
        }
        for (group, keys) in byGroup {
            let chosen = Self.spread(keys.sorted(), limit: Self.limits[group] ?? 1)
            for (offset, key) in chosen.enumerated() {
                guard let info = smc.info(key), smc.read(key, info) != nil else { continue }
                let label = Self.label(group)
                sensors.append(Sensor(key: key, info: info, name: chosen.count > 1 ? "\(label) \(offset + 1)" : label, group: group))
            }
        }
        sensors.sort { ($0.group.rawValue, $0.name) < ($1.group.rawValue, $1.name) }

        let fanCountKey = SMC.code("FNum")
        if let info = smc.info(fanCountKey), let n = smc.read(fanCountKey, info) {
            for index in 0..<min(Int(n), 8) {
                let key = SMC.code("F\(index)Ac")
                guard let info = smc.info(key) else { continue }
                fans.append(Fan(index: index, key: key, info: info,
                                min: staticValue(smc, "F\(index)Mn"), max: staticValue(smc, "F\(index)Mx")))
            }
        }
    }

    private func staticValue(_ smc: SMC, _ name: String) -> Double? {
        let key = SMC.code(name)
        guard let info = smc.info(key), let value = smc.read(key, info), value > 0 else { return nil }
        return value
    }

    static func label(_ group: Group) -> String {
        switch group {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .storage: return "SSD"
        case .ambient: return "Enclosure"
        }
    }

    static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        if limit == 1 { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(limit - 1)
        return (0..<limit).map { items[Int((Double($0) * step).rounded())] }
    }
}
