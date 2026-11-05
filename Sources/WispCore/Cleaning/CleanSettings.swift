import Foundation

/// How often a scheduled clean comes due. Off unless the owner turns it on.
public enum CleanSchedule: String, Codable, CaseIterable, Sendable {
    case off, weekly, monthly, quarterly, custom

    public var title: String {
        switch self {
        case .off: return "Off"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        case .quarterly: return "Every 3 months"
        case .custom: return "Every few days"
        }
    }
}

/// Clean Up's own settings, kept as JSON in the support folder so the app and the CLI read the same ones.
public struct CleanSettings: Codable, Equatable, Sendable {
    /// Absolute paths the owner excluded from every scan and clean.
    public var exclusions: [String] = []
    /// A project untouched for this many days counts as stale (the Developer tab reads it).
    public var staleProjectDays = 30
    public var schedule = CleanSchedule.off
    /// Days between cleans for `.custom`.
    public var customDays = 14
    /// When the next scheduled clean is due; nil while the schedule is off.
    public var nextDue: Date?
    /// One FSEvents stream on the Applications folders, to offer the leftovers of a deleted app.
    public var watchDeletedApps = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field falls back to its default, so a file from another build still loads.
        let fallback = CleanSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exclusions = (try? c.decode([String].self, forKey: .exclusions)) ?? fallback.exclusions
        staleProjectDays = (try? c.decode(Int.self, forKey: .staleProjectDays)) ?? fallback.staleProjectDays
        schedule = (try? c.decode(CleanSchedule.self, forKey: .schedule)) ?? fallback.schedule
        customDays = (try? c.decode(Int.self, forKey: .customDays)) ?? fallback.customDays
        nextDue = try? c.decode(Date.self, forKey: .nextDue)
        watchDeletedApps = (try? c.decode(Bool.self, forKey: .watchDeletedApps)) ?? fallback.watchDeletedApps
    }

    public static var fileURL: URL { Wisp.supportDirectory.appendingPathComponent("clean-settings.json") }

    public static func load(from url: URL = fileURL) -> CleanSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? CleanHistory.decoder.decode(CleanSettings.self, from: data) else {
            return CleanSettings()
        }
        return settings
    }

    public func save(to url: URL = fileURL) {
        guard let data = try? CleanHistory.encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Exclusions

    public func isExcluded(_ path: String) -> Bool {
        CleanScanContext(excluded: exclusions).isExcluded(path)
    }

    /// Adds a path, dropping any exclusion it already covers.
    public mutating func exclude(_ path: String) {
        let path = (path as NSString).standardizingPath
        guard !isExcluded(path) else { return }
        exclusions.removeAll { $0.hasPrefix(path + "/") }
        exclusions.append(path)
        exclusions.sort()
    }

    // MARK: Schedule

    /// The date a clean done at `date` makes the next one due, or nil when the schedule is off.
    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch schedule {
        case .off: return nil
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: return calendar.date(byAdding: .month, value: 3, to: date)
        case .custom: return calendar.date(byAdding: .day, value: max(1, customDays), to: date)
        }
    }

    public func isDue(now: Date = Date()) -> Bool {
        guard schedule != .off, let nextDue else { return false }
        return now >= nextDue
    }

    /// Changes the schedule and counts the first clean from now, so turning it on never cleans at once.
    public mutating func setSchedule(_ schedule: CleanSchedule, customDays days: Int? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.schedule = schedule
        if let days { customDays = max(1, days) }
        nextDue = nextDate(after: now, calendar: calendar)
    }

    /// After a scheduled clean, or after the owner saw the notice: the next one is one interval later.
    public mutating func scheduleNext(from now: Date = Date(), calendar: Calendar = .current) {
        nextDue = nextDate(after: now, calendar: calendar)
    }
}
