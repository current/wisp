import Foundation

/// Asks Antigravity for its plan limits. While it runs, Antigravity's language server
/// writes its port and a per-run token to ~/.gemini/antigravity/daemon/hub_<port>.json
/// and answers `GetUserStatus` on 127.0.0.1 with each model's remaining quota. Wisp
/// reads that answer only; the request never leaves the Mac and no sign-in is read.
public enum AntigravityLive {
    struct Record: Codable, Equatable {
        var updated: Date
        var account: String?
        var plan: String?
        var windows: [ClaudeStatusLine.Record.Window]
    }

    struct Hub: Decodable {
        var pid: Int32
        var httpPort: Int
        var csrfToken: String
    }

    static let fileName = "live-antigravity.json"

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

    static func saved(store: URL) -> Record? {
        guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(fileName).path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }

    static func save(_ record: Record, store: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? data.write(to: store.appendingPathComponent(fileName), options: .atomic)
    }

    /// Asks again when Antigravity is running and the saved answer is older than `maxAge`.
    public static func refresh(home: String = NSHomeDirectory(), store: URL = ClaudeStatusLine.store,
                               maxAge: TimeInterval, now: Date = Date()) {
        if let saved = saved(store: store), now.timeIntervalSince(saved.updated) < maxAge { return }
        guard let hub = hub(home: home), let status = ask(hub), let record = record(status, now: now) else { return }
        save(record, store: store)
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

    /// "Gemini" for every Gemini model and orchestrator, otherwise the label's first word
    /// ("Claude", "GPT-OSS").
    static func vendorName(_ config: [String: Any]) -> String {
        let id = (config["modelId"] as? String ?? "").lowercased()
        if id.hasPrefix("gemini") { return "Gemini" }
        let label = config["label"] as? String ?? id
        return label.split(separator: " ").first.map(String.init) ?? "Other"
    }

    static func ask(_ hub: Hub, timeout: TimeInterval = 5) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(hub.httpPort)/exa.language_server_pb.LanguageServerService/GetUserStatus") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hub.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
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
