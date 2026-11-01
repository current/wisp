import Foundation

/// Bytes each app sent and received per day, from the per-app measurements Wisp
/// already makes. Nothing extra is sampled: a day only grows while per-app
/// network is measured (a page or drawer showing it, or background tracking), so
/// the totals are a floor, and `since` says when counting began.
///
/// Kept in memory and written as one small JSON file at most every five minutes
/// and on quit. Days older than `keepDays` are dropped.
public final class AppDataUsage: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var received: Double
        public var sent: Double
        public var bytes: Double { received + sent }
    }

    public struct Day: Codable, Sendable, Equatable {
        /// Local calendar day, "2026-11-04".
        public var day: String
        public var apps: [String: Entry] = [:]
        /// Seconds of the day per-app network was measured.
        public var measuredSeconds: Double = 0
    }

    private struct File: Codable {
        var since: Date?
        var days: [Day]
    }

    public static let keepDays = 62
    /// Last few minutes per app, for "what is using my hotspot".
    public static let recentWindow: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let url: URL?
    private var days: [Day] = []
    private var first: Date?
    private var dirty = false
    private var savedAt = Date()
    private var recent: [(date: Date, seconds: Double, apps: [String: (Double, Double)])] = []
    private let calendar: Calendar

    /// `url` nil keeps everything in memory only.
    public init(url: URL?, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        days = file.days
        first = file.since
    }

    public static var defaultURL: URL { Wisp.supportDirectory.appendingPathComponent("data-usage.json") }

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Recording

    /// Adds one process pass. Only passes that measured per-app network count.
    public func record(_ table: ProcessTable) {
        guard table.networkMeasured, table.interval > 0, table.interval < 600 else { return }
        let dt = table.interval
        var add: [String: (String, Double, Double)] = [:]
        for app in table.apps where app.networkInPerSecond > 0 || app.networkOutPerSecond > 0 {
            add[app.id] = (app.name, app.networkInPerSecond * dt, app.networkOutPerSecond * dt)
        }
        record(date: table.date, seconds: dt, apps: add)
    }

    func record(date: Date, seconds: Double, apps add: [String: (name: String, received: Double, sent: Double)]) {
        let key = dayKey(date)
        lock.withLock {
            if first == nil { first = date.addingTimeInterval(-seconds) }
            if days.last?.day != key {
                days.append(Day(day: key))
                if days.count > Self.keepDays { days.removeFirst(days.count - Self.keepDays) }
            }
            let last = days.count - 1
            days[last].measuredSeconds += seconds
            for (id, value) in add {
                var entry = days[last].apps[id] ?? Entry(name: value.name, received: 0, sent: 0)
                entry.name = value.name
                entry.received += value.received
                entry.sent += value.sent
                days[last].apps[id] = entry
            }
            recent.append((date, seconds, add.mapValues { ($0.received, $0.sent) }))
            let cutoff = date.addingTimeInterval(-Self.recentWindow)
            if let drop = recent.firstIndex(where: { $0.date >= cutoff }), drop > 0 { recent.removeFirst(drop) }
            dirty = true
        }
        if date.timeIntervalSince(savedAt) > 300 { save() }
    }

    /// Writes the file if anything changed. Cheap enough to call on quit.
    public func save() {
        guard let url else { return }
        let data: Data? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            savedAt = Date()
            return try? JSONEncoder().encode(File(since: first, days: days))
        }
        if let data { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Reading

    /// When counting began, or nil before the first measured pass.
    public var since: Date? { lock.withLock { first } }

    public func startOfWeek(_ now: Date = Date()) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    public func startOfMonth(_ now: Date = Date()) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    /// Totals per app from the local day of `start` through today.
    public func totals(since start: Date) -> [String: Entry] {
        let from = dayKey(start)
        return lock.withLock {
            var result: [String: Entry] = [:]
            for day in days where day.day >= from {
                for (id, entry) in day.apps {
                    var total = result[id] ?? Entry(name: entry.name, received: 0, sent: 0)
                    total.received += entry.received
                    total.sent += entry.sent
                    total.name = entry.name
                    result[id] = total
                }
            }
            return result
        }
    }

    /// One app's today, this week and this month.
    public func usage(of id: String, now: Date = Date()) -> (today: Entry?, week: Entry?, month: Entry?) {
        (totals(since: calendar.startOfDay(for: now))[id], totals(since: startOfWeek(now))[id], totals(since: startOfMonth(now))[id])
    }

    /// Hours measured since `start`.
    public func measuredSeconds(since start: Date) -> Double {
        let from = dayKey(start)
        return lock.withLock { days.filter { $0.day >= from }.reduce(0) { $0 + $1.measuredSeconds } }
    }

    /// Bytes per app over the last `window` seconds, with the seconds actually measured.
    public func recentTotals(window: TimeInterval = 5 * 60, now: Date = Date()) -> (apps: [String: Entry], seconds: Double) {
        let cutoff = now.addingTimeInterval(-window)
        return lock.withLock {
            var result: [String: Entry] = [:]
            var seconds = 0.0
            for pass in recent where pass.date > cutoff {
                seconds += pass.seconds
                for (id, value) in pass.apps {
                    var entry = result[id] ?? Entry(name: "", received: 0, sent: 0)
                    entry.received += value.0
                    entry.sent += value.1
                    result[id] = entry
                }
            }
            // Names come from today's totals, which every recent app is in.
            if let today = days.last {
                for id in result.keys { result[id]?.name = today.apps[id]?.name ?? id }
            }
            return (result, seconds)
        }
    }
}
