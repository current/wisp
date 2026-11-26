import Foundation

/// What the live limit checks share. Each agent is asked by its own program (Claude Code,
/// `codex app-server`, the Antigravity CLI) with its own sign-in: Wisp starts the program,
/// reads the answer and stops it, and never reads a sign-in or contacts anyone itself.
public enum LiveCheck {
    /// The first of `names` found in the usual install folders or on PATH. A Mac app
    /// starts with a short PATH, so the usual folders come first.
    static func binary(_ names: [String], home: String = NSHomeDirectory(), extra: [String] = []) -> String? {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin",
                       home + "/Library/pnpm", home + "/.bun/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = names.flatMap { name in folders.map { $0 + "/" + name } } + extra
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Wisp's own environment without what would point a program at another account or
    /// provider: a parent Claude Code session's config folder, API keys, proxies.
    static func environment(setting extra: [String: String] = [:], home: String = NSHomeDirectory()) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key == "CLAUDECODE" || key == "CODEX_HOME"
              || ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "AGY_ACCOUNT"].contains(key)
              || key.hasPrefix("ANTIGRAVITY_"))
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", path].joined(separator: ":")
        environment["HOME"] = home
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["NO_COLOR"] = "1"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Runs a program, writes `input`, and hands each line it prints to `answer` until one
    /// gives a value, the program ends or `timeout` passes. The program is stopped then.
    static func run<T>(_ executable: String, _ arguments: [String], environment: [String: String],
                       directory: URL? = nil, input: Data = Data(), closeInput: Bool = false,
                       timeout: TimeInterval = 20, answer: @escaping (Data) -> T?) -> T? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            process.currentDirectoryURL = directory
        }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var result: T?
        var finished = false
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            if chunk.isEmpty {
                // The program ended: a last line without a newline still counts.
                if !buffer.isEmpty { result = answer(buffer) }
                finished = true
                done.signal()
                return
            }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer.removeSubrange(buffer.startIndex...end)
                if let found = answer(line) {
                    result = found
                    finished = true
                    done.signal()
                    return
                }
            }
        }
        do { try process.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if !input.isEmpty { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        if closeInput { try? stdin.fileHandleForWriting.close() }
        _ = done.wait(timeout: .now() + timeout)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // A program that ignores SIGTERM for two seconds is killed.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    // MARK: Pacing

    /// How long a saved answer serves. A look (the dropdown or the Coding Agents page
    /// opening) asks once `maxAge` has passed; the menu bar's own checks wait longer while
    /// an account's figures stay the same, doubling from `maxAge` to 30 minutes, since
    /// each check starts a program.
    public static func interval(maxAge: TimeInterval, unchanged: Int, paced: Bool) -> TimeInterval {
        guard paced, maxAge.isFinite else { return maxAge }
        return min(maxAge * pow(2, Double(min(max(unchanged, 0), 5))), max(maxAge, 1800))
    }

    /// True when two answers show the same: the same limits, within half a percent, and
    /// resets within two minutes (some services move theirs by a second on each answer).
    static func same(_ a: [ClaudeStatusLine.Record.Window], _ b: [ClaudeStatusLine.Record.Window]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            guard x.name == y.name, abs(x.used - y.used) < 0.005 else { return false }
            switch (x.resets, y.resets) {
            case (nil, nil): return true
            case let (l?, r?): return abs(l.timeIntervalSince(r)) < 120
            default: return false
            }
        }
    }

    /// How many checks in a row the figures stayed the same, with `next` counted.
    static func unchanged(previous: [ClaudeStatusLine.Record.Window]?, count: Int?, next: [ClaudeStatusLine.Record.Window]) -> Int {
        guard let previous, same(previous, next) else { return 0 }
        return (count ?? 0) + 1
    }

    // MARK: Answers

    /// "2026-12-01T00:59:59.596745+00:00", "2026-11-26T18:25:41Z": any number of second
    /// fractions. The Unix epoch, which some services send for a limit not started, is nil.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return number.doubleValue > 946_684_800 ? Date(timeIntervalSince1970: number.doubleValue) : nil }
        guard var text = value as? String, !text.isEmpty else { return nil }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) { text.removeSubrange(range) }
        let date = ISO8601DateFormatter().date(from: text)
        return date.flatMap { $0.timeIntervalSince1970 > 946_684_800 ? $0 : nil }
    }

    static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    static func json(_ line: Data) -> [String: Any]? {
        guard line.first == UInt8(ascii: "{") else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func save<T: Encodable>(_ value: T, as name: String, store: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? data.write(to: store.appendingPathComponent(name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String, store: URL) -> T? {
        guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(name).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    // MARK: One question at a time

    private static let lock = NSLock()
    nonisolated(unsafe) private static var asking = Set<String>()
    nonisolated(unsafe) private static var failures: [String: Date] = [:]

    /// A question that got no answer (offline, signed out, a program that hung) is not
    /// asked again for ten minutes, so the menu bar's minute timer does not start a
    /// program every minute.
    static func failed(_ key: String, now: Date = Date()) {
        lock.lock()
        failures[key] = now
        lock.unlock()
    }

    static func failedRecently(_ key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = failures[key] else { return false }
        if now.timeIntervalSince(at) < 600 { return true }
        failures[key] = nil
        return false
    }

    /// Forgets failures, for tests.
    static func forgetFailures() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
    }

    /// Runs `body` unless the same question is being asked already (the menu bar and the
    /// Coding Agents page both refresh), in which case that answer is left to come.
    static func once(_ key: String, _ body: () -> Void) {
        lock.lock()
        let mine = asking.insert(key).inserted
        lock.unlock()
        guard mine else { return }
        defer { lock.lock(); asking.remove(key); lock.unlock() }
        body()
    }
}
