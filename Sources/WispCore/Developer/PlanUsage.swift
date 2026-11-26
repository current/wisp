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
    /// What another app calls the account, such as T3 Code's "Claude (alt)".
    public var label: String?
    public var id: String { provider + ":" + account }
}

/// Reads plan limits from what each agent reports. Claude Code, Codex and Antigravity are
/// asked by their own programs for each signed-in account (see `ClaudeLive`, `CodexLive`
/// and `AntigravityLive`), which covers use anywhere: other apps, other machines, the
/// web. Codex's session logs and Claude Code's status line, where Wisp was added to it
/// before, report between the questions. No sign-in is read and Wisp sends nothing itself.
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
    public static func codexFolders(home: String = NSHomeDirectory()) -> [String] {
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
            let found: (email: String?, plan: String?)? = FileCache.value(path, kind: "account") {
                guard let data = FileManager.default.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let account = json["oauthAccount"] as? [String: Any], let email = account["emailAddress"] as? String else { return nil }
                return (email, account["planDisplayName"] as? String ?? planName(organizationType: account["organizationType"] as? String))
            }
            if let found { return found }
        }
        return (nil, nil)
    }

    /// Older sign-ins keep only the organization type ("claude_pro"); name the plan from it.
    static func planName(organizationType: String?) -> String? {
        guard let type = organizationType, type.hasPrefix("claude_") else { return nil }
        let name = type.dropFirst("claude_".count)
        return name.isEmpty ? nil : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Every account with figures.
    public static func readAll(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store, now: Date = Date()) -> [PlanUsage] {
        var byAccount: [String: PlanUsage] = [:]
        let labels = T3CodeNames.labels(home: home)
        for folder in claudeFolders(home: home) {
            let (email, plan) = claudeAccount(folder: folder, home: home)
            let account = email ?? (folder as NSString).lastPathComponent
            let live = ClaudeLive.saved(folder: folder, store: store)
            var usage = PlanUsage(provider: "Claude", account: account, plan: plan ?? live?.plan, windows: [])
            usage.label = labels[folder]
            // Claude Code's answer and its status line can both report one folder: the
            // newer figures win, and limits only the answer has (a model's weekly limit)
            // stay beside them.
            var records = ClaudeStatusLine.read(folder: folder, store: store).map { [$0] } ?? []
            if let live {
                // Signed out since the status line last ran: nothing to show.
                if !live.available, live.updated >= (records.first?.updated ?? .distantPast) { continue }
                if live.available { records.append(.init(folder: folder, updated: live.updated, windows: live.windows)) }
            }
            guard let newest = records.max(by: { $0.updated < $1.updated }) else { continue }
            var windows = newest.windows
            for record in records where record != newest {
                windows += record.windows.filter { window in !windows.contains { $0.name == window.name } }
            }
            usage.windows = windows.map { window($0.name, used: $0.used, resets: $0.resets, now: now) }
            usage.updated = newest.updated
            // Two folders signed in to one account: keep the newer figures.
            let key = "claude:" + account
            if let existing = byAccount[key], (existing.updated ?? .distantPast) >= (usage.updated ?? .distantPast) { continue }
            byAccount[key] = usage
        }
        // Codex folders can share one sign-in (T3 Code's ~/.codex-t3 links to ~/.codex's),
        // so folders whose sessions name the same account are one account: the newest
        // figures win, and the name stays on the folder T3 Code labels, so a menu bar
        // item that picked it keeps it.
        var codexByAccount: [String: [(folder: String, usage: PlanUsage)]] = [:]
        for folder in codexFolders(home: home) {
            // What Codex logged while it worked here, or what it last answered when asked
            // (see `CodexLive`): the newer one.
            var found = codex(folder: folder, now: now).map { [$0] } ?? []
            if let live = CodexLive.saved(folder: folder, store: store), !live.windows.isEmpty {
                var usage = PlanUsage(provider: "Codex", account: "", plan: live.plan,
                                      windows: live.windows.map { window($0.name, used: $0.used, resets: $0.resets, now: now) })
                usage.updated = live.updated
                found.append((usage, live.accountID))
            }
            guard let (usage, accountID) = found.max(by: { ($0.0.updated ?? .distantPast) < ($1.0.updated ?? .distantPast) }) else { continue }
            // A log may lack the account id (older Codex); the live answer always has it.
            let account = accountID ?? found.compactMap(\.1).first
            codexByAccount[account ?? folder, default: []].append((folder, usage))
        }
        for (key, group) in codexByAccount {
            guard var usage = group.max(by: { ($0.usage.updated ?? .distantPast) < ($1.usage.updated ?? .distantPast) })?.usage else { continue }
            let named = group.first { labels[$0.folder] != nil }?.folder ?? group.map(\.folder).sorted().first!
            usage.account = named.replacingOccurrences(of: home, with: "~")
            usage.label = labels[named]
            byAccount["codex:" + key] = usage
        }
        if let live = AntigravityLive.saved(store: store) {
            var usage = PlanUsage(provider: "Antigravity", account: live.account ?? "Antigravity", plan: live.plan.map(AntigravityLive.planName),
                                  windows: live.windows.map { window($0.name, used: $0.used, resets: $0.resets, now: now) })
            usage.updated = live.updated
            byAccount["antigravity"] = usage
        }
        // Accounts with figures first, then by provider and name.
        return byAccount.values.sorted {
            ($0.problem == nil ? 0 : 1, $0.provider, $0.account) < ($1.problem == nil ? 0 : 1, $1.provider, $1.account)
        }
    }

    /// Files earlier versions kept: T3 Code's log index and the SSH hosts' answers.
    public static func removeRetiredFiles(store: URL = ClaudeStatusLine.store) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        for name in names where name == "t3-logs.json" || (name.hasPrefix("remote-") && name.hasSuffix(".json")) {
            try? FileManager.default.removeItem(at: store.appendingPathComponent(name))
        }
    }

    /// A window whose reset time has passed has had no use reported since.
    static func window(_ name: String, used: Double, resets: Date?, now: Date) -> PlanUsage.Window {
        if let resets, resets <= now { return .init(name: name, used: 0, resets: nil) }
        return .init(name: name, used: used, resets: resets)
    }

    public static func windowName(minutes: Double?) -> String? {
        guard let minutes else { return nil }
        if minutes <= 300 { return "5-hour session" }
        // Codex's free plan has a 30-day limit in place of a weekly one.
        if minutes >= 27 * 1440 { return "This month" }
        if minutes >= 6 * 1440 { return "This week" }
        return nil
    }

    /// The latest limits Codex wrote into its newest session logs, and the account that
    /// session ran under (Codex names it in the session's first line). A long session can
    /// keep its file the newest while a shorter one reported later, so each file's last
    /// figures are compared by when they were written.
    static func codex(folder: String, now: Date) -> (PlanUsage, accountID: String?)? {
        var best: (usage: PlanUsage, file: String)?
        for file in newestSessions(folder + "/sessions", count: 4) {
            let line = FileCache.value(file, kind: "codex-limits") { lastLine(containing: "\"rate_limits\":{", in: file) }
            guard let line,
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
            usage.updated = (json["timestamp"] as? String).flatMap(iso.date(from:)) ?? FileCache.modified(file)
            if let best, (best.usage.updated ?? .distantPast) >= (usage.updated ?? .distantPast) { continue }
            best = (usage, file)
        }
        return best.map { best in (best.usage, FileCache.value(best.file, kind: "codex-account") { accountID(sessionFile: best.file) }) }
    }

    /// The account id from a session's opening `session_meta` line, which comes first.
    static func accountID(sessionFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        // The cut can split a character; decoding repairs it rather than failing.
        let head = String(decoding: data, as: UTF8.self)
        guard let range = head.range(of: #""creator_account_id":"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = head[range].dropFirst(#""creator_account_id":""#.count).dropLast()
        return match.isEmpty ? nil : String(match)
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
        let dated = files.map { ($0, FileCache.modified($0) ?? .distantPast) }
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

    public static func disconnectAll(home: String = NSHomeDirectory()) {
        for folder in PlanUsageReader.claudeFolders(home: home) { disconnect(folder: folder) }
    }
}

/// Tokens Claude Code used today, counted from the session logs it keeps on this Mac.
/// Reads only what each log gained since the last count, and walks the folders for new
/// logs every few minutes; between walks it only checks the logs it knows.
public final class TokenCounter: @unchecked Sendable {
    /// The app's counter, so what it has read outlives the window that shows it.
    public static let shared = TokenCounter()

    private struct File {
        var inode: UInt64
        var offset: UInt64
    }

    private let roots: [String]?
    private let walkEvery: TimeInterval
    private var files: [String: File] = [:]
    private var walkedAt = Date.distantPast
    private var day = ""
    private var total = 0
    private var counted = Set<String>()
    private let lock = NSLock()
    private static let chunk = 4 << 20
    private static let usage = Data(#""usage""#.utf8)

    /// `roots` are the projects folders to read; by default those of every Claude folder.
    public init(roots: [String]? = nil, walkEvery: TimeInterval = 300) {
        self.roots = roots
        self.walkEvery = walkEvery
    }

    public func today(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayText = formatter.string(from: now)
        if todayText != day {
            // Offsets stay: what was read before midnight was written before it.
            day = todayText
            total = 0
            counted.removeAll()
        }
        let midnight = Calendar.current.startOfDay(for: now)
        if now.timeIntervalSince(walkedAt) >= walkEvery {
            walk(midnight: midnight)
            walkedAt = now
        }
        // Lines carry UTC timestamps; today here spans one or two UTC dates.
        let utc = DateFormatter()
        utc.dateFormat = "yyyy-MM-dd"
        utc.timeZone = TimeZone(identifier: "UTC")
        let days = Set([midnight, now].map { utc.string(from: $0) }).map { Data(("\"timestamp\":\"" + $0).utf8) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var bytesRead: UInt64 = 0
        defer {
            // Parsing a day's logs frees tens of MB of small blocks whose pages malloc keeps
            // dirty; after a large read, hand them back.
            if bytesRead > 32 << 20 { malloc_zone_pressure_relief(nil, 0) }
        }
        for (path, file) in files {
            var info = stat()
            guard stat(path, &info) == 0 else {
                files[path] = nil
                continue
            }
            var start = file.offset
            // Replaced or cut short: read it again from the top.
            if UInt64(info.st_ino) != file.inode || UInt64(info.st_size) < start { start = 0 }
            guard UInt64(info.st_size) > start else {
                files[path] = File(inode: UInt64(info.st_ino), offset: start)
                continue
            }
            let end = read(path, from: start, days: days, midnight: midnight, iso: iso)
            bytesRead += end - start
            files[path] = File(inode: UInt64(info.st_ino), offset: end)
        }
        return total
    }

    private func walk(midnight: Date) {
        var found = Set<String>()
        for root in roots ?? PlanUsageReader.claudeFolders().map({ $0 + "/projects" }) {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            for case let name as String in walker where name.hasSuffix(".jsonl") { found.insert(root + "/" + name) }
        }
        files = files.filter { found.contains($0.key) }
        for path in found where files[path] == nil {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            // A log untouched since midnight holds nothing from today: start at its end.
            let untouched = TimeInterval(info.st_mtimespec.tv_sec) < midnight.timeIntervalSince1970
            files[path] = File(inode: UInt64(info.st_ino), offset: untouched ? UInt64(info.st_size) : 0)
        }
    }

    /// Counts the whole lines from `start` on and returns where the next read begins;
    /// a line still being written is read next time.
    private func read(_ path: String, from start: UInt64, days: [Data], midnight: Date, iso: ISO8601DateFormatter) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return start }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil else { return start }
        var offset = start
        var pending = Data()
        // Each chunk the handle reads, and every line parsed from it, is autoreleased. A log
        // touched today is read from its start, and a day's logs run to hundreds of MB, so
        // without a pool per chunk all of it stays in memory until the whole count ends.
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: Self.chunk), !chunk.isEmpty else { return false }
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 10) else { return true }
            count(pending[..<lastNewline], days: days, midnight: midnight, iso: iso)
            offset += UInt64(lastNewline - pending.startIndex + 1)
            pending = Data(pending[(lastNewline + 1)...])
            return true
        }) {}
        return offset
    }

    /// Adds the usage on lines stamped today. memmem finds today's lines by their
    /// timestamp, so older lines are never split out or parsed.
    private func count(_ data: Data, days: [Data], midnight: Date, iso: ISO8601DateFormatter) {
        var lines: [Range<Int>] = []
        var starts = Set<Int>()
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buffer.count
            for day in days {
                day.withUnsafeBytes { needle in
                    var position = 0
                    while position < count, let match = memmem(base + position, count - position, needle.baseAddress, needle.count) {
                        let at = base.distance(to: match.assumingMemoryBound(to: UInt8.self))
                        var lineStart = at
                        while lineStart > position, base[lineStart - 1] != 10 { lineStart -= 1 }
                        let lineEnd = memchr(base + at, 10, count - at).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                        if starts.insert(lineStart).inserted { lines.append(lineStart..<lineEnd) }
                        position = lineEnd + 1
                    }
                }
            }
        }
        for range in lines {
            let line = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            guard line.count > 40, line.range(of: Self.usage) != nil,
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
