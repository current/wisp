import Foundation

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case cpu, memoryGrowth, diskWrites, network, temperature, appLimit
}

/// A limit the owner set for one app: tell me when it goes over this.
public struct AppLimit: Codable, Equatable, Sendable {
    public var appID: String
    public var appName: String
    /// Bytes of memory, or nil for no memory limit.
    public var memoryBytes: Double?
    /// Cores, or nil for no CPU limit.
    public var cpu: Double?

    public init(appID: String, appName: String, memoryBytes: Double? = nil, cpu: Double? = nil) {
        self.appID = appID
        self.appName = appName
        self.memoryBytes = memoryBytes
        self.cpu = cpu
    }
}

public struct AlertRules: Codable, Equatable, Sendable {
    public var cpuEnabled = true
    /// Cores. 0.9 is one core nearly pinned.
    public var cpuThreshold = 0.9
    public var cpuMinutes = 3.0

    public var memoryEnabled = true
    /// Growth over the window, in bytes, that counts as a leak worth a look.
    public var memoryGrowthBytes: Double = 1_000_000_000
    public var memoryWindowMinutes = 30

    public var diskEnabled = true
    public var diskBytesPerSecond: Double = 50_000_000
    public var diskMinutes = 2.0

    public var networkEnabled = false
    public var networkBytesPerSecond: Double = 10_000_000
    public var networkMinutes = 2.0

    /// The CPU running hot for a while. Off by default: it reads the sensor on the background pass.
    public var temperatureEnabled = false
    public var temperatureCelsius = 95.0
    public var temperatureMinutes = 2.0

    /// Per-app limits, each checked after the app has been over it for a minute.
    public var appLimits: [AppLimit] = []

    /// No repeat for the same app and rule inside this many minutes.
    public var cooldownMinutes = 30.0

    public init() {}

    public init(from decoder: Decoder) throws {
        // Rules saved by an older build lack the newer fields; each falls back on its own.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertRules()
        cpuEnabled = try c.decodeIfPresent(Bool.self, forKey: .cpuEnabled) ?? d.cpuEnabled
        cpuThreshold = try c.decodeIfPresent(Double.self, forKey: .cpuThreshold) ?? d.cpuThreshold
        cpuMinutes = try c.decodeIfPresent(Double.self, forKey: .cpuMinutes) ?? d.cpuMinutes
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? d.memoryEnabled
        memoryGrowthBytes = try c.decodeIfPresent(Double.self, forKey: .memoryGrowthBytes) ?? d.memoryGrowthBytes
        memoryWindowMinutes = try c.decodeIfPresent(Int.self, forKey: .memoryWindowMinutes) ?? d.memoryWindowMinutes
        diskEnabled = try c.decodeIfPresent(Bool.self, forKey: .diskEnabled) ?? d.diskEnabled
        diskBytesPerSecond = try c.decodeIfPresent(Double.self, forKey: .diskBytesPerSecond) ?? d.diskBytesPerSecond
        diskMinutes = try c.decodeIfPresent(Double.self, forKey: .diskMinutes) ?? d.diskMinutes
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? d.networkEnabled
        networkBytesPerSecond = try c.decodeIfPresent(Double.self, forKey: .networkBytesPerSecond) ?? d.networkBytesPerSecond
        networkMinutes = try c.decodeIfPresent(Double.self, forKey: .networkMinutes) ?? d.networkMinutes
        temperatureEnabled = try c.decodeIfPresent(Bool.self, forKey: .temperatureEnabled) ?? d.temperatureEnabled
        temperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .temperatureCelsius) ?? d.temperatureCelsius
        temperatureMinutes = try c.decodeIfPresent(Double.self, forKey: .temperatureMinutes) ?? d.temperatureMinutes
        appLimits = try c.decodeIfPresent([AppLimit].self, forKey: .appLimits) ?? d.appLimits
        cooldownMinutes = try c.decodeIfPresent(Double.self, forKey: .cooldownMinutes) ?? d.cooldownMinutes
    }
}

public struct Alert: Codable, Sendable, Equatable {
    public var kind: AlertKind
    public var appID: String
    public var appName: String
    public var title: String
    public var body: String
    public var date: Date
}

/// Watches every process pass for apps that stay over a limit.
///
/// Sustained rules track when an app first crossed the line and fire once it has
/// stayed there long enough; a single quiet pass resets the clock. Memory growth
/// looks at the minute history instead, because a leak is a trend, not a spike.
public final class AlertEngine: @unchecked Sendable {
    public var rules: AlertRules
    private var since: [AlertKind: [String: Date]] = [:]
    private var lastFired: [String: Date] = [:]
    private var hotSince: Date?
    private var overLimitSince: [String: Date] = [:]
    /// The last 50 alerts, newest last, for the CLI and assistants.
    public private(set) var recent: [Alert] = []
    /// Called on the engine's queue whenever `recent` changes, so the app can save it.
    public var onChange: (([Alert]) -> Void)?

    public init(rules: AlertRules = AlertRules()) {
        self.rules = rules
    }

    public var needsNetwork: Bool { rules.networkEnabled }
    public var needsTemperature: Bool { rules.temperatureEnabled }

    /// Puts back alerts saved by an earlier run.
    public func restore(_ alerts: [Alert]) {
        recent = Array(alerts.suffix(50))
    }

    public func clear() {
        recent = []
        onChange?(recent)
    }

    /// The machine-wide temperature rule.
    public func evaluate(cpuCelsius: Double?, now: Date = Date()) -> Alert? {
        guard rules.temperatureEnabled, let celsius = cpuCelsius, celsius >= rules.temperatureCelsius else {
            hotSince = nil
            return nil
        }
        let first = hotSince ?? now
        hotSince = first
        guard now.timeIntervalSince(first) >= rules.temperatureMinutes * 60 else { return nil }
        return fire(.temperature, id: "mac", name: "This Mac", now: now,
                    ("The CPU is running hot", "\(Format.celsius(celsius)) for more than \(Format.minutes(rules.temperatureMinutes))."))
    }

    public func evaluate(_ table: ProcessTable, history: HistoryStore?, now: Date = Date()) -> [Alert] {
        guard table.interval > 0 else { return [] }
        var alerts: [Alert] = []
        let appIDs = Set(table.apps.map(\.id))

        func sustained(_ kind: AlertKind, enabled: Bool, minutes: Double, value: (AppGroup) -> Double, threshold: Double,
                       message: (AppGroup) -> (String, String)) {
            guard enabled else {
                since[kind] = nil
                return
            }
            var started = since[kind] ?? [:]
            for app in table.apps {
                if value(app) >= threshold {
                    let first = started[app.id] ?? now
                    started[app.id] = first
                    if now.timeIntervalSince(first) >= minutes * 60, let alert = fire(kind, app, now: now, message(app)) {
                        alerts.append(alert)
                    }
                } else {
                    started[app.id] = nil
                }
            }
            started = started.filter { appIDs.contains($0.key) }
            since[kind] = started
        }

        sustained(.cpu, enabled: rules.cpuEnabled, minutes: rules.cpuMinutes, value: \.cpu, threshold: rules.cpuThreshold) { app in
            ("\(app.name) is using a lot of CPU",
             "\(Format.percent(app.cpu)) of a core for more than \(Format.minutes(self.rules.cpuMinutes)).")
        }
        sustained(.diskWrites, enabled: rules.diskEnabled, minutes: rules.diskMinutes, value: \.diskWritePerSecond,
                  threshold: rules.diskBytesPerSecond) { app in
            ("\(app.name) is writing heavily to disk",
             "\(Format.rate(app.diskWritePerSecond)) for more than \(Format.minutes(self.rules.diskMinutes)).")
        }
        if table.networkMeasured {
            sustained(.network, enabled: rules.networkEnabled, minutes: rules.networkMinutes, value: \.networkPerSecond,
                      threshold: rules.networkBytesPerSecond) { app in
                ("\(app.name) is moving a lot of data",
                 "\(Format.rate(app.networkPerSecond)) over the network for more than \(Format.minutes(self.rules.networkMinutes)).")
            }
        }

        // Per-app limits: over for a whole minute, so one busy moment does not count.
        var stillOver = Set<String>()
        for limit in rules.appLimits {
            guard let app = table.apps.first(where: { $0.id == limit.appID }) else { continue }
            var over: String?
            if let bytes = limit.memoryBytes, Double(app.memory) > bytes {
                over = "\(Format.memory(app.memory)) of memory, over your limit of \(Format.memory(bytes))."
            } else if let cores = limit.cpu, app.cpu > cores {
                over = "\(Format.percent(app.cpu)) CPU, over your limit of \(Format.percent(cores))."
            }
            guard let over else { continue }
            stillOver.insert(app.id)
            let first = overLimitSince[app.id] ?? now
            overLimitSince[app.id] = first
            if now.timeIntervalSince(first) >= 60,
               let alert = fire(.appLimit, id: app.id, name: app.name, now: now, ("\(app.name) is over its limit", over)) {
                alerts.append(alert)
            }
        }
        overLimitSince = overLimitSince.filter { stillOver.contains($0.key) }

        if rules.memoryEnabled, let history {
            for app in table.apps where Double(app.memory) > rules.memoryGrowthBytes {
                let series = history.app(app.id, .memory, minutes: rules.memoryWindowMinutes, now: now)
                if Self.isGrowing(series, by: rules.memoryGrowthBytes),
                   let alert = fire(.memoryGrowth, app, now: now,
                                    ("\(app.name) keeps growing in memory",
                                     "Up \(Format.bytes(UInt64(Self.growth(series)))) in the last \(rules.memoryWindowMinutes) minutes, now \(Format.bytes(app.memory)).")) {
                    alerts.append(alert)
                }
            }
        }
        return alerts
    }

    private func fire(_ kind: AlertKind, _ app: AppGroup, now: Date, _ message: (String, String)) -> Alert? {
        fire(kind, id: app.id, name: app.name, now: now, message)
    }

    private func fire(_ kind: AlertKind, id: String, name: String, now: Date, _ message: (String, String)) -> Alert? {
        let key = kind.rawValue + "|" + id
        if let last = lastFired[key], now.timeIntervalSince(last) < rules.cooldownMinutes * 60 { return nil }
        lastFired[key] = now
        let alert = Alert(kind: kind, appID: id, appName: name, title: message.0, body: message.1, date: now)
        recent.append(alert)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        onChange?(recent)
        return alert
    }

    static func growth(_ series: [Float]) -> Double {
        let values = series.filter { !$0.isNaN }
        guard let first = values.first, let last = values.last else { return 0 }
        return Double(last - first)
    }

    /// Grew by at least `bytes` across the window, with most minute-to-minute steps
    /// flat or upward, so a single large allocation that is later freed does not count.
    static func isGrowing(_ series: [Float], by bytes: Double) -> Bool {
        let values = series.filter { !$0.isNaN }
        guard values.count >= max(10, series.count * 2 / 3) else { return false }
        guard growth(series) >= bytes else { return false }
        var up = 0
        for index in 1..<values.count where values[index] >= values[index - 1] * 0.98 { up += 1 }
        return Double(up) / Double(values.count - 1) >= 0.8
    }
}
