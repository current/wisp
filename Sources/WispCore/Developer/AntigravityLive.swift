import Foundation

/// Asks Antigravity for its plan limits. The Antigravity CLI answers `agy -p /usage`
/// without starting an agent turn, spending quota or keeping a conversation, with each
/// model group's 5-hour and weekly limit; Wisp runs it, reads the answer and stops it.
/// Without the CLI, the Antigravity app's language server answers on 127.0.0.1 while the
/// app runs: it writes its port and a per-run token to ~/.gemini/antigravity/daemon/
/// hub_<port>.json, and answers `RetrieveUserQuotaSummary` and `GetUserStatus`. Either
/// way Antigravity asks with its own sign-in, which Wisp never reads.
public enum AntigravityLive {
    struct Record: Codable, Equatable {
        var updated: Date
        var account: String?
        var plan: String?
        var windows: [ClaudeStatusLine.Record.Window]
        /// Checks in a row that answered the same, which spaces the next ones out.
        var unchanged: Int?
    }

    struct Hub: Decodable {
        var pid: Int32
        var httpPort: Int
        var csrfToken: String
    }

    static let fileName = "live-antigravity.json"

    /// A running language server: its local HTTP port, and the token it asks for.
    struct Server: Equatable {
        var port: Int
        var token: String?
    }

    /// The Antigravity CLI.
    static func binary(home: String = NSHomeDirectory()) -> String? {
        LiveCheck.binary(["agy"], home: home, extra: ["/Applications/Antigravity.app/Contents/Resources/app/bin/agy"])
    }

    /// The signed-in Google account, from the account list Antigravity keeps beside its
    /// settings (addresses only; the sign-in is elsewhere).
    static func account(home: String) -> String? {
        let path = home + "/.gemini/google_accounts.json"
        return FileCache.value(path, kind: "agy-account") {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let active = json["active"] as? String, !active.isEmpty else { return nil }
            return active
        }
    }

    /// The running language server's hub file, newest first when there are several.
    static func hub(home: String) -> Hub? {
        let folder = home + "/.gemini/antigravity/daemon"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix("hub_") && $0.hasSuffix(".json") }
            .map { folder + "/" + $0 }
        let dated = files.map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
        for (path, _) in dated.sorted(by: { $0.1 > $1.1 }) {
            guard let data = FileManager.default.contents(atPath: path),
                  let hub = try? JSONDecoder().decode(Hub.self, from: data) else { continue }
            // A crashed server leaves its file behind.
            if kill(hub.pid, 0) == 0 { return hub }
        }
        return nil
    }

    /// True once Antigravity has answered on this Mac.
    public static func seen(store: URL = ClaudeStatusLine.store) -> Bool {
        FileManager.default.fileExists(atPath: store.appendingPathComponent(fileName).path)
    }

    static func saved(store: URL) -> Record? { LiveCheck.load(Record.self, name: fileName, store: store) }

    static func save(_ record: Record, store: URL) { LiveCheck.save(record, as: fileName, store: store) }

    /// Asks again when the saved answer is older than `maxAge` (spaced out while the
    /// figures stay the same when `paced`): the CLI when it is installed, otherwise the
    /// app's server while it runs. `ask` stands in for the CLI in tests.
    public static func refresh(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store,
                               maxAge: TimeInterval, paced: Bool = false, now: Date = Date(),
                               ask: ((String) -> [ClaudeStatusLine.Record.Window]?)? = nil) {
        let previous = saved(store: store)
        if let previous, now.timeIntervalSince(previous.updated) < LiveCheck.interval(maxAge: maxAge, unchanged: previous.unchanged ?? 0, paced: paced) { return }
        if LiveCheck.failedRecently("antigravity", now: now) { return }
        LiveCheck.once("antigravity") {
            var record: Record?
            let agy = binary(home: home) ?? (ask == nil ? nil : "agy")
            let running = ask == nil ? hub(home: home) : nil
            // Neither is there: nothing to ask, and nothing failed.
            if agy == nil && running == nil { return }
            if let agy, let windows = ask.map({ $0(agy) }) ?? askCLI(agy, home: home, store: store) {
                record = Record(updated: now, account: account(home: home) ?? previous?.account, plan: previous?.plan, windows: windows)
            }
            // The app's own server answers while it runs: the fallback when the CLI did not,
            // and the only place the plan's name comes from.
            if let hub = running, record == nil || record?.plan == nil {
                let server = Server(port: hub.httpPort, token: hub.csrfToken)
                if let status = self.ask(server), var found = self.record(status, now: now) {
                    if let record {
                        found.windows = record.windows
                    } else if let summary = self.ask(server, method: "RetrieveUserQuotaSummary"), let windows = windows(summary) {
                        found.windows = windows
                    }
                    record = found
                }
            }
            guard var record else { return LiveCheck.failed("antigravity", now: now) }
            record.unchanged = LiveCheck.unchanged(previous: previous?.windows, count: previous?.unchanged, next: record.windows)
            save(record, store: store)
        }
    }

    /// `agy -p /usage --output-format json`, its log kept out of Antigravity's log folder.
    static func askCLI(_ agy: String, home: String, store: URL) -> [ClaudeStatusLine.Record.Window]? {
        let answer: [ClaudeStatusLine.Record.Window]?? = LiveCheck.run(
            agy, ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null", "--print-timeout", "20s"],
            environment: LiveCheck.environment(home: home), directory: store, closeInput: true, timeout: 30
        ) { line in
            guard let json = LiveCheck.json(line), json["status"] != nil || json["command"] != nil else { return nil }
            return .some(cliWindows(json))
        }
        return answer ?? nil
    }

    /// The CLI's answer: `command.data.groups[].buckets[]` with `id`, `window`,
    /// `remaining_fraction` and `reset_time`, or failing that the tab-separated lines of
    /// `response` ("Gemini Models\tFive Hour Limit Remaining\t98%\t2026-11-26T18:25:41Z").
    static func cliWindows(_ json: [String: Any]) -> [ClaudeStatusLine.Record.Window]? {
        let data = (json["command"] as? [String: Any])?["data"] as? [String: Any]
        if let groups = data?["groups"] as? [[String: Any]] {
            let converted: [[String: Any]] = groups.map { group in
                ["displayName": group["name"] ?? "", "buckets": (group["buckets"] as? [[String: Any]] ?? []).map { bucket in
                    ["bucketId": bucket["id"] ?? "", "window": bucket["window"] ?? "",
                     "remainingFraction": bucket["remaining_fraction"] ?? 0, "resetTime": bucket["reset_time"] ?? ""] as [String: Any]
                }]
            }
            if let windows = windows(["response": ["groups": converted]]) { return windows }
        }
        guard let text = json["response"] as? String else { return nil }
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, let percent = Double(fields[2].replacingOccurrences(of: "%", with: "")) else { continue }
            let window = fields[1].lowercased().contains("five hour") || fields[1].lowercased().contains("5-hour") ? "5h"
                : fields[1].lowercased().contains("week") ? "weekly" : ""
            let id = (fields[0].lowercased().hasPrefix("gemini") ? "gemini-" : "3p-") + window
            if groups[fields[0]] == nil { order.append(fields[0]) }
            groups[fields[0], default: []].append(["bucketId": id, "window": window, "remainingFraction": percent / 100,
                                                   "resetTime": fields.count > 3 ? fields[3] : ""])
        }
        return windows(["response": ["groups": order.map { ["displayName": $0, "buckets": groups[$0] ?? []] as [String: Any] }]])
    }

    /// The limits AI usage can show, in order, with their names in Settings.
    public static let limits: [(name: String, title: String)] = [
        ("5-hour Gemini", "Gemini, 5-hour"),
        ("Gemini this week", "Gemini, weekly"),
        ("5-hour Claude and GPT-OSS", "Claude and GPT-OSS, 5-hour"),
        ("Claude and GPT-OSS this week", "Claude and GPT-OSS, weekly"),
    ]

    /// `RetrieveUserQuotaSummary` has each model group's 5-hour and weekly limit, which
    /// `GetUserStatus` folds into one figure per model. Servers older than it answer nothing.
    static func windows(_ summary: [String: Any]) -> [ClaudeStatusLine.Record.Window]? {
        let groups = (summary["response"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        var windows: [ClaudeStatusLine.Record.Window] = []
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                let id = bucket["bucketId"] as? String ?? ""
                let models = id.hasPrefix("gemini") ? "Gemini" : id.hasPrefix("3p") ? "Claude and GPT-OSS"
                    : (group["displayName"] as? String ?? "Other").replacingOccurrences(of: " Models", with: "").replacingOccurrences(of: " models", with: "")
                let name: String
                switch bucket["window"] as? String {
                case "5h": name = "5-hour " + models
                case "weekly": name = models + " this week"
                default: continue
                }
                let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
                windows.append(.init(name: name, used: min(max(1 - remaining, 0), 1),
                                     resets: LiveCheck.date(bucket["resetTime"])))
            }
        }
        // Each group's 5-hour limit before its weekly one.
        let order = { (name: String) in limits.firstIndex { $0.name == name } ?? limits.count }
        return windows.isEmpty ? nil : windows.enumerated().sorted { (order($0.element.name), $0.offset) < (order($1.element.name), $1.offset) }.map(\.element)
    }

    /// Models share quota pools: every Gemini model draws on one, Claude and GPT-OSS on
    /// another. Models with the same remaining fraction and reset time are one window.
    static func record(_ status: [String: Any], now: Date) -> Record? {
        guard let user = status["userStatus"] as? [String: Any] else { return nil }
        let configs = (user["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        var pools: [(remaining: Double, resets: Date?, vendors: [String])] = []
        for config in configs {
            guard let quota = config["quotaInfo"] as? [String: Any],
                  let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue ?? (quota["resetTime"] != nil ? 0 : nil) else { continue }
            let resets = (quota["resetTime"] as? String).flatMap(iso.date(from:))
            let vendor = vendorName(config)
            if let index = pools.firstIndex(where: { $0.remaining == remaining && $0.resets == resets }) {
                if !pools[index].vendors.contains(vendor) { pools[index].vendors.append(vendor) }
            } else {
                pools.append((remaining, resets, [vendor]))
            }
        }
        guard !pools.isEmpty else { return nil }
        let windows = pools.map { pool -> ClaudeStatusLine.Record.Window in
            let models = pool.vendors.joined(separator: " and ")
            // Paid plans refill every 5 hours; a reset further out is the weekly limit.
            let fiveHour = pool.resets.map { $0.timeIntervalSince(now) <= 5 * 3600 + 300 } ?? true
            return .init(name: fiveHour ? "5-hour " + models : models + " this week",
                         used: min(max(1 - pool.remaining, 0), 1), resets: pool.resets)
        }
        let tier = (user["userTier"] as? [String: Any])?["name"] as? String
        let planInfo = ((user["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        return Record(updated: now, account: user["email"] as? String, plan: tier ?? planInfo, windows: windows)
    }

    /// The plan as the other accounts name theirs: "Google AI Ultra" is "Ultra", as
    /// Claude's is "Max" and Codex's "Plus".
    static func planName(_ plan: String) -> String {
        plan.hasPrefix("Google AI ") ? String(plan.dropFirst("Google AI ".count)) : plan
    }

    /// "Gemini" for every Gemini model and orchestrator, otherwise the label's first word
    /// ("Claude", "GPT-OSS").
    static func vendorName(_ config: [String: Any]) -> String {
        let id = (config["modelId"] as? String ?? "").lowercased()
        if id.hasPrefix("gemini") { return "Gemini" }
        let label = config["label"] as? String ?? id
        return label.split(separator: " ").first.map(String.init) ?? "Other"
    }

    static func ask(_ server: Server, method: String = "GetUserStatus", timeout: TimeInterval = 5) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(server.port)/exa.language_server_pb.LanguageServerService/" + method) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = server.token { request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return answer
    }
}
