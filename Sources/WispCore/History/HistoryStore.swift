import Foundation

public enum SystemMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, diskRead, diskWrite, networkIn, networkOut, gpu, cpuTemperature, power, battery, cpuSystem
}

public enum AppMetric: String, CaseIterable, Codable, Sendable {
    /// Average cores in use over the minute.
    case cpu
    /// Largest footprint seen in the minute, bytes.
    case memory
    /// Average watts.
    case energy
    /// Bytes read plus written per second, averaged.
    case disk
    /// Bytes in plus out per second, averaged.
    case network
}

/// Recent history in memory: the last day at one-minute resolution for the machine
/// and for every app seen, plus a short ring of raw samples for sparklines. Finished
/// hours are handed to the on-disk archive.
public final class HistoryStore: @unchecked Sendable {
    public static let minutes = 1440
    public static let recentSamples = 120
    public static let recentCoreSamples = 32

    fileprivate struct Accumulator {
        var sum: Double = 0
        var time: Double = 0
        var peak: Double = 0
    }

    fileprivate final class AppHistory {
        var name: String
        var kind: AppKind
        var bundlePath: String?
        var lastSeenMinute = 0
        var rings: [MinuteRing]
        var pending: [Accumulator]
        var pendingMinute = 0

        init(name: String, kind: AppKind, bundlePath: String?) {
            self.name = name
            self.kind = kind
            self.bundlePath = bundlePath
            rings = AppMetric.allCases.map { _ in MinuteRing(capacity: HistoryStore.minutes) }
            pending = AppMetric.allCases.map { _ in Accumulator() }
        }
    }

    private let lock = NSLock()
    private var systemRings: [SystemMetric: MinuteRing] = [:]
    private var systemPending: [SystemMetric: Accumulator] = [:]
    private var systemPendingMinute = 0
    private var recent: [SystemMetric: RecentRing] = [:]
    private var recentCores: [RecentRing] = []
    private var apps: [String: AppHistory] = [:]
    private var lastHourFlushed = 0
    /// The first minute this run recorded; the minute rings know nothing before it.
    private var firstMinute: Int?
    public var archive: HourlyArchive?

    public init(archive: HourlyArchive? = nil) {
        self.archive = archive
    }

    static func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }

    // MARK: Recording

    public func record(system snapshot: SystemSnapshot, interval: Double) {
        var values: [(SystemMetric, Double)] = []
        if let cpu = snapshot.cpu {
            values.append((.cpu, cpu.total))
            values.append((.cpuSystem, cpu.system))
        }
        if let memory = snapshot.memory { values.append((.memory, Double(memory.used))) }
        if let disk = snapshot.disk {
            values.append((.diskRead, disk.readBytesPerSecond))
            values.append((.diskWrite, disk.writeBytesPerSecond))
        }
        if let net = snapshot.network {
            values.append((.networkIn, net.receivedBytesPerSecond))
            values.append((.networkOut, net.sentBytesPerSecond))
        }
        if let gpu = snapshot.gpu?.utilization { values.append((.gpu, gpu)) }
        if let temp = snapshot.thermal?.cpuCelsius { values.append((.cpuTemperature, temp)) }
        if let power = snapshot.power?.cpu.map({ $0 + (snapshot.power?.gpu ?? 0) + (snapshot.power?.ane ?? 0) }) {
            values.append((.power, power))
        }
        if let battery = snapshot.battery { values.append((.battery, battery.percent)) }

        let minute = Self.minute(snapshot.date)
        lock.withLock {
            if firstMinute == nil { firstMinute = minute }
            if minute != systemPendingMinute { flushSystem(newMinute: minute) }
            for (metric, value) in values {
                var acc = systemPending[metric] ?? Accumulator()
                acc.sum += value * max(interval, 0.001)
                acc.time += max(interval, 0.001)
                acc.peak = max(acc.peak, value)
                systemPending[metric] = acc
                var ring = recent[metric] ?? RecentRing(capacity: Self.recentSamples)
                ring.append(Float(value))
                recent[metric] = ring
            }
            if let cores = snapshot.cpu?.cores, !cores.isEmpty {
                if recentCores.count != cores.count {
                    recentCores = cores.map { _ in RecentRing(capacity: Self.recentCoreSamples) }
                }
                for (index, value) in cores.enumerated() { recentCores[index].append(Float(value)) }
            }
        }
    }

    private func flushSystem(newMinute: Int) {
        if systemPendingMinute != 0 {
            for (metric, acc) in systemPending where acc.time > 0 {
                var ring = systemRings[metric] ?? MinuteRing(capacity: Self.minutes)
                ring.set(Float(acc.sum / acc.time), minute: systemPendingMinute)
                systemRings[metric] = ring
            }
        }
        systemPending.removeAll(keepingCapacity: true)
        systemPendingMinute = newMinute
    }

    public func record(table: ProcessTable) {
        guard table.interval > 0 else { return }
        let minute = Self.minute(table.date)
        let dt = table.interval
        lock.withLock {
            for app in table.apps {
                let history: AppHistory
                if let existing = apps[app.id] {
                    history = existing
                } else {
                    history = AppHistory(name: app.name, kind: app.kind, bundlePath: app.bundlePath)
                    apps[app.id] = history
                }
                if history.pendingMinute != minute {
                    flush(history)
                    history.pendingMinute = minute
                }
                history.lastSeenMinute = minute
                let rates: [Double] = [app.cpu, Double(app.memory), app.watts, app.diskPerSecond, app.networkPerSecond]
                for index in rates.indices {
                    history.pending[index].sum += rates[index] * dt
                    history.pending[index].time += dt
                    history.pending[index].peak = max(history.pending[index].peak, rates[index])
                }
            }
            // Flush apps that stopped reporting so their last minute is not lost.
            for history in apps.values where history.pendingMinute != 0 && history.pendingMinute < minute {
                flush(history)
            }
            let hour = minute / 60
            if lastHourFlushed == 0 { lastHourFlushed = hour }
            if hour > lastHourFlushed {
                archiveHours(through: hour - 1)
                lastHourFlushed = hour
                apps = apps.filter { minute - $0.value.lastSeenMinute < Self.minutes }
            }
        }
    }

    private func flush(_ history: AppHistory) {
        guard history.pendingMinute != 0 else { return }
        for (index, metric) in AppMetric.allCases.enumerated() {
            let acc = history.pending[index]
            guard acc.time > 0 else { continue }
            let value = metric == .memory ? acc.peak : acc.sum / acc.time
            history.rings[index].set(Float(value), minute: history.pendingMinute)
            history.pending[index] = Accumulator()
        }
        history.pendingMinute = 0
    }

    private func archiveHours(through hour: Int) {
        guard let archive else { return }
        let start = max(lastHourFlushed, hour - 23)
        guard start <= hour else { return }
        for h in start...hour {
            var rows: [HourlyArchive.Row] = []
            for (id, history) in apps {
                let minutes = (0..<60).map { h * 60 + $0 }
                func values(_ metric: AppMetric) -> [Float] {
                    minutes.map { history.rings[AppMetric.allCases.firstIndex(of: metric)!].value(at: $0) }.filter { !$0.isNaN }
                }
                let cpu = values(.cpu)
                guard !cpu.isEmpty else { continue }
                let mem = values(.memory)
                let energy = values(.energy)
                let disk = values(.disk)
                let net = values(.network)
                rows.append(HourlyArchive.Row(hour: h, app: id, name: history.name,
                                              cpu: Double(cpu.reduce(0, +)) / Double(cpu.count),
                                              memoryPeak: Double(mem.max() ?? 0),
                                              energyWh: Double(energy.reduce(0, +)) / 60,
                                              diskBytes: Double(disk.reduce(0, +)) * 60,
                                              networkBytes: Double(net.reduce(0, +)) * 60,
                                              minutes: cpu.count))
            }
            var system: [SystemMetric: Double] = [:]
            for (metric, ring) in systemRings {
                let values = (0..<60).map { ring.value(at: h * 60 + $0) }.filter { !$0.isNaN }
                if !values.isEmpty { system[metric] = Double(values.reduce(0, +)) / Double(values.count) }
            }
            archive.write(hour: h, apps: rows, system: system)
        }
    }

    /// Writes the hour in progress so a quit does not lose it.
    public func flushToArchive() {
        lock.withLock {
            let minute = Self.minute(Date())
            for history in apps.values { flush(history) }
            flushSystem(newMinute: minute)
            archiveHours(through: minute / 60)
        }
    }

    // MARK: Reading

    public func recent(_ metric: SystemMetric) -> [Float] {
        lock.withLock { recent[metric]?.values ?? [] }
    }

    /// The total of a per-second metric (bytes, joules) from `start` until now:
    /// memory for the last day, the hourly archive before that.
    public func total(_ metric: SystemMetric, since start: Date, now: Date = Date()) -> Double {
        let nowMinute = Self.minute(now)
        let startMinute = Self.minute(start)
        // Memory covers the last day, but only since this run began; the archive covers the rest.
        let began = lock.withLock { firstMinute } ?? nowMinute
        let memoryFrom = min(nowMinute, max(startMinute, nowMinute - Self.minutes + 1, began))
        var sum = 0.0
        if let archive, startMinute < memoryFrom {
            for (hour, value) in archive.system(metric, since: startMinute / 60) {
                // Hours are averages; take the part of each hour inside the range.
                let from = max(hour * 60, startMinute), to = min(hour * 60 + 60, memoryFrom)
                if to > from { sum += value * 60 * Double(to - from) }
            }
        }
        let recent = day(metric, minutes: nowMinute - memoryFrom, now: now)
        sum += recent.reduce(0) { $1.isNaN ? $0 : $0 + Double($1) * 60 }
        return sum
    }

    /// The last few samples of each core, oldest first, in the order the CPU reports them.
    public func cores() -> [[Float]] {
        lock.withLock { recentCores.map(\.values) }
    }

    public func day(_ metric: SystemMetric, minutes count: Int = HistoryStore.minutes, now: Date = Date()) -> [Float] {
        lock.withLock { systemRings[metric]?.values(last: count, endingAt: Self.minute(now) - 1) ?? [] }
    }

    public func app(_ id: String, _ metric: AppMetric, minutes count: Int = HistoryStore.minutes, now: Date = Date()) -> [Float] {
        lock.withLock {
            guard let history = apps[id] else { return [] }
            let index = AppMetric.allCases.firstIndex(of: metric)!
            return history.rings[index].values(last: count, endingAt: Self.minute(now) - 1)
        }
    }

    public struct AppSummary: Codable, Sendable {
        public var id: String
        public var name: String
        public var kind: AppKind
        public var bundlePath: String?
        /// Averages over the minutes the app was running.
        public var cpu: Double
        public var memoryPeak: Double
        public var energyWh: Double
        public var diskBytes: Double
        public var networkBytes: Double
        public var minutes: Int
    }

    /// Totals for every app over the last `count` minutes.
    public func summaries(minutes count: Int = 60, now: Date = Date()) -> [AppSummary] {
        let end = Self.minute(now) - 1
        return lock.withLock {
            apps.compactMap { id, history in
                let cpu = history.rings[0].values(last: count, endingAt: end).filter { !$0.isNaN }
                guard !cpu.isEmpty else { return nil }
                let mem = history.rings[1].values(last: count, endingAt: end).filter { !$0.isNaN }
                let energy = history.rings[2].values(last: count, endingAt: end).filter { !$0.isNaN }
                let disk = history.rings[3].values(last: count, endingAt: end).filter { !$0.isNaN }
                let net = history.rings[4].values(last: count, endingAt: end).filter { !$0.isNaN }
                return AppSummary(id: id, name: history.name, kind: history.kind, bundlePath: history.bundlePath,
                                  cpu: Double(cpu.reduce(0, +)) / Double(cpu.count),
                                  memoryPeak: Double(mem.max() ?? 0),
                                  energyWh: Double(energy.reduce(0, +)) / 60,
                                  diskBytes: Double(disk.reduce(0, +)) * 60,
                                  networkBytes: Double(net.reduce(0, +)) * 60,
                                  minutes: cpu.count)
            }
        }
    }
}
