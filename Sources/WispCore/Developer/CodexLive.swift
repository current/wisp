import Foundation

/// Asks Codex itself for an account's current limits. Codex writes its limits into
/// session logs only while it works on this Mac, so work done in the Codex app's cloud
/// tasks or on another machine never reaches them. `codex app-server` answers
/// `account/rateLimits/read` with the figures OpenAI holds now. Codex makes that
/// request with its own sign-in; Wisp starts the program and reads the answer, and
/// never reads the sign-in itself.
public enum CodexLive {
    /// One answer, kept in the plan-limits folder so every read can use it.
    struct Record: Codable, Equatable {
        var folder: String
        var updated: Date
        var accountID: String?
        var plan: String?
        var windows: [ClaudeStatusLine.Record.Window]
        /// Checks in a row that answered the same, which spaces the next ones out.
        var unchanged: Int?
    }

    /// The codex program, or the one inside the Codex app.
    static func binary(home: String = NSHomeDirectory()) -> String? {
        LiveCheck.binary(["codex"], home: home, extra: ["/Applications/Codex.app/Contents/Resources/codex"])
    }

    static func fileName(folder: String) -> String {
        var name = (folder as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        return "live-" + (name.isEmpty ? "codex" : name) + ".json"
    }

    static func saved(folder: String, store: URL) -> Record? {
        guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(fileName(folder: folder)).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }

    static func save(_ record: Record, store: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? data.write(to: store.appendingPathComponent(fileName(folder: record.folder)), options: .atomic)
    }

    /// Asks again for each signed-in Codex folder whose saved answer is older than
    /// `maxAge` (spaced out while the figures stay the same when `paced`). Folders that
    /// share one sign-in file are asked once; a sign-in whose last question failed waits
    /// ten minutes.
    public static func refresh(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store,
                               maxAge: TimeInterval, paced: Bool = false, now: Date = Date()) {
        guard let codex = binary(home: home) else { return }
        var asked = Set<String>()
        for folder in PlanUsageReader.codexFolders(home: home) {
            let auth = folder + "/auth.json"
            guard FileManager.default.fileExists(atPath: auth) else { continue }
            // T3 Code's ~/.codex-t3/auth.json links to ~/.codex's: one account, one question.
            let signIn = (auth as NSString).resolvingSymlinksInPath
            guard asked.insert(signIn).inserted else { continue }
            let previous = saved(folder: folder, store: store)
            if let previous, now.timeIntervalSince(previous.updated) < LiveCheck.interval(maxAge: maxAge, unchanged: previous.unchanged ?? 0, paced: paced) { continue }
            let key = "codex:" + signIn
            if LiveCheck.failedRecently(key, now: now) { continue }
            LiveCheck.once(key) {
                guard let answer = ask(codex: codex, folder: folder, home: home) else { return LiveCheck.failed(key, now: now) }
                var next = record(answer, folder: folder, now: now)
                next.unchanged = LiveCheck.unchanged(previous: previous?.windows, count: previous?.unchanged, next: next.windows)
                save(next, store: store)
            }
        }
    }

    static func record(_ result: [String: Any], folder: String, now: Date) -> Record {
        let limits = result["rateLimits"] as? [String: Any] ?? [:]
        var windows: [ClaudeStatusLine.Record.Window] = []
        for (key, fallback) in [("primary", "5-hour session"), ("secondary", "This week")] {
            guard let item = limits[key] as? [String: Any], let percent = (item["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let name = PlanUsageReader.windowName(minutes: (item["windowDurationMins"] as? NSNumber)?.doubleValue) ?? fallback
            windows.append(.init(name: name, used: percent / 100,
                                 resets: (item["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
        }
        return Record(folder: folder, updated: now, accountID: result["accountId"] as? String,
                      plan: (limits["planType"] as? String)?.capitalized, windows: windows)
    }

    /// Starts `codex app-server` for one folder, asks for the limits and stops it.
    /// Gives up after `timeout` seconds, as when Codex is signed out or offline.
    static func ask(codex: String, folder: String, home: String = NSHomeDirectory(), timeout: TimeInterval = 20) -> [String: Any]? {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"wisp","version":"\#(Wisp.version)"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
        ]
        let answer: [String: Any]? = LiveCheck.run(
            codex, ["app-server"], environment: LiveCheck.environment(setting: ["CODEX_HOME": folder], home: home),
            input: Data((requests.joined(separator: "\n") + "\n").utf8), timeout: timeout
        ) { line in
            guard let json = LiveCheck.json(line), (json["id"] as? NSNumber)?.intValue == 2 else { return nil }
            return json["result"] as? [String: Any] ?? [:]
        }
        guard let answer, answer["rateLimits"] != nil else { return nil }
        return answer
    }
}
