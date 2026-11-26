import Foundation

/// Asks Claude Code for an account's plan limits. Claude Code answers the `get_usage`
/// request of its stream-json protocol from claude.ai with the figures for the whole
/// account, wherever it was used: in a terminal, in T3 Code, on another machine or on
/// the web. The request runs no model turn and costs nothing. Wisp starts `claude -p`
/// for each signed-in config folder with hooks, MCP servers, slash commands and session
/// saving off, asks, and stops it; Claude Code uses its own sign-in, which Wisp never reads.
public enum ClaudeLive {
    /// One answer, kept in the plan-limits folder so every read can use it.
    struct Record: Codable, Equatable {
        var folder: String
        var updated: Date
        var plan: String?
        var windows: [ClaudeStatusLine.Record.Window]
        /// False when the folder's Claude Code has no plan limits to show: signed out, or
        /// on an API key, Bedrock or Vertex.
        var available: Bool
        /// Checks in a row that answered the same, which spaces the next ones out.
        var unchanged: Int?
    }

    /// What one question found.
    struct Answer: Equatable {
        var plan: String?
        var windows: [ClaudeStatusLine.Record.Window]
        var available: Bool
    }

    static func fileName(folder: String) -> String { "live-" + ClaudeStatusLine.fileName(folder: folder) }

    static func saved(folder: String, store: URL) -> Record? {
        LiveCheck.load(Record.self, name: fileName(folder: folder), store: store)
    }

    static func save(_ record: Record, store: URL) {
        LiveCheck.save(record, as: fileName(folder: record.folder), store: store)
    }

    /// The claude program. Wisp looks in the install folders before PATH, so a wrapper
    /// script earlier on a shell's PATH is not what runs.
    static func binary(home: String = NSHomeDirectory()) -> String? {
        LiveCheck.binary(["claude"], home: home, extra: [home + "/.claude/local/claude"])
    }

    /// Config folders signed in to a claude.ai account: those whose .claude.json names one.
    public static func signedIn(home: String = NSHomeDirectory()) -> [String] {
        PlanUsageReader.claudeFolders(home: home).filter { PlanUsageReader.claudeAccount(folder: $0, home: home).email != nil }
    }

    /// Asks again for each signed-in folder whose saved answer is older than `maxAge`
    /// (spaced out while the figures stay the same when `paced`). A folder whose last
    /// question failed waits ten minutes, one with no plan limits an hour.
    public static func refresh(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store,
                               maxAge: TimeInterval, paced: Bool = false, now: Date = Date()) {
        check(home: home, store: store, maxAge: maxAge, paced: paced, now: now, ask: nil)
    }

    /// `refresh`, with `ask` standing in for Claude Code in tests.
    static func check(home: String, store: URL, maxAge: TimeInterval, paced: Bool, now: Date,
                      ask: ((String, String) -> Answer?)?) {
        guard let claude = binary(home: home) ?? (ask == nil ? nil : "claude") else { return }
        for folder in signedIn(home: home) {
            let previous = saved(folder: folder, store: store)
            if let previous {
                var wait = LiveCheck.interval(maxAge: maxAge, unchanged: previous.unchanged ?? 0, paced: paced)
                if !previous.available { wait = max(wait, 3600) }
                if now.timeIntervalSince(previous.updated) < wait { continue }
            }
            let key = "claude:" + folder
            if LiveCheck.failedRecently(key, now: now) { continue }
            LiveCheck.once(key) {
                let found = ask.map { $0(claude, folder) } ?? self.ask(claude: claude, folder: folder, home: home, store: store)
                guard let answer = found else { return LiveCheck.failed(key, now: now) }
                var record = Record(folder: folder, updated: now, plan: answer.plan ?? previous?.plan,
                                    windows: answer.windows, available: answer.available)
                record.unchanged = LiveCheck.unchanged(previous: previous?.windows, count: previous?.unchanged, next: answer.windows)
                save(record, store: store)
            }
        }
    }

    static let quiet = ["--no-session-persistence", "--strict-mcp-config", "--setting-sources", "project"]

    /// Asks one folder's Claude Code. The structured request comes first; a Claude Code
    /// that does not know it is asked for `/usage` as text.
    static func ask(claude: String, folder: String, home: String, store: URL) -> Answer? {
        var extra: [String: String] = [:]
        // ~/.claude is Claude Code's own default; naming it would make it another folder.
        if folder != home + "/.claude" { extra["CLAUDE_CONFIG_DIR"] = folder }
        let environment = LiveCheck.environment(setting: extra, home: home)
        let requests = [
            #"{"type":"control_request","request_id":"wisp-init","request":{"subtype":"initialize"}}"#,
            #"{"type":"control_request","request_id":"wisp-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#,
        ]
        let reply: [String: Any]?? = LiveCheck.run(
            claude, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--disable-slash-commands"] + quiet,
            environment: environment, directory: store, input: Data((requests.joined(separator: "\n") + "\n").utf8), timeout: 25
        ) { line in
            guard let json = LiveCheck.json(line), json["type"] as? String == "control_response",
                  let response = json["response"] as? [String: Any], response["request_id"] as? String == "wisp-usage" else { return nil }
            return .some(response["subtype"] as? String == "success" ? response["response"] as? [String: Any] : nil)
        }
        switch reply {
        case .some(.some(let usage)): return answer(usage)
        case .some(.none): break
        case .none: return nil
        }
        let text: String?? = LiveCheck.run(claude, ["-p", "/usage", "--output-format", "json"] + quiet,
                                            environment: environment, directory: store, closeInput: true, timeout: 25) { line in
            guard let json = LiveCheck.json(line), json["type"] as? String == "result" else { return nil }
            return .some(json["result"] as? String)
        }
        guard let text = text ?? nil else { return nil }
        let windows = windows(text: text, now: Date())
        // The text cannot tell an account without plan limits from a check that failed,
        // so no figures is a failed check: asked again in ten minutes, never hidden.
        if windows.isEmpty { return nil }
        return Answer(plan: nil, windows: windows, available: true)
    }

    /// The answer to `get_usage`. Its `limits` list names each limit; older answers have
    /// only the fixed fields (five_hour, seven_day, seven_day_sonnet...). Nil when the
    /// account has limits but claude.ai did not send them this time.
    static func answer(_ usage: [String: Any]) -> Answer? {
        let type = usage["subscription_type"] as? String
        let plan = type.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if usage["rate_limits_available"] as? Bool == false { return Answer(plan: plan, windows: [], available: false) }
        guard let limits = usage["rate_limits"] as? [String: Any] else { return nil }
        var windows: [ClaudeStatusLine.Record.Window] = []
        func add(_ name: String, _ percent: Double, _ resets: Any?) {
            guard !windows.contains(where: { $0.name == name }) else { return }
            windows.append(.init(name: name, used: min(max(percent / 100, 0), 1), resets: LiveCheck.date(resets)))
        }
        if let list = limits["limits"] as? [[String: Any]], !list.isEmpty {
            for item in list {
                guard let percent = LiveCheck.number(item["percent"]) else { continue }
                switch item["kind"] as? String {
                case "session": add("5-hour session", percent, item["resets_at"])
                case "weekly_all": add("This week", percent, item["resets_at"])
                case "weekly_scoped":
                    let model = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    // A model's own weekly limit shows once it is in use.
                    guard let model, item["is_active"] as? Bool == true || percent > 0 else { continue }
                    add(model + " this week", percent, item["resets_at"])
                default: continue
                }
            }
        } else {
            for (key, name) in [("five_hour", "5-hour session"), ("seven_day", "This week"),
                                ("seven_day_opus", "Opus this week"), ("seven_day_sonnet", "Sonnet this week")] {
                guard let item = limits[key] as? [String: Any], let percent = LiveCheck.number(item["utilization"]) else { continue }
                if key.hasPrefix("seven_day_"), percent <= 0 { continue }
                add(name, percent, item["resets_at"])
            }
        }
        // Before the first reply of a 5-hour session there is no session figure: none of it is used.
        if type == "pro" || type == "max", windows.contains(where: { $0.name == "This week" }),
           !windows.contains(where: { $0.name == "5-hour session" }) {
            windows.insert(.init(name: "5-hour session", used: 0, resets: nil), at: 0)
        }
        let order = { (name: String) in name == "5-hour session" ? 0 : name == "This week" ? 1 : 2 }
        windows = windows.enumerated().sorted { (order($0.element.name), $0.offset) < (order($1.element.name), $1.offset) }.map(\.element)
        return windows.isEmpty ? nil : Answer(plan: plan, windows: windows, available: true)
    }

    /// `/usage` as text: "Current session: 12% used · resets 7:59pm (America/Chicago)",
    /// "Current week (all models): 8% used · resets Nov 30 at 7pm (America/Chicago)".
    static func windows(text: String, now: Date) -> [ClaudeStatusLine.Record.Window] {
        let pattern = try! NSRegularExpression(pattern: #"^Current (session|week \(([^)]*)\)): (\d+(?:\.\d+)?)% used(?: · resets (.+))?$"#)
        var windows: [ClaudeStatusLine.Record.Window] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let percentRange = Range(match.range(at: 3), in: line), let percent = Double(line[percentRange]) else { continue }
            let scope = Range(match.range(at: 2), in: line).map { String(line[$0]) }
            let name: String
            switch scope {
            case nil: name = "5-hour session"
            case "all models": name = "This week"
            case let scope?:
                guard percent > 0 else { continue }
                name = scope.replacingOccurrences(of: " only", with: "") + " this week"
            }
            let resets = Range(match.range(at: 4), in: line).flatMap { resetDate(String(line[$0]), now: now) }
            windows.append(.init(name: name, used: min(percent / 100, 1), resets: resets))
        }
        if windows.contains(where: { $0.name == "This week" }), !windows.contains(where: { $0.name == "5-hour session" }) {
            windows.insert(.init(name: "5-hour session", used: 0, resets: nil), at: 0)
        }
        return windows
    }

    /// "Nov 30 at 7pm (America/Chicago)", "7:59pm (America/Chicago)": the next such time.
    static func resetDate(_ text: String, now: Date) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            zone = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) ?? zone
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.defaultDate = now
        // "7pm" reads as "7:00pm": DateFormatter cannot split an hour from its am/pm.
        text = text.lowercased().replacingOccurrences(of: #"(?<![:\d])(\d{1,2})(am|pm)\b"#, with: "$1:00$2", options: .regularExpression)
        for format in ["MMM d, yyyy 'at' h:mma", "MMM d 'at' h:mma", "h:mma", "MMM d"] {
            formatter.dateFormat = format
            guard var date = formatter.date(from: text) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            if !format.contains("MMM"), date < now.addingTimeInterval(-60) {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            } else if !format.contains("yyyy"), date < now.addingTimeInterval(-86_400) {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }
}
