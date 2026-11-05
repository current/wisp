import Foundation

/// Per-app folders in ~/Library/Caches and in sandboxed apps' containers, one row per app.
public struct AppCacheScanner: CleanScanner {
    static let group = "App caches"

    /// Apple caches known to hold nothing but cache. Every other com.apple folder is left
    /// alone: many hold state (CloudKit, Family, Find My, downloads in progress).
    static let appleCaches: [String: String?] = [
        "com.apple.Safari": nil,
        "com.apple.python": "Python bytecode",
        "com.apple.helpd": "Help Viewer",
    ]

    /// Apple folders without the com.apple prefix that hold state rather than cache.
    static let appleFolders: Set<String> = [
        "CloudKit", "FamilyCircle", "GeoServices", "PassKit", "Metadata", "TemporaryItems", "Maps", "AMSDataMigratorTool",
        "SiriTTS", "Siri", "MobileSync", "Cleanup At Startup", "FontRegistry", "ColorSync", "storeassetd", "familycircled",
        "akd", "assistantd", "callservicesd", "sharedfilelistd", "suggestd", "parsecd", "knowledge-agent", "icloudmailagent",
        "spotlightknowledged", "homed", "CrashReporter", "SoftwareUpdate", "Apple", "Microsoft Edge Update",
    ]

    /// Caches that hold downloads worth keeping (offline music, game data, sample libraries)
    /// or that cost a sign-in: listed as check first.
    static let costlyPrefixes = ["com.spotify.", "com.valvesoftware.", "com.blizzard.", "net.battle.", "com.epicgames.", "com.adobe.",
                                 "com.roblox.", "com.microsoft.teams"]

    public var tab: CleanTab { .junk }
    public var minimumBytes: Int64
    public var appName: @Sendable (String) -> String?
    /// Containers need Full Disk Access; without it macOS asks the owner about every app.
    public var readsContainers: @Sendable () -> Bool

    public init(minimumBytes: Int64 = 1 << 20, appName: @escaping @Sendable (String) -> String? = AppNames.name(bundleID:),
                readsContainers: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess }) {
        self.minimumBytes = minimumBytes
        self.appName = appName
        self.readsContainers = readsContainers
    }

    /// One app's caches, wherever they are.
    struct App {
        var key: String
        var name: String
        var bundleID: String?
        var paths: [String] = []
    }

    static func skipped(_ name: String) -> Bool {
        if name.hasPrefix("app.wisp.") || DeveloperCacheScanner.cacheFolders.contains(name) { return true }
        if name.hasPrefix("com.apple.") { return !appleCaches.keys.contains(name) }
        if appleFolders.contains(name) { return true }
        // Lowercase names ending in "d" are system daemons: geod, nsurlsessiond.
        return name.count > 2 && name.hasSuffix("d") && name.allSatisfy { $0.isLowercase && $0.isLetter }
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let home = context.homePath
        var folders: [(name: String, path: String)] = []
        let caches = home + "/Library/Caches"
        for name in CleanFiles.names(caches) where !Self.skipped(name) {
            folders.append((name, caches + "/" + name))
        }
        if readsContainers() {
            let containers = home + "/Library/Containers"
            for name in CleanFiles.names(containers) where !name.hasPrefix("com.apple.") && !Self.skipped(name) {
                folders.append((name, containers + "/" + name + "/Data/Library/Caches"))
            }
        }
        folders = folders.filter { CleanFiles.isDirectory($0.path) && !context.isBlocked($0.path) }

        var apps: [String: App] = [:]
        var order: [String] = []
        var resolved: [String: (key: String, name: String?)] = [:]
        for folder in folders {
            if context.isCancelled() { return [] }
            let owner = resolved[folder.name] ?? resolve(folder.name)
            resolved[folder.name] = owner
            if apps[owner.key] == nil {
                let name = owner.name ?? Self.appleCaches[owner.key].flatMap { $0 } ?? owner.key
                apps[owner.key] = App(key: owner.key, name: name, bundleID: owner.name != nil || owner.key.contains(".") ? owner.key : nil)
                order.append(owner.key)
            }
            apps[owner.key]?.paths.append(folder.path)
        }

        let sizer = CleanSizer(context)
        var items: [CleanItem] = []
        var start = 0
        // Batches of a dozen apps, so the list fills in while the rest are measured.
        while start < order.count, !sizer.cancelled {
            let keys = order[start..<min(order.count, start + 12)]
            start += 12
            let sizes = sizer.sizes(keys.flatMap { apps[$0]?.paths ?? [] })
            var batch: [CleanItem] = []
            for key in keys {
                guard var app = apps[key] else { continue }
                app.paths.sort()
                let size = sizer.total(app.paths, sizes: sizes)
                guard size.bytes >= minimumBytes else { continue }
                let costly = Self.costlyPrefixes.contains { key.hasPrefix($0) }
                let detail = costly
                    ? "Files \(app.name) downloaded. It downloads them again when needed, which can take a while."
                    : "Temporary files \(app.name) makes again as you use it."
                batch.append(CleanItem(id: "appcache:\(app.paths[0])", tab: .junk, group: Self.group, name: "\(app.name) cache",
                                       detail: detail, paths: app.paths, bytes: size.bytes, modified: size.modified,
                                       safety: costly ? .checkFirst : .safe, ownerBundleID: app.bundleID))
            }
            if !batch.isEmpty { context.found(batch) }
            items += batch
        }
        return items
    }

    /// The app a cache folder belongs to: its bundle identifier, or the nearest parent
    /// identifier LaunchServices knows (an extension's caches go with its app). Updater
    /// folders named <id>.ShipIt go with <id>.
    private func resolve(_ folder: String) -> (key: String, name: String?) {
        var key = folder
        if key.hasSuffix(".ShipIt") { key.removeLast(".ShipIt".count) }
        guard key.contains(".") else { return (key, nil) }
        var parts = key.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let name = appName(candidate) { return (candidate, name) }
            if parts.count <= 3 { break }
            parts.removeLast()
        }
        return (key, nil)
    }
}
