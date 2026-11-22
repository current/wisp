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
    }

    /// Where the codex program usually is. A Mac app starts with a short PATH, so the
    /// usual install folders are tried as well.
    static func binary(home: String = NSHomeDirectory()) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        let usual = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                     home + "/.npm-global/bin/codex", home + "/Library/pnpm/codex",
                     "/Applications/Codex.app/Contents/Resources/codex"]
        return (path + usual).first { FileManager.default.isExecutableFile(atPath: $0) }
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
    /// `maxAge`. Folders that share one sign-in file are asked once.
    public static func refresh(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store,
                               maxAge: TimeInterval, now: Date = Date()) {
        guard let codex = binary(home: home) else { return }
        var asked = Set<String>()
        for folder in PlanUsageReader.codexFolders(home: home) {
            let auth = folder + "/auth.json"
            guard FileManager.default.fileExists(atPath: auth) else { continue }
            // T3 Code's ~/.codex-t3/auth.json links to ~/.codex's: one account, one question.
            let signIn = (auth as NSString).resolvingSymlinksInPath
            guard asked.insert(signIn).inserted else { continue }
            if let saved = saved(folder: folder, store: store), now.timeIntervalSince(saved.updated) < maxAge { continue }
            guard let answer = ask(codex: codex, folder: folder) else { continue }
            save(record(answer, folder: folder, now: now), store: store)
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
    static func ask(codex: String, folder: String, timeout: TimeInterval = 20) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = folder
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var answer: [String: Any]?
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            guard answer == nil else { return }
            if chunk.isEmpty { done.signal(); return }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (json["id"] as? NSNumber)?.intValue == 2 else { continue }
                answer = json["result"] as? [String: Any] ?? [:]
                done.signal()
                return
            }
        }
        do { try process.run() } catch { return nil }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"wisp","version":"\#(Wisp.version)"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
        ]
        try? input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        _ = done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.lock()
        defer { lock.unlock() }
        guard let answer, answer["rateLimits"] != nil else { return nil }
        return answer
    }
}
