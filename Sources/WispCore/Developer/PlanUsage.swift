import CryptoKit
import Foundation

/// How much of an AI plan's limits is used, per signed-in account on this Mac.
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
    /// Set when the limits could not be read, in words a person can act on.
    public var problem: String?
    public var id: String { provider + ":" + account }
}

/// Reads plan limits the way each tool does for itself: the sign-in the tool keeps
/// on this Mac, sent only to the company that issued it. Wisp never refreshes or
/// stores a sign-in; an expired one is reported so the tool can renew it.
public enum PlanUsageReader {
    /// Claude Code config folders: ~/.claude and any ~/.claude-* with a .claude.json.
    static func claudeFolders() -> [String] {
        let home = NSHomeDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0 == ".claude" || ($0.hasPrefix(".claude-") && !$0.contains(".json")) }
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0 + "/.claude.json") || $0 == home + "/.claude" }
            .sorted()
    }

    /// Claude Code names its Keychain item after the config folder, except for the default one.
    static func keychainService(for folder: String) -> String {
        if folder == NSHomeDirectory() + "/.claude" { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    /// Asks the `security` tool rather than the Keychain API. Claude Code saves its
    /// sign-in with that tool, so the item already trusts it and no prompt appears.
    static func keychainData(service: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    struct ClaudeSignIn {
        var token: String
        var expires: Date?
        var plan: String?
    }

    static func claudeSignIn(folder: String) -> ClaudeSignIn? {
        let data = keychainData(service: keychainService(for: folder))
            ?? FileManager.default.contents(atPath: folder + "/.credentials.json")
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let plan = (oauth["subscriptionType"] as? String)?.capitalized
        return ClaudeSignIn(token: token, expires: expires, plan: plan)
    }

    static func claudeEmail(folder: String) -> String? {
        let paths = folder == NSHomeDirectory() + "/.claude" ? [NSHomeDirectory() + "/.claude.json", folder + "/.claude.json"] : [folder + "/.claude.json"]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = (json["oauthAccount"] as? [String: Any])?["emailAddress"] as? String else { continue }
            return email
        }
        return nil
    }

    /// Every account, read in parallel. Takes as long as the slowest request, a second or two.
    public static func readAll() async -> [PlanUsage] {
        await withTaskGroup(of: PlanUsage?.self) { group in
            var seen = Set<String>()
            for folder in claudeFolders() {
                let email = claudeEmail(folder: folder) ?? (folder as NSString).lastPathComponent
                guard seen.insert("claude:" + email).inserted else { continue }
                group.addTask { await claude(folder: folder, account: email) }
            }
            for folder in [NSHomeDirectory() + "/.codex", NSHomeDirectory() + "/.codex-alt"] where FileManager.default.fileExists(atPath: folder + "/auth.json") {
                group.addTask { await codex(folder: folder) }
            }
            var result: [PlanUsage] = []
            for await usage in group { if let usage { result.append(usage) } }
            // Accounts with readable limits first, then by provider and name.
            return result.sorted { ($0.problem == nil ? 0 : 1, $0.provider, $0.account) < ($1.problem == nil ? 0 : 1, $1.provider, $1.account) }
        }
    }

    static func claude(folder: String, account: String) async -> PlanUsage? {
        guard let signIn = claudeSignIn(folder: folder) else { return nil }
        var usage = PlanUsage(provider: "Claude", account: account, plan: signIn.plan, windows: [])
        if let expires = signIn.expires, expires < Date() {
            usage.problem = "Sign-in expired · renews when Claude Code next runs"
            return usage
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        request.setValue("Bearer " + signIn.token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Wisp", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            usage.problem = "Could not read the limits right now"
            return usage
        }
        let names = ["five_hour": "5-hour session", "seven_day": "This week", "seven_day_opus": "This week, Opus",
                     "seven_day_sonnet": "This week, Sonnet"]
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] {
            guard let window = json[key] as? [String: Any], let utilization = window["utilization"] as? Double else { continue }
            usage.windows.append(.init(name: names[key] ?? key, used: utilization / 100, resets: date(window["resets_at"])))
        }
        return usage
    }

    static func codex(folder: String) async -> PlanUsage? {
        guard let data = FileManager.default.contents(atPath: folder + "/auth.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any], let token = tokens["access_token"] as? String else { return nil }
        let accountID = tokens["account_id"] as? String
        let email = (tokens["id_token"] as? String).flatMap(jwtEmail) ?? (folder as NSString).lastPathComponent
        var usage = PlanUsage(provider: "Codex", account: email, plan: nil, windows: [])
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("Wisp", forHTTPHeaderField: "User-Agent")
        guard let (body, response) = try? await URLSession.shared.data(for: request) else {
            usage.problem = "Could not read the limits right now"
            return usage
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let result = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            usage.problem = status == 401 ? "Sign-in expired · renews when Codex next runs"
                : "Could not read the limits right now"
            return usage
        }
        usage.plan = (result["plan_type"] as? String)?.capitalized
        let limits = result["rate_limit"] as? [String: Any] ?? [:]
        for (key, fallback) in [("primary_window", "5-hour session"), ("secondary_window", "This week")] {
            guard let window = limits[key] as? [String: Any], let percent = window["used_percent"] as? Double else { continue }
            let seconds = window["limit_window_seconds"] as? Double
            let name = seconds.map { $0 >= 86_400 * 6 ? "This week" : ($0 <= 18_000 ? "5-hour session" : fallback) } ?? fallback
            let resets = (window["reset_after_seconds"] as? Double).map { Date().addingTimeInterval($0) }
            usage.windows.append(.init(name: name, used: percent / 100, resets: resets))
        }
        return usage
    }

    /// Parses "2026-11-03T23:10:00.130194+00:00"; the formatter does not take six fractional digits.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// The email claim of an OpenAI id token, read without verifying it; it is only a label.
    static func jwtEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
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
