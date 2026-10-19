import Foundation
import SQLite3

/// Hourly per-app and machine totals on disk, kept for a year.
///
/// The database is written once an hour and read only when a history page or the
/// CLI asks, so it costs nothing between those moments.
public final class HourlyArchive: @unchecked Sendable {
    public struct Row: Codable, Sendable, Equatable {
        public var hour: Int
        public var app: String
        public var name: String
        public var cpu: Double
        public var memoryPeak: Double
        public var energyWh: Double
        public var diskBytes: Double
        public var networkBytes: Double
        public var minutes: Int
    }

    public static let retentionHours = 24 * 366

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public init?(url: URL = Wisp.supportDirectory.appendingPathComponent("history.sqlite")) {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS app_hours (
            hour INTEGER NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL,
            cpu REAL, memory_peak REAL, energy_wh REAL, disk_bytes REAL, network_bytes REAL, minutes INTEGER,
            PRIMARY KEY (hour, app));
        CREATE INDEX IF NOT EXISTS app_hours_app ON app_hours (app, hour);
        CREATE TABLE IF NOT EXISTS system_hours (
            hour INTEGER NOT NULL, metric TEXT NOT NULL, value REAL, PRIMARY KEY (hour, metric));
        """)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func write(hour: Int, apps: [Row], system: [SystemMetric: Double]) {
        lock.withLock {
            exec("BEGIN")
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO app_hours VALUES (?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK {
                for row in apps {
                    sqlite3_bind_int64(statement, 1, Int64(row.hour))
                    sqlite3_bind_text(statement, 2, row.app, -1, Self.transient)
                    sqlite3_bind_text(statement, 3, row.name, -1, Self.transient)
                    sqlite3_bind_double(statement, 4, row.cpu)
                    sqlite3_bind_double(statement, 5, row.memoryPeak)
                    sqlite3_bind_double(statement, 6, row.energyWh)
                    sqlite3_bind_double(statement, 7, row.diskBytes)
                    sqlite3_bind_double(statement, 8, row.networkBytes)
                    sqlite3_bind_int64(statement, 9, Int64(row.minutes))
                    sqlite3_step(statement)
                    sqlite3_reset(statement)
                }
            }
            sqlite3_finalize(statement)
            if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO system_hours VALUES (?,?,?)", -1, &statement, nil) == SQLITE_OK {
                for (metric, value) in system {
                    sqlite3_bind_int64(statement, 1, Int64(hour))
                    sqlite3_bind_text(statement, 2, metric.rawValue, -1, Self.transient)
                    sqlite3_bind_double(statement, 3, value)
                    sqlite3_step(statement)
                    sqlite3_reset(statement)
                }
            }
            sqlite3_finalize(statement)
            exec("DELETE FROM app_hours WHERE hour < \(hour - Self.retentionHours)")
            exec("DELETE FROM system_hours WHERE hour < \(hour - Self.retentionHours)")
            exec("COMMIT")
        }
    }

    /// Hourly rows for one app, or for every app when `app` is nil, newest last.
    public func rows(app: String? = nil, since hour: Int) -> [Row] {
        lock.withLock {
            var statement: OpaquePointer?
            let sql = app == nil
                ? "SELECT * FROM app_hours WHERE hour >= ? ORDER BY hour"
                : "SELECT * FROM app_hours WHERE hour >= ? AND app = ? ORDER BY hour"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(hour))
            if let app { sqlite3_bind_text(statement, 2, app, -1, Self.transient) }
            var rows: [Row] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Row(hour: Int(sqlite3_column_int64(statement, 0)),
                                app: String(cString: sqlite3_column_text(statement, 1)),
                                name: String(cString: sqlite3_column_text(statement, 2)),
                                cpu: sqlite3_column_double(statement, 3),
                                memoryPeak: sqlite3_column_double(statement, 4),
                                energyWh: sqlite3_column_double(statement, 5),
                                diskBytes: sqlite3_column_double(statement, 6),
                                networkBytes: sqlite3_column_double(statement, 7),
                                minutes: Int(sqlite3_column_int64(statement, 8))))
            }
            return rows
        }
    }

    public func system(_ metric: SystemMetric, since hour: Int) -> [(hour: Int, value: Double)] {
        lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT hour, value FROM system_hours WHERE metric = ? AND hour >= ? ORDER BY hour", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, metric.rawValue, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, Int64(hour))
            var result: [(Int, Double)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((Int(sqlite3_column_int64(statement, 0)), sqlite3_column_double(statement, 1)))
            }
            return result
        }
    }

    public static var currentHour: Int { Int(Date().timeIntervalSince1970 / 3600) }
}
