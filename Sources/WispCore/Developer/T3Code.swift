import Foundation

/// The names T3 Code gives the accounts it runs, such as "Claude (alt)", so AI usage can
/// show the same ones. Only the account list in T3 Code's settings is read; the figures
/// themselves come from each agent (see `PlanUsageReader`), with or without T3 Code.
public enum T3CodeNames {
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

    static func instances(settings path: String, home: String, driver: String) -> [String: (folder: String, label: String?)] {
        let fallback = home + (driver == "codex" ? "/.codex" : "/.claude")
        var found: [String: (folder: String, label: String?)] = driver == "claudeAgent" ? ["claudeAgent": (fallback, nil)] : [:]
        let instances: [String: Any]? = FileCache.value(path, kind: "t3-instances") {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["providerInstances"] as? [String: Any]
        }
        guard let instances else { return found }
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
}
