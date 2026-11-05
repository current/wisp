import Darwin
import Foundation

/// A folder in ~/Library where apps keep files named after their bundle id.
struct LibraryArea: Sendable {
    /// Relative to ~/Library.
    let folder: String
    /// The row name in a plan.
    let label: String
    let detail: String
    /// Apps also name folders here after themselves ("Slack"), not only their bundle id.
    let byName: Bool
    /// Reading inside needs Full Disk Access; without it Wisp only checks exact paths.
    let guarded: Bool
    /// Comes back by itself if the app is used again, so removing it costs nothing.
    let safe: Bool

    static let all: [LibraryArea] = [
        LibraryArea(folder: "Application Support", label: "Application Support",
                    detail: "Databases, downloads and settings the app keeps; without them it starts fresh.", byName: true, guarded: false, safe: false),
        LibraryArea(folder: "Caches", label: "Caches", detail: "Files the app downloads or builds again when it needs them.",
                    byName: true, guarded: false, safe: true),
        LibraryArea(folder: "Preferences", label: "Preferences", detail: "The app's settings.", byName: false, guarded: false, safe: false),
        LibraryArea(folder: "Preferences/ByHost", label: "Preferences for this Mac", detail: "Settings the app keeps for this Mac only.",
                    byName: false, guarded: false, safe: false),
        LibraryArea(folder: "Containers", label: "Container", detail: "The app's sandbox, with its settings and any documents saved inside it.",
                    byName: false, guarded: true, safe: false),
        LibraryArea(folder: "Saved Application State", label: "Saved windows", detail: "Windows macOS reopens when the app starts.",
                    byName: false, guarded: false, safe: true),
        LibraryArea(folder: "HTTPStorages", label: "Website data", detail: "Cookies and website data that keep the app signed in.",
                    byName: false, guarded: false, safe: false),
        LibraryArea(folder: "WebKit", label: "Web view storage", detail: "Storage for the web pages the app shows inside its windows.",
                    byName: false, guarded: false, safe: false),
        LibraryArea(folder: "Cookies", label: "Cookies", detail: "Cookies that keep the app signed in to websites.",
                    byName: false, guarded: true, safe: false),
        LibraryArea(folder: "Logs", label: "Logs", detail: "Records the app kept of what it did and what went wrong.",
                    byName: true, guarded: false, safe: true),
        LibraryArea(folder: "Application Scripts", label: "Application Scripts", detail: "Scripts macOS keeps for the app and its extensions.",
                    byName: false, guarded: false, safe: false),
    ]

    static let groupContainers = LibraryArea(folder: "Group Containers", label: "Group Container",
                                             detail: "Data the app shares with its extensions and widgets.", byName: false, guarded: true, safe: false)
    static let launchAgents = LibraryArea(folder: "LaunchAgents", label: "Launch agent", detail: "Starts a helper of the app when you log in.",
                                          byName: false, guarded: false, safe: false)

    /// The bundle id a Library entry is named after: "com.foo.Bar.plist", "com.foo.Bar.savedState",
    /// "com.foo.Bar.binarycookies" and the ByHost "com.foo.Bar.<host UUID>.plist" all give "com.foo.Bar".
    static func bundleKey(_ entry: String) -> String {
        var name = entry
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        if let dot = name.lastIndex(of: "."), isUUID(name[name.index(after: dot)...]) {
            name = String(name[..<dot])
        }
        return name
    }

    static func isUUID<S: StringProtocol>(_ text: S) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// Group container names carry a team id or "group." in front of a reverse-DNS id.
    static func groupKey(_ entry: String) -> String {
        var name = entry
        if name.hasPrefix("group.") { name.removeFirst(6) }
        let first = name.prefix { $0 != "." }
        if first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }), name.count > 11 {
            name.removeFirst(11)
        }
        if name.hasPrefix("group.") { name.removeFirst(6) }
        return name
    }

    /// "com.vendor.App" and longer: a known top-level domain and at least two more parts, no
    /// spaces, and not ending in a number, which rules out rotated logs such as "warp.log.old.1".
    static func isReverseDNS(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), !key.contains(" "), !key.contains("/") else { return false }
        guard let last = parts.last, !last.allSatisfy(\.isNumber) else { return false }
        return topLevelDomains.contains(String(parts[0]))
    }

    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "ai", "sh", "so", "tv", "fm", "ly", "gg", "to", "ws", "la", "cx",
        "us", "uk", "de", "fr", "jp", "cn", "ru", "eu", "ch", "nl", "se", "no", "fi", "dk", "it", "es", "pl", "cz", "at", "be",
        "ca", "au", "nz", "br", "in", "kr", "tw", "hk", "info", "biz", "edu", "gov", "xyz", "im", "cc", "is", "li", "lu", "pt",
        "gr", "hu", "ro", "ua", "by", "kz", "il", "za", "mx", "ar", "cl", "sg", "my", "th", "vn", "id", "ph", "ie", "sk", "si",
        "hr", "rs", "bg", "lt", "lv", "ee", "tr", "pro", "tech", "studio", "games", "design", "page", "one", "zone", "work",
        "space", "site", "online", "cloud", "software", "tools", "systems", "digital", "media", "world", "life", "fun", "run",
    ]

    /// The bundle path a container's metadata names, as it was when the container was made.
    static func containerBundle(_ container: String) -> String? {
        guard let plist = containerMetadata(container), let info = plist["MCMMetadataInfo"] as? [String: Any],
              let validation = info["SandboxProfileDataValidationInfo"] as? [String: Any],
              let parameters = validation["Parameters"] as? [String: Any],
              let bundle = parameters["application_bundle"] as? String, bundle.hasPrefix("/") else { return nil }
        return bundle
    }

    static func containerMetadata(_ container: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: container + "/.com.apple.containermanagerd.metadata.plist") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// "com.google" for "com.google.Chrome".
    static func vendor(_ key: String) -> String {
        key.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// `key` is `id` or something below it, such as "com.foo.Bar.ShipIt" for "com.foo.Bar".
    static func isWithin(_ key: String, _ id: String) -> Bool {
        key.caseInsensitiveCompare(id) == .orderedSame || key.lowercased().hasPrefix(id.lowercased() + ".")
    }
}

/// Sizes and dates for files and folders, through one FolderScanner so hard links count once.
final class FootprintMeter {
    private let scanner: FolderScanner
    private let enabled: Bool

    init(home: String, fullDiskAccess: Bool, enabled: Bool = true) {
        var rules = FolderScanner.Rules()
        rules.skip = fullDiskAccess ? [] : Set(StorageAccess.guarded.map { home + "/" + $0 })
        scanner = FolderScanner(rules: rules)
        self.enabled = enabled
    }

    /// Allocated bytes and the latest change below the path.
    func measure(_ path: String) -> (bytes: Int64, modified: Date?) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, nil) }
        let own = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if (info.st_mode & S_IFMT) != S_IFDIR {
            return (Int64(info.st_blocks) * 512, own)
        }
        guard enabled else { return (0, own) }
        let node = scanner.folder(at: path)
        let modified = node.modified > 0 ? Date(timeIntervalSince1970: node.modified) : own
        return (Int64(node.size), max(modified, own))
    }
}
