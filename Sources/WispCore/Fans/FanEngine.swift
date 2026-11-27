import Foundation

/// One fan as the hardware reports it.
public struct FanState: Codable, Sendable, Equatable {
    public var index: Int
    public var rpm: Double?
    public var minRPM: Double
    public var maxRPM: Double
    /// What Wisp last asked for; nil while macOS controls the fan.
    public var targetRPM: Double?

    public init(index: Int, rpm: Double?, minRPM: Double, maxRPM: Double, targetRPM: Double? = nil) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }
}

/// What the helper reports: the answer to every request it takes.
public struct FanStatus: Codable, Sendable, Equatable {
    public var version: Int
    public var mode: FanMode
    /// The speed in force after smoothing, percent of range; nil while macOS controls the fans.
    public var percent: Double?
    /// Too hot for the chosen mode: the fans run at full speed until the chip cools.
    public var overheated: Bool
    public var temperatures: FanTemperatures
    public var fans: [FanState]
    /// The last write the SMC refused, if any.
    public var error: String?
}

/// Reads and drives the fans. The SMC one needs root to write.
public protocol FanHardware: AnyObject {
    var fans: [FanState] { get }
    var thermalPressure: ThermalPressure { get }
    func temperatures() -> FanTemperatures
    func rpm(_ index: Int) -> Double?
    func setManual(_ index: Int, rpm: Double) -> Bool
    func setAutomatic(_ index: Int) -> Bool
}

public extension FanHardware {
    var thermalPressure: ThermalPressure { .nominal }
}

/// The loop the helper runs every two seconds: read the temperature, work out the speed the
/// mode asks for, ease towards it, and write it. Not thread safe; the helper calls it from one queue.
public final class FanEngine {
    public static let interval: TimeInterval = 2
    /// Any CPU or GPU sensor this hot runs the fans at full speed, whatever the mode says.
    public static let overheatCelsius = 95.0
    /// ...until every sensor is back under this.
    public static let cooledCelsius = 85.0
    /// Consecutive manual write failures before handing the fans back to macOS so `Ftst` is never left half-set.
    public static let maxWriteFailures = 3
    /// Percent per tick. Up fast so heat never builds, down slowly so the sound does not pump.
    static let rampUp = 25.0
    static let rampDown = 4.0

    private let hardware: FanHardware
    public private(set) var mode: FanMode = .auto
    private var percent: Double?
    private var overheated = false
    private var managed = false
    private var consecutiveWriteFailures = 0
    private var lastError: String?

    public var isManaging: Bool { managed }

    public init(hardware: FanHardware) {
        self.hardware = hardware
    }

    public func set(_ mode: FanMode) {
        self.mode = mode
        consecutiveWriteFailures = 0
    }

    /// One step of the loop. Returns what is in force afterwards.
    @discardableResult
    public func tick() -> FanStatus {
        let temperatures = hardware.temperatures()
        let pressure = hardware.thermalPressure
        let pressureHot = pressure == .serious || pressure == .critical
        if pressureHot || (temperatures.hottest.map { $0 >= Self.overheatCelsius } ?? false) {
            overheated = true
        } else if !pressureHot, let hottest = temperatures.hottest, hottest < Self.cooledCelsius {
            overheated = false
        }
        var wanted = mode.percent(temperatures)
        // Missing temperature sensors while holding a manual speed fails safe to full speed.
        if mode.kind != .auto, temperatures.hottest == nil { wanted = 100 }
        let emergency = overheated && mode.kind != .auto
        if emergency { wanted = 100 }
        percent = emergency ? 100 : Self.ease(from: percent, to: wanted)
        lastError = nil
        if let percent, percent > 0 || mode.kind == .fixed {
            managed = true
            var failed = false
            for fan in hardware.fans {
                let rpm = fan.minRPM + (fan.maxRPM - fan.minRPM) * percent / 100
                if !hardware.setManual(fan.index, rpm: rpm) {
                    failed = true
                    lastError = "The SMC did not take fan \(fan.index)'s speed"
                }
            }
            if failed {
                consecutiveWriteFailures += 1
                if consecutiveWriteFailures >= Self.maxWriteFailures {
                    let error = lastError
                    restore()
                    lastError = error
                }
            } else {
                consecutiveWriteFailures = 0
            }
        } else if managed {
            consecutiveWriteFailures = 0
            restore()
        }
        return status(temperatures)
    }

    /// Hands every fan back to macOS.
    public func restore() {
        managed = false
        percent = nil
        for fan in hardware.fans where !hardware.setAutomatic(fan.index) {
            lastError = "The SMC did not give fan \(fan.index) back to macOS"
        }
    }

    public func status(_ temperatures: FanTemperatures? = nil) -> FanStatus {
        let fans = hardware.fans.map { fan -> FanState in
            var fan = fan
            fan.rpm = hardware.rpm(fan.index)
            if managed, let percent { fan.targetRPM = fan.minRPM + (fan.maxRPM - fan.minRPM) * percent / 100 }
            return fan
        }
        return FanStatus(version: FanHelper.protocolVersion, mode: mode, percent: managed ? percent : nil,
                         overheated: overheated && mode.kind != .auto, temperatures: temperatures ?? hardware.temperatures(),
                         fans: fans, error: lastError)
    }

    /// The next speed on the way from `current` to `target`. Nil target: macOS has the fans.
    static func ease(from current: Double?, to target: Double?) -> Double? {
        guard let target else { return nil }
        guard let current else { return target }
        if target > current { return min(target, current + rampUp) }
        return max(target, current - rampDown)
    }
}

/// The real fans, through the SMC. Apple silicon takes a manual speed only after the
/// `Ftst` key is set, and macOS may take a fan back at any time (including after sleep),
/// so every tick writes the mode and target again and re-unlocks if the SMC rejects a write.
public final class SMCFanHardware: FanHardware {
    private var smc: SMC
    private let thermal: ThermalCollector
    public let fans: [FanState]
    private var unlocked = false

    public init?(allSensors: Bool = true) {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        self.thermal = ThermalCollector(allComputeSensors: allSensors)
        var fans: [FanState] = []
        if let info = smc.info(SMC.code("FNum")), let count = smc.read(SMC.code("FNum"), info) {
            for index in 0..<min(Int(count), 8) {
                guard let low = Self.value(smc, "F\(index)Mn"), let high = Self.value(smc, "F\(index)Mx"), high > low else { continue }
                fans.append(FanState(index: index, rpm: nil, minRPM: low, maxRPM: high))
            }
        }
        self.fans = fans
    }

    private static func value(_ smc: SMC, _ name: String) -> Double? {
        let key = SMC.code(name)
        guard let info = smc.info(key) else { return nil }
        return smc.read(key, info)
    }

    private func write(_ name: String, _ value: Double) -> Bool {
        let key = SMC.code(name)
        guard let info = smc.info(key) else { return false }
        return smc.write(key, info, value)
    }

    private func reopenSMC() -> Bool {
        guard let fresh = SMC() else { return false }
        smc = fresh
        unlocked = false
        return true
    }

    /// Clears cached unlock state after sleep/wake so the next manual tick re-verifies `Ftst`.
    public func invalidateUnlock() {
        unlocked = false
    }

    public var thermalPressure: ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        default: return .nominal
        }
    }

    public func temperatures() -> FanTemperatures {
        let reading = thermal.sample(detail: true)
        let cpu = reading.sensors.filter { $0.name.hasPrefix("CPU") }.map(\.celsius).max()
        let gpu = reading.sensors.filter { $0.name.hasPrefix("GPU") }.map(\.celsius).max()
        return FanTemperatures(cpu: cpu, gpu: gpu, hottest: [cpu, gpu].compactMap { $0 }.max())
    }

    public func rpm(_ index: Int) -> Double? { Self.value(smc, "F\(index)Ac") }

    public func setManual(_ index: Int, rpm: Double) -> Bool {
        // Macs without an Ftst key (Intel) refuse the write; their mode key works on its own.
        if !unlocked { unlocked = write("Ftst", 1) }
        var modeSet = write("F\(index)Md", 1)
        if !modeSet {
            // thermalmonitord may have cleared Ftst (e.g. after sleep) or the IOKit handle may be stale.
            unlocked = write("Ftst", 1)
            modeSet = write("F\(index)Md", 1)
            if !modeSet, reopenSMC() {
                unlocked = write("Ftst", 1)
                modeSet = write("F\(index)Md", 1)
            }
        }
        var targetSet = write("F\(index)Tg", rpm)
        if !targetSet, modeSet, reopenSMC() {
            unlocked = write("Ftst", 1)
            modeSet = write("F\(index)Md", 1)
            targetSet = write("F\(index)Tg", rpm)
        }
        return targetSet && modeSet
    }

    public func setAutomatic(_ index: Int) -> Bool {
        var done = write("F\(index)Md", 0)
        if !done, reopenSMC() {
            done = write("F\(index)Md", 0)
        }
        // Never gate Ftst=0 on in-memory `unlocked`: a freshly started helper after a crash
        // or kill must still clear a leftover Ftst=1 left in hardware.
        if index == fans.last?.index {
            let ftst = SMC.code("Ftst")
            if let info = smc.info(ftst) {
                let current = smc.read(ftst, info)
                if unlocked || current == nil || current != 0 {
                    unlocked = !smc.write(ftst, info, 0)
                }
            } else {
                unlocked = false
            }
        }
        return done
    }

    /// Last-resort restore using a brand-new SMC handle, callable from a watchdog thread
    /// if the helper's main queue ever stalls.
    public static func emergencyRestore() {
        guard let smc = SMC() else { return }
        if let info = smc.info(SMC.code("FNum")), let count = smc.read(SMC.code("FNum"), info) {
            for index in 0..<min(Int(count), 8) {
                let key = SMC.code("F\(index)Md")
                if let modeInfo = smc.info(key) { _ = smc.write(key, modeInfo, 0) }
            }
        }
        let ftst = SMC.code("Ftst")
        if let ftstInfo = smc.info(ftst) { _ = smc.write(ftst, ftstInfo, 0) }
    }
}
