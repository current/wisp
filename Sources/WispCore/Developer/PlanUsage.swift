import Foundation

/// How much of an AI plan's limits is used, per account on this Mac.
public struct PlanUsage: Codable, Sendable, Equatable, Identifiable {
    public struct Window: Codable, Sendable, Equatable {
        /// "5-hour session", "This week"...
        public var name: String
        /// 0 to 1.
        public var used: Double
        public var resets: Date?
    }

    public var provider: String
    public var account: String
    public var plan: String?
    public var windows: [Window]
    /// When the tool last reported these figures.
    public var updated: Date?
    /// Set when the limits could not be read, in words a person can act on.
    public var problem: String?
    public var id: String { provider + ":" + account }
}

/// Reads plan limits from what Claude Code and Codex already report on this Mac:
/// Claude Code hands them to its status line, which Wisp joins (see `ClaudeStatusLine`),
/// and Codex writes them into its session logs. No sign-in is read and nothing is sent.
public enum PlanUsageReader {
    /// Claude Code config folders: ~/.claude and any ~/.claude-* with a .claude.json.
    public static func claudeFolders(home: String = NSHomeDirectory()) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0 == ".claude" || ($0.hasPrefix(".claude-") && !$0.contains(".json")) }
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0 + "/.claude.json") || $0 == home + "/.claude" }
            .sorted()
    }

    /// Codex home folders: ~/.codex and any ~/.codex-* that keeps sessions.
    static func codexFolders(home: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0 == ".codex" || $0.hasPrefix(".codex-") }
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0 + "/sessions") }
            .sorted()
    }

    /// The account fields Claude Code keeps beside its settings (not the sign-in).
    static func claudeAccount(folder: String, home: String) -> (email: String?, plan: String?) {
        let paths = folder == home + "/.claude" ? [home + "/.claude.json", folder + "/.claude.json"] : [folder + "/.claude.json"]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["oauthAccount"] as? [String: Any], let email = account["emailAddress"] as? String else { continue }
            return (email, account["planDisplayName"] as? String)
        }
        return (nil, nil)
    }

    /// Every account with figures, plus connected Claude folders still waiting for their first.
    public static func readAll(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store, now: Date = Date()) -> [PlanUsage] {
        var byAccount: [String: PlanUsage] = [:]
        for folder in claudeFolders(home: home) {
            let (email, plan) = claudeAccount(folder: folder, home: home)
            let account = email ?? (folder as NSString).lastPathComponent
            var usage = PlanUsage(provider: "Claude", account: account, plan: plan, windows: [])
            if let record = ClaudeStatusLine.read(folder: folder, store: store) {
                usage.windows = record.windows.map { window($0.name, used: $0.used, resets: $0.resets, now: now) }
                usage.updated = record.updated
            } else if ClaudeStatusLine.state(folder: folder) == .connected {
                usage.problem = "Waiting for Claude Code's next reply"
            } else {
                continue
            }
            // Two folders signed in to one account: keep the newer figures.
            let key = "claude:" + account
            if let existing = byAccount[key], (existing.updated ?? .distantPast) >= (usage.updated ?? .distantPast) { continue }
            byAccount[key] = usage
        }
        for folder in codexFolders(home: home) {
            guard var usage = codex(folder: folder, now: now) else { continue }
            usage.account = folder.replacingOccurrences(of: home, with: "~")
            byAccount["codex:" + folder] = usage
        }
        // Accounts with figures first, then by provider and name.
        return byAccount.values.sorted {
            ($0.problem == nil ? 0 : 1, $0.provider, $0.account) < ($1.problem == nil ? 0 : 1, $1.provider, $1.account)
        }
    }

    /// A window whose reset time has passed has had no use reported since.
    static func window(_ name: String, used: Double, resets: Date?, now: Date) -> PlanUsage.Window {
        if let resets, resets <= now { return .init(name: name, used: 0, resets: nil) }
        return .init(name: name, used: used, resets: resets)
    }

    static func windowName(minutes: Double?) -> String? {
        guard let minutes else { return nil }
        if minutes <= 300 { return "5-hour session" }
        if minutes >= 6 * 1440 { return "This week" }
        return nil
    }

    /// The last limits Codex wrote into its newest session logs.
    static func codex(folder: String, now: Date) -> PlanUsage? {
        for file in newestSessions(folder + "/sessions", count: 4) {
            guard let line = lastLine(containing: "\"rate_limits\":{", in: file),
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            var usage = PlanUsage(provider: "Codex", account: "", plan: (limits["plan_type"] as? String)?.capitalized, windows: [])
            for (key, fallback) in [("primary", "5-hour session"), ("secondary", "This week")] {
                guard let item = limits[key] as? [String: Any], let percent = item["used_percent"] as? Double else { continue }
                let resets = (item["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                usage.windows.append(window(windowName(minutes: item["window_minutes"] as? Double) ?? fallback,
                                            used: percent / 100, resets: resets, now: now))
            }
            guard !usage.windows.isEmpty else { continue }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            usage.updated = (json["timestamp"] as? String).flatMap(iso.date(from:))
                ?? (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)
            return usage
        }
        return nil
    }

    /// Session logs live in sessions/YYYY/MM/DD. A session keeps writing to the day it
    /// started, so the newest few files of the two latest days are compared by date.
    static func newestSessions(_ root: String, count: Int) -> [String] {
        let fm = FileManager.default
        func sortedDown(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >).map { path + "/" + $0 }
        }
        var days: [String] = []
        outer: for year in sortedDown(root) {
            for month in sortedDown(year) {
                for day in sortedDown(month) {
                    days.append(day)
                    if days.count == 2 { break outer }
                }
            }
        }
        let files = days.flatMap(sortedDown).filter { $0.hasSuffix(".jsonl") }
        let dated = files.map { ($0, (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
    }

    /// The last whole line holding `marker`, from the final 256 KB of the file.
    static func lastLine(containing marker: String, in path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let needle = Data(marker.utf8)
        for line in data.split(separator: 10).reversed() where line.range(of: needle) != nil {
            // Codex writes "rate_limits":{"primary":null...} before the first reply; skip those.
            if line.range(of: Data("\"used_percent\"".utf8)) != nil { return Data(line) }
        }
        return nil
    }
}

/// Wisp joins Claude Code's status line to see the plan limits Claude Code itself
/// reports there. The status line you already have keeps running: Wisp passes it the
/// same input and prints what it prints. Turning plan limits off puts it back.
public enum ClaudeStatusLine {
    public struct Record: Codable, Equatable, Sendable {
        public struct Window: Codable, Equatable, Sendable {
            public var name: String
            public var used: Double
            public var resets: Date?
        }
        public var folder: String
        public var updated: Date
        public var windows: [Window]
    }

    public static var store: URL { Wisp.supportDirectory.appendingPathComponent("plan-limits", isDirectory: true) }

    static func fileName(folder: String) -> String {
        var name = (folder as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        return (name.isEmpty ? "claude" : name) + ".json"
    }

    // MARK: The helper side (`wisp statusline`)

    /// Saves the limits from one status-line input. Writes only when a figure changed
    /// or the saved one is a minute old, since Claude Code runs the status line often.
    public static func record(input: Data, folder: String, store: URL = store, now: Date = Date()) {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        var windows: [Record.Window] = []
        for (key, name) in [("five_hour", "5-hour session"), ("seven_day", "This week")] {
            guard let item = limits[key] as? [String: Any], let percent = item["used_percentage"] as? Double else { continue }
            windows.append(.init(name: name, used: percent / 100, resets: (item["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))))
        }
        guard !windows.isEmpty else { return }
        if let saved = read(folder: folder, store: store), saved.windows == windows, now.timeIntervalSince(saved.updated) < 60 { return }
        let record = Record(folder: folder, updated: now, windows: windows)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? data.write(to: store.appendingPathComponent(fileName(folder: folder)), options: .atomic)
    }

    public static func read(folder: String, store: URL = store) -> Record? {
        guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(fileName(folder: folder)).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }

    // MARK: The command in settings.json

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Reads one shell word written by `quote` from the front of `text`.
    static func unquote(_ text: Substring) -> (word: String, rest: Substring)? {
        var rest = text
        var word = ""
        var any = false
        while true {
            if rest.hasPrefix("'") {
                rest.removeFirst()
                guard let end = rest.firstIndex(of: "'") else { return nil }
                word += rest[..<end]
                rest = rest[rest.index(after: end)...]
                any = true
            } else if rest.hasPrefix(#"\'"#) {
                word += "'"
                rest = rest.dropFirst(2)
                any = true
            } else {
                break
            }
        }
        return any ? (word, rest) : nil
    }

    /// Runs the helper when it is there and falls back to the old status line when it is
    /// not, so moving or deleting Wisp never leaves Claude Code without one.
    public static func command(helper: String, folder: String, original: String?) -> String {
        let run = #"exec "$W" statusline --folder "# + quote(folder)
        guard let original, !original.isEmpty else { return "W=\(quote(helper)); [ -x \"$W\" ] && \(run)" }
        return "W=\(quote(helper)); if [ -x \"$W\" ]; then \(run) --then \(quote(original)); else exec /bin/sh -c \(quote(original)); fi"
    }

    public struct Parsed: Equatable {
        public var helper: String
        public var original: String?
    }

    /// Reads back a command written by `command`; nil for anyone else's.
    public static func parse(_ command: String) -> Parsed? {
        guard command.hasPrefix("W='"), command.contains(" statusline --folder "),
              let (helper, _) = unquote(command.dropFirst(2)) else { return nil }
        guard let range = command.range(of: " --then ") else { return Parsed(helper: helper, original: nil) }
        guard let (original, _) = unquote(command[range.upperBound...]) else { return nil }
        return Parsed(helper: helper, original: original)
    }

    public enum State: Equatable { case connected, notConnected, unreadable }

    static func settingsURL(folder: String) -> URL {
        URL(fileURLWithPath: folder + "/settings.json").resolvingSymlinksInPath()
    }

    static func loadSettings(folder: String) -> [String: Any]? {
        let url = settingsURL(folder: folder)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : [:]
        }
        if data.allSatisfy({ $0 == 10 || $0 == 32 || $0 == 13 || $0 == 9 }) { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Connected means the status line runs this copy of the helper.
    public static func state(folder: String, helper: String? = nil) -> State {
        guard let settings = loadSettings(folder: folder) else { return .unreadable }
        guard let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
              let parsed = parse(command) else { return .notConnected }
        if let helper, parsed.helper != helper { return .notConnected }
        return .connected
    }

    /// Adds Wisp in front of the folder's status line, keeping the one already set.
    /// The first time, a copy of settings.json is kept in `backups`.
    @discardableResult
    public static func connect(folder: String, helper: String, backups: URL) -> Bool {
        guard var settings = loadSettings(folder: folder) else { return false }
        var line = settings["statusLine"] as? [String: Any] ?? [:]
        var original = line["command"] as? String
        if let command = original, let parsed = parse(command) {
            if parsed.helper == helper { return true }
            original = parsed.original
        }
        if (line["type"] as? String).map({ $0 != "command" }) == true { original = nil }
        backUp(folder: folder, to: backups)
        line["type"] = "command"
        line["command"] = command(helper: helper, folder: folder, original: original)
        settings["statusLine"] = line
        return save(settings, folder: folder)
    }

    /// Puts back the status line Wisp wrapped, or removes it if there was none.
    @discardableResult
    public static func disconnect(folder: String) -> Bool {
        guard var settings = loadSettings(folder: folder), var line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String, let parsed = parse(command) else { return true }
        if let original = parsed.original {
            line["command"] = original
            settings["statusLine"] = line
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        return save(settings, folder: folder)
    }

    static func backUp(folder: String, to backups: URL) {
        let url = settingsURL(folder: folder)
        let target = backups.appendingPathComponent(fileName(folder: folder))
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    static func save(_ settings: [String: Any], folder: String) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        data.append(10)
        return (try? data.write(to: settingsURL(folder: folder), options: .atomic)) != nil
    }

    // MARK: Every folder at once

    public static var backups: URL { Wisp.supportDirectory.appendingPathComponent("claude-settings-backup", isDirectory: true) }

    /// Claude folders whose status line does not run `helper` yet.
    public static func unconnected(helper: String, home: String = NSHomeDirectory()) -> [String] {
        PlanUsageReader.claudeFolders(home: home).filter { state(folder: $0, helper: helper) == .notConnected }
    }

    public static func connectAll(helper: String, home: String = NSHomeDirectory()) {
        for folder in PlanUsageReader.claudeFolders(home: home) { connect(folder: folder, helper: helper, backups: backups) }
    }

    public static func disconnectAll(home: String = NSHomeDirectory()) {
        for folder in PlanUsageReader.claudeFolders(home: home) { disconnect(folder: folder) }
    }
}

/// Tokens Claude Code used today, counted from the session logs it keeps on this Mac.
/// Reads only what was appended since the last count.
public final class TokenCounter: @unchecked Sendable {
    private var offsets: [String: UInt64] = [:]
    private var day = ""
    private var total = 0
    private var counted = Set<String>()
    private let lock = NSLock()

    public init() {}

    public func today() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayText = formatter.string(from: Date())
        if todayText != day {
            day = todayText
            total = 0
            offsets.removeAll()
            counted.removeAll()
        }
        let midnight = Calendar.current.startOfDay(for: Date())
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for folder in PlanUsageReader.claudeFolders() {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder + "/projects"),
                                                              includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, modified >= midnight,
                      let size = values.fileSize else { continue }
                let start = offsets[url.path] ?? 0
                guard UInt64(size) > start, let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                try? handle.seek(toOffset: start)
                guard let data = try? handle.readToEnd() else { continue }
                // Count whole lines only; a line still being written is read next time.
                guard let lastNewline = data.lastIndex(of: 10) else { continue }
                offsets[url.path] = start + UInt64(lastNewline + 1)
                for line in data[..<lastNewline].split(separator: 10) {
                    guard line.count > 40, line.range(of: Data("\"usage\"".utf8)) != nil,
                          let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let stamp = (json["timestamp"] as? String).flatMap(iso.date(from:)), stamp >= midnight,
                          let message = json["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
                    // A reply split over several lines repeats its usage on each; count it once.
                    let key = (message["id"] as? String ?? "") + ":" + (json["requestId"] as? String ?? "")
                    if key != ":" { guard counted.insert(key).inserted else { continue } }
                    for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                        total += usage[key] as? Int ?? 0
                    }
                }
            }
        }
        return total
    }
}
