import Foundation
import SQLite3

/// Where the battery's power came from in a logged minute.
public enum BatteryLogState: UInt8, Codable, Sendable {
    case onBattery = 1
    case charging = 2
    /// Plugged in and not charging (full, or the charge is held).
    case pluggedIn = 3
}

public struct BatteryLogSample: Codable, Sendable, Equatable {
    /// Minutes since 1970.
    public var minute: Int
    public var level: Float
    public var state: BatteryLogState

    public init(minute: Int, level: Float, state: BatteryLogState) {
        self.minute = minute
        self.level = level
        self.state = state
    }
}

/// The battery level once a minute for the last week, for the charge history.
///
/// Only minutes on battery or charging are kept, plus the first minute plugged in
/// without charging, so a Mac that sits on its charger writes almost nothing. Samples
/// are buffered and written in batches; reads happen only while the Battery page is open.
public final class BatteryLog: @unchecked Sendable {
    public static let keepMinutes = 8 * 1440
    static let batch = 15

    private let lock = NSLock()
    private var db: OpaquePointer?
    /// Samples not yet on disk, or every sample when there is no database.
    private var pending: [BatteryLogSample] = []
    private var lastState: BatteryLogState?
    private var lastMinute = 0

    /// A nil url keeps the log in memory only, for history turned off and for tests.
    public init(url: URL?) {
        guard let url else { return }
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            return
        }
        sqlite3_exec(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS battery_minutes (minute INTEGER PRIMARY KEY, level REAL NOT NULL, state INTEGER NOT NULL);
        """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    /// Whether a minute in this state is worth keeping, given the state logged before it.
    static func keeps(_ state: BatteryLogState, after previous: BatteryLogState?) -> Bool {
        state != .pluggedIn || previous != .pluggedIn
    }

    public func record(level: Double, charging: Bool, plugged: Bool, at date: Date = Date()) {
        let state: BatteryLogState = charging ? .charging : (plugged ? .pluggedIn : .onBattery)
        let minute = HistoryStore.minute(date)
        lock.withLock {
            guard minute != lastMinute else { return }
            defer { lastState = state }
            guard Self.keeps(state, after: lastState) else { return }
            lastMinute = minute
            pending.append(BatteryLogSample(minute: minute, level: Float(level), state: state))
            if db != nil, pending.count >= Self.batch { writePending() }
            if db == nil, pending.count > Self.keepMinutes { pending.removeFirst(pending.count - Self.keepMinutes) }
        }
    }

    /// Writes buffered samples to disk, for quitting.
    public func flush() {
        lock.withLock { writePending() }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func writePending() {
        guard let db, !pending.isEmpty else { return }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO battery_minutes VALUES (?,?,?)", -1, &statement, nil) == SQLITE_OK {
            for sample in pending {
                sqlite3_bind_int64(statement, 1, Int64(sample.minute))
                sqlite3_bind_double(statement, 2, Double(sample.level))
                sqlite3_bind_int64(statement, 3, Int64(sample.state.rawValue))
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
        }
        sqlite3_finalize(statement)
        let oldest = (pending.last?.minute ?? 0) - Self.keepMinutes
        sqlite3_exec(db, "DELETE FROM battery_minutes WHERE minute < \(oldest)", nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        pending.removeAll(keepingCapacity: true)
    }

    /// Every logged sample from `minute` on, oldest first.
    public func samples(since minute: Int) -> [BatteryLogSample] {
        lock.withLock {
            var result: [BatteryLogSample] = []
            if let db {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT minute, level, state FROM battery_minutes WHERE minute >= ? ORDER BY minute", -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int64(statement, 1, Int64(minute))
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let state = BatteryLogState(rawValue: UInt8(clamping: sqlite3_column_int64(statement, 2))) else { continue }
                        result.append(BatteryLogSample(minute: Int(sqlite3_column_int64(statement, 0)),
                                                       level: Float(sqlite3_column_double(statement, 1)), state: state))
                    }
                }
                sqlite3_finalize(statement)
            }
            let newer = pending.filter { $0.minute >= minute && $0.minute > (result.last?.minute ?? .min) }
            result.append(contentsOf: newer)
            return result
        }
    }
}
