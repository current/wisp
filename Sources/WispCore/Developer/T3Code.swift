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
    struct Hit: Equatable {
        var updated: Date
        var windows: [ClaudeStatusLine.Record.Window]
    }

    static let maxFiles = 32
    static let tailBytes: UInt64 = 524_288
    static let maxAge: TimeInterval = 8 * 86_400
    static let marker = Data(#""payload":{"type":"rate_limit_event""#.utf8)

    /// The newest figures for each Claude instance T3 Code has logged in the last 8 days.
    public static func read(home: String = NSHomeDirectory(), now: Date = Date()) -> [Account] {
        let root = home + "/.t3/userdata"
        let instances = claudeInstances(settings: root + "/settings.json", home: home)
        var best: [String: Hit] = [:]
        for log in recentLogs(root + "/logs/provider", now: now) {
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

    /// Claude instances in T3 Code's settings, by id, with the config folder each one uses.
    /// The built-in "claudeAgent" instance uses ~/.claude even when settings never mention it.
    static func claudeInstances(settings path: String, home: String) -> [String: (folder: String, label: String?)] {
        var found: [String: (folder: String, label: String?)] = ["claudeAgent": (home + "/.claude", nil)]
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = json["providerInstances"] as? [String: Any] else { return found }
        for (id, value) in instances {
            guard let instance = value as? [String: Any], instance["driver"] as? String == "claudeAgent" else { continue }
            let config = instance["config"] as? [String: Any]
            var folder = (config?["homePath"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
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
        return Array(logs.sorted { $0.modified > $1.modified }.prefix(maxFiles))
    }

    private static let lock = NSLock()
    private static var cache: [String: (log: Log, hits: [String: Hit])] = [:]

    /// The newest hit per instance in the log's tail, remembered until the file changes.
    static func hits(in log: Log) -> [String: Hit] {
        lock.lock()
        if let cached = cache[log.path], cached.log == log {
            lock.unlock()
            return cached.hits
        }
        lock.unlock()
        let found = scan(log.path)
        lock.lock()
        cache[log.path] = (log, found)
        lock.unlock()
        return found
    }

    static func scan(_ path: String) -> [String: Hit] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return [:] }
        var found: [String: Hit] = [:]
        for line in data.split(separator: 10).reversed() where line.range(of: marker) != nil {
            guard let (instance, hit) = parse(line: line), found[instance] == nil else { continue }
            found[instance] = hit
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
