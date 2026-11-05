import Foundation

/// What happened to one item when a clean ran.
public enum CleanOutcome: Codable, Sendable, Equatable {
    case removed
    /// Left alone on purpose; the reason is one plain sentence ("Xcode is open").
    case skipped(String)
    case failed(String)

    public var removed: Bool { self == .removed }

    /// "Removed", or the reason it was not.
    public var summary: String {
        switch self {
        case .removed: return "Removed"
        case .skipped(let reason), .failed(let reason): return reason
        }
    }
}

/// One clean, as the History tab and `wisp clean --history` list it.
public struct CleanRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Trigger: String, Codable, Sendable {
        case manual, scheduled, cli

        public var title: String {
            switch self {
            case .manual: return "You"
            case .scheduled: return "Schedule"
            case .cli: return "wisp clean"
            }
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var tab: CleanTab
        public var paths: [String]
        public var bytes: Int64
        public var removal: CleanRemoval
        public var outcome: CleanOutcome

        public init(name: String, tab: CleanTab, paths: [String], bytes: Int64, removal: CleanRemoval, outcome: CleanOutcome) {
            self.name = name
            self.tab = tab
            self.paths = paths
            self.bytes = bytes
            self.removal = removal
            self.outcome = outcome
        }
    }

    public var id: UUID
    public var date: Date
    public var trigger: Trigger
    public var items: [Item]
    public var bytesFreed: Int64

    public init(id: UUID = UUID(), date: Date = Date(), trigger: Trigger, items: [Item], bytesFreed: Int64) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.items = items
        self.bytesFreed = bytesFreed
    }

    public var removedCount: Int { items.filter(\.outcome.removed).count }
}

/// Past cleans, newest last, in one JSON file in the support folder. Only the last 200 are kept.
public enum CleanHistory {
    public static let limit = 200

    public static var fileURL: URL { Wisp.supportDirectory.appendingPathComponent("clean-history.json") }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load(from url: URL = fileURL) -> [CleanRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([CleanRecord].self, from: data)) ?? []
    }

    /// Adds a record and trims the file to the newest `limit`. The app and the CLI can both
    /// write, so the read and the write happen under a lock on the file.
    public static func append(_ record: CleanRecord, to url: URL = fileURL) {
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var records = load(from: url)
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
