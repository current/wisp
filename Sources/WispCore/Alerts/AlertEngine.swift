import Foundation

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case cpu, memoryGrowth, diskWrites, network
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

    /// No repeat for the same app and rule inside this many minutes.
    public var cooldownMinutes = 30.0

    public init() {}
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
    /// The last 50 alerts, newest last, for the CLI and assistants.
    public private(set) var recent: [Alert] = []

    public init(rules: AlertRules = AlertRules()) {
        self.rules = rules
    }

    public var needsNetwork: Bool { rules.networkEnabled }

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
        let key = kind.rawValue + "|" + app.id
        if let last = lastFired[key], now.timeIntervalSince(last) < rules.cooldownMinutes * 60 { return nil }
        lastFired[key] = now
        let alert = Alert(kind: kind, appID: app.id, appName: app.name, title: message.0, body: message.1, date: now)
        recent.append(alert)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
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
