import Foundation

/// Plan limits for Claude accounts used through T3 Code. T3 Code runs Claude through the
/// Agent SDK, which never runs the status line, but it logs every `rate_limit_event` the
/// SDK passes on to ~/.t3/userdata/logs/provider/events.<thread>.log.
public enum T3CodeLimits {
    public struct Account: Equatable, Sendable {
        /// The instance's name in T3 Code, such as "Claude (alt)".
        public var label: String?
        public var record: ClaudeStatusLine.Record
    }

    /// One instance's figures as of one log line.
    struct Hit: Equatable, Codable {
        var updated: Date
        var windows: [ClaudeStatusLine.Record.Window]
    }

    /// A file seen for the first time is read this far back from its end; after that,
    /// only what it gained since.
    static let tailBytes: UInt64 = 2_097_152
    static let maxAge: TimeInterval = 8 * 86_400
    static let marker = Data(#""payload":{"type":"rate_limit_event""#.utf8)

    /// The newest figures for each Claude instance T3 Code has logged in the last 8 days.
    /// T3 Code writes a log per thread, often well over a hundred a day, so every recent
    /// log is read once and what it held is kept in `cacheFile`; after that only what a
    /// log gained is read.
    public static func read(home: String = NSHomeDirectory(), now: Date = Date(), cacheFile: URL? = nil) -> [Account] {
        let root = home + "/.t3/userdata"
        let instances = claudeInstances(settings: root + "/settings.json", home: home)
        let logs = recentLogs(root + "/logs/provider", now: now)
        if let cacheFile { loadCache(cacheFile) }
        defer { if let cacheFile { saveCache(cacheFile, keeping: Set(logs.map(\.path))) } }
        var best: [String: Hit] = [:]
        for log in logs {
            // A log last written before every instance's best line cannot hold a newer one.
            if instances.keys.allSatisfy({ (best[$0]?.updated ?? .distantPast) >= log.modified }) { break }
            for (instance, hit) in hits(in: log) where instances[instance] != nil {
                if let known = best[instance], known.updated >= hit.updated { continue }
                best[instance] = hit
            }
        }
        return best.compactMap { instance, hit in
            guard let (folder, label) = instances[instance] else { return nil }
            return Account(label: label, record: .init(folder: folder, updated: hit.updated, windows: hit.windows))
        }.sorted { $0.record.folder < $1.record.folder }
    }

    /// The names T3 Code gives its Claude and Codex accounts ("Claude (alt)"), by config folder.
    public static func labels(home: String = NSHomeDirectory()) -> [String: String] {
        let path = home + "/.t3/userdata/settings.json"
        var found: [String: String] = [:]
        for driver in ["claudeAgent", "codex"] {
            for (_, instance) in instances(settings: path, home: home, driver: driver) {
                if let label = instance.label { found[instance.folder] = label }
            }
        }
        return found
    }

    /// Claude instances in T3 Code's settings, by id, with the config folder each one uses.
    /// The built-in "claudeAgent" instance uses ~/.claude even when settings never mention it.
    static func claudeInstances(settings path: String, home: String) -> [String: (folder: String, label: String?)] {
        instances(settings: path, home: home, driver: "claudeAgent")
    }

    static func instances(settings path: String, home: String, driver: String) -> [String: (folder: String, label: String?)] {
        let fallback = home + (driver == "codex" ? "/.codex" : "/.claude")
        var found: [String: (folder: String, label: String?)] = driver == "claudeAgent" ? ["claudeAgent": (fallback, nil)] : [:]
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = json["providerInstances"] as? [String: Any] else { return found }
        for (id, value) in instances {
            guard let instance = value as? [String: Any], instance["driver"] as? String == driver else { continue }
            let config = instance["config"] as? [String: Any]
            var folder = (config?["homePath"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            if folder.hasPrefix("~/") { folder = home + folder.dropFirst() }
            while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
            found[id] = (folder, instance["displayName"] as? String)
        }
        return found
    }

    struct Log: Equatable {
        var path: String
        var modified: Date
        var size: UInt64
    }

    /// events.*.log and their rotations (.log.1 ...), newest first.
    static func recentLogs(_ folder: String, now: Date) -> [Log] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        let logs: [Log] = names.compactMap { name in
            guard name.hasPrefix("events."), name.hasSuffix(".log") || name.range(of: #"\.log\.\d+$"#, options: .regularExpression) != nil else { return nil }
            let path = folder + "/" + name
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) < maxAge else { return nil }
            return Log(path: path, modified: modified, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        return logs.sorted { $0.modified > $1.modified }
    }

    private static let lock = NSLock()
    private static var cache: [String: (log: Log, hits: [String: Hit])] = [:]
    private static var cacheLoaded = false
    private static var cacheDirty = false

    private struct SavedLog: Codable {
        var path: String
        var modified: Date
        var size: UInt64
        var hits: [String: Hit]
    }

    static func loadCache(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([SavedLog].self, from: data) else { return }
        for entry in saved where cache[entry.path] == nil {
            cache[entry.path] = (Log(path: entry.path, modified: entry.modified, size: entry.size), entry.hits)
        }
    }

    /// Writes what the logs held, for the logs still recent, when anything was read.
    static func saveCache(_ url: URL, keeping paths: Set<String>) {
        lock.lock()
        guard cacheDirty else { return lock.unlock() }
        cacheDirty = false
        cache = cache.filter { paths.contains($0.key) }
        let saved = cache.values.map { SavedLog(path: $0.log.path, modified: $0.log.modified, size: $0.log.size, hits: $0.hits) }
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    /// The newest hit per instance in the log. A file that grew is read from where the
    /// last read stopped and its earlier hits kept, so an instance's last event does not
    /// drop out of view as the file grows past it.
    static func hits(in log: Log) -> [String: Hit] {
        lock.lock()
        let cached = cache[log.path]
        lock.unlock()
        if let cached, cached.log == log { return cached.hits }
        var found: [String: Hit]
        if let cached, log.size >= cached.log.size {
            found = cached.hits
            // A little before the old end, in case the last line was still being written.
            let start = cached.log.size > 4096 ? cached.log.size - 4096 : 0
            for (instance, hit) in scan(log.path, from: start) where (found[instance]?.updated ?? .distantPast) < hit.updated {
                found[instance] = hit
            }
        } else {
            found = scan(log.path, from: log.size > tailBytes ? log.size - tailBytes : 0)
        }
        lock.lock()
        cache[log.path] = (log, found)
        cacheDirty = true
        lock.unlock()
        return found
    }

    static func scan(_ path: String, from offset: UInt64 = 0) -> [String: Hit] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [:] }
        var found: [String: Hit] = [:]
        // memmem finds the few event lines in megabytes of log without splitting it into lines.
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = buffer.count
            marker.withUnsafeBytes { needle in
                var position = 0
                while position < count,
                      let match = memmem(bytes + position, count - position, needle.baseAddress, needle.count) {
                    let at = bytes.distance(to: match.assumingMemoryBound(to: UInt8.self))
                    var lineStart = at
                    while lineStart > 0, bytes[lineStart - 1] != 10 { lineStart -= 1 }
                    var lineEnd = at
                    while lineEnd < count, bytes[lineEnd] != 10 { lineEnd += 1 }
                    if let (instance, hit) = parse(line: data[lineStart..<lineEnd]),
                       (found[instance]?.updated ?? .distantPast) < hit.updated {
                        found[instance] = hit
                    }
                    position = lineEnd + 1
                }
            }
        }
        return found
    }

    /// One log line: `[2026-11-18T15:19:08.803Z] NTIVE: {"provider":"claudeAgent",...}`.
    static func parse(line: Data.SubSequence) -> (instance: String, hit: Hit)? {
        guard line.first == UInt8(ascii: "["), let close = line.firstIndex(of: UInt8(ascii: "]")),
              let brace = line[close...].firstIndex(of: UInt8(ascii: "{")),
              let updated = date(String(decoding: line[line.index(after: line.startIndex)..<close], as: UTF8.self)),
              let json = try? JSONSerialization.jsonObject(with: Data(line[brace...])) as? [String: Any],
              json["provider"] as? String == "claudeAgent",
              let session = json["providerSessionId"] as? String,
              let start = session.range(of: "provider-instance:")?.upperBound,
              let event = json["event"] as? [String: Any], let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "rate_limit_event",
              let info = payload["rate_limit_info"] as? [String: Any] else { return nil }
        let instance = String(session[start...].prefix { $0 != ":" })
        guard !instance.isEmpty else { return nil }
        // Older SDKs report only the window that triggered the event, at the top level.
        let unified = info["unifiedWindows"] as? [String: Any]
            ?? (info["rateLimitType"] as? String).map { [$0: info] } ?? [:]
        var windows: [ClaudeStatusLine.Record.Window] = []
        for (key, name) in [("five_hour", "5-hour session"), ("seven_day", "This week")] {
            guard let item = unified[key] as? [String: Any], let used = item["utilization"] as? Double else { continue }
            windows.append(.init(name: name, used: used, resets: (item["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))))
        }
        return windows.isEmpty ? nil : (instance, Hit(updated: updated, windows: windows))
    }

    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}
