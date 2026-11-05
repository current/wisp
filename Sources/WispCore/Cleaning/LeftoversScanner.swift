import Foundation

/// Files in ~/Library named with the bundle id of an app that is no longer installed,
/// one row per vanished app.
///
/// Conservative on purpose. An id is left alone when any installed app owns it or
/// something above or below it, when LaunchServices still knows an app for it, when an
/// installed app comes from the same vendor ("com.google"), when it names a
/// command-line tool, when it is on the short list of ids that never have an app, and
/// when anything in the group changed in the last week.
public struct LeftoversScanner: CleanScanner {
    public let tab = CleanTab.leftovers
    /// Nil reads /Applications and the context's ~/Applications.
    public var appFolders: [String]?
    public var caskrooms: [String]
    /// Folders whose file names count as command-line tools. Nil uses the usual bin folders.
    public var commandFolders: [String]?
    /// launchd folders outside home whose items keep an id in use.
    public var systemLaunchFolders: [String]
    public var minimumAge: TimeInterval
    /// Nil asks StorageAccess.
    public var fullDiskAccess: Bool?
    /// Whether an app with this bundle id exists anywhere outside the scanned folders.
    public var appExists: @Sendable (String) -> Bool
    public var now: @Sendable () -> Date

    public init(appFolders: [String]? = nil, caskrooms: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
                commandFolders: [String]? = nil, systemLaunchFolders: [String] = ["/Library/LaunchAgents", "/Library/LaunchDaemons"],
                minimumAge: TimeInterval = 7 * 86_400, fullDiskAccess: Bool? = nil,
                appExists: @escaping @Sendable (String) -> Bool = { InstalledApps.launchServicesHasApp($0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.appFolders = appFolders
        self.caskrooms = caskrooms
        self.commandFolders = commandFolders
        self.systemLaunchFolders = systemLaunchFolders
        self.minimumAge = minimumAge
        self.fullDiskAccess = fullDiskAccess
        self.appExists = appExists
        self.now = now
    }

    /// Ids that belong to updaters, crash reporters, shared frameworks and printer drivers:
    /// they have no app by design, so no app being installed says nothing. Each covers what is below it.
    static let noAppByDesign = [
        "com.google.Keystone", "com.google.keystone", "com.google.GoogleUpdater", "com.microsoft.autoupdate",
        "com.microsoft.autoupdate2", "com.microsoft.shared", "com.microsoft.office", "com.microsoft.errorreporting",
        "org.sparkle-project", "com.crashlytics", "io.fabric", "io.sentry", "com.segment", "com.plausiblelabs",
        "com.github.Squirrel", "com.electron", "org.swift", "org.llvm", "org.python", "org.cocoapods", "com.oracle.java",
        "net.java", "com.hp", "com.epson", "jp.co.epson", "com.brother", "jp.co.canon", "com.canon", "org.cups",
        "com.firebase", "com.google.firebase",
    ]

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let items = find(context, only: nil)
        if !items.isEmpty { context.found(items) }
        return items
    }

    /// What an app left behind, asked right after it was deleted: the week-old rule and the
    /// vendor rule do not apply, everything else does. Nil when nothing is left or an app still has the id.
    public func leftovers(forBundleID bundleID: String, context: CleanScanContext = CleanScanContext()) -> CleanItem? {
        find(context, only: bundleID).first
    }

    private struct Candidate {
        var paths: [String] = []
        var areas: [String] = []
        var nameHint: String?
    }

    private func find(_ context: CleanScanContext, only: String?) -> [CleanItem] {
        let home = context.home.path
        let library = home + "/Library"
        let access = fullDiskAccess ?? StorageAccess.hasFullDiskAccess
        let installed = InstalledApps.scan(locations: InstalledApps.Locations(appFolders: appFolders ?? ["/Applications", home + "/Applications"]),
                                           measure: false, cancelled: context.isCancelled)
        if context.isCancelled() { return [] }
        let owned = installed.flatMap(\.ownBundleIDs)
        let ownedLower = Set(owned.map { $0.lowercased() })
        let vendors = Set(installed.map { LibraryArea.vendor($0.bundleID).lowercased() })
        let groups = Set(installed.flatMap(\.appGroups))
        let teams = Set(installed.compactMap(\.teamID))
        let commands = only == nil ? commandNames(home: home) : []

        func wanted(_ key: String) -> Bool {
            guard let only else { return true }
            return LibraryArea.isWithin(key, only)
        }

        var candidates: [String: Candidate] = [:]
        func add(_ key: String, _ path: String, area: String, hint: String? = nil) {
            guard LibraryArea.isReverseDNS(key), wanted(key), !context.isExcluded(path) else { return }
            var candidate = candidates[key] ?? Candidate()
            candidate.paths.append(path)
            if !candidate.areas.contains(area) { candidate.areas.append(area) }
            candidate.nameHint = candidate.nameHint ?? hint
            candidates[key] = candidate
        }

        for area in LibraryArea.all where access || !area.guarded {
            let base = library + "/" + area.folder
            for entry in listing(base) {
                if context.isCancelled() { return [] }
                let path = base + "/" + entry
                if area.folder == "Containers" {
                    // The container says which bundle made it; when that bundle exists the container is in use.
                    let creator = LibraryArea.containerBundle(path)
                    if let creator, FileManager.default.fileExists(atPath: creator) { continue }
                    add(entry, path, area: area.label, hint: creator.flatMap(Self.appName))
                } else {
                    add(LibraryArea.bundleKey(entry), path, area: area.label)
                }
            }
        }
        if access {
            let base = library + "/Group Containers"
            for entry in listing(base) where !groups.contains(entry) {
                let first = String(entry.prefix { $0 != "." })
                if teams.contains(first) { continue }
                let creator = LibraryArea.containerMetadata(base + "/" + entry)?["MCMMetadataCreator"] as? String
                add(creator ?? LibraryArea.groupKey(entry), base + "/" + entry, area: LibraryArea.groupContainers.label)
            }
        }
        // Ids that launchd still runs something for are in use, even with the main app gone
        // (iStat Menus keeps its menu bar helper in Application Support).
        var live: [String] = []
        let agents = library + "/LaunchAgents"
        for folder in [agents] + systemLaunchFolders {
            for entry in listing(folder) where entry.hasSuffix(".plist") {
                let path = folder + "/" + entry
                guard let item = LaunchItemScanner.item(plistAt: path, kind: .agent, scope: .user, lookup: { _ in nil }) else { continue }
                if !item.isLeftover {
                    live += [item.label] + item.associatedBundleIDs
                } else if folder == agents {
                    // Only agents whose program or app is gone: the owner's own scripts have reverse-DNS labels too.
                    add(item.associatedBundleIDs.first ?? item.label, path, area: LibraryArea.launchAgents.label)
                }
            }
        }

        func ownedByInstalled(_ key: String) -> Bool {
            let lower = key.lowercased()
            if ownedLower.contains(lower) { return true }
            return owned.contains { LibraryArea.isWithin(key, $0) || LibraryArea.isWithin($0, key) }
        }
        func knownToLaunchServices(_ key: String) -> Bool {
            var parts = key.split(separator: ".").map(String.init)
            while parts.count >= 3 {
                if appExists(parts.joined(separator: ".")) { return true }
                parts.removeLast()
            }
            return false
        }
        func keep(_ key: String) -> Bool {
            if InstalledApps.isApple(key) || key.lowercased().hasPrefix("com.apple.") { return false }
            if Self.noAppByDesign.contains(where: { LibraryArea.isWithin(key, $0) }) { return false }
            if ownedByInstalled(key) { return false }
            if live.contains(where: { LibraryArea.isWithin(key, $0) || LibraryArea.isWithin($0, key) }) { return false }
            if only == nil {
                if vendors.contains(LibraryArea.vendor(key).lowercased()) { return false }
                if isCommand(key, commands) { return false }
            }
            return !knownToLaunchServices(key)
        }

        // Fold "com.foo.Bar.ShipIt" into "com.foo.Bar" when both are there, and everything into the asked-for id.
        var merged: [String: Candidate] = [:]
        let ordered = candidates.keys.sorted { ($0.split(separator: ".").count, $0) < ($1.split(separator: ".").count, $1) }
        for key in ordered where keep(key) {
            let candidate = candidates[key]!
            guard let parent = only ?? merged.keys.first(where: { LibraryArea.isWithin(key, $0) }) else {
                merged[key] = candidate
                continue
            }
            var into = merged[parent] ?? Candidate()
            into.paths += candidate.paths
            into.areas += candidate.areas.filter { !into.areas.contains($0) }
            into.nameHint = into.nameHint ?? candidate.nameHint
            merged[parent] = into
        }

        let meter = FootprintMeter(home: home, fullDiskAccess: access)
        let trashNames = access ? trashedAppNames(home: home) : [:]
        let cutoff = now().addingTimeInterval(-minimumAge)
        var items: [CleanItem] = []
        for (key, candidate) in merged {
            if context.isCancelled() { return [] }
            var bytes: Int64 = 0
            var latest: Date?
            for path in candidate.paths {
                let figure = meter.measure(path)
                bytes += figure.bytes
                if let date = figure.modified { latest = max(latest ?? date, date) }
            }
            if only == nil, let latest, latest > cutoff { continue }
            let name = candidate.nameHint ?? trashNames[key.lowercased()] ?? key
            items.append(CleanItem(id: "leftovers:" + key, tab: .leftovers, group: "Removed apps", name: name,
                                   detail: "Files \(name == key ? "an app" : name) left in \(Self.list(candidate.areas)) after it was removed.",
                                   paths: candidate.paths.sorted(), bytes: bytes, modified: latest, safety: .checkFirst, removal: .trash,
                                   ownerBundleID: key, checkedByDefault: false))
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    static func list(_ areas: [String]) -> String {
        guard areas.count > 1 else { return areas.first ?? "Library" }
        if areas.count > 3 { return areas.prefix(2).joined(separator: ", ") + " and \(areas.count - 2) more folders" }
        return areas.dropLast().joined(separator: ", ") + " and " + areas.last!
    }

    /// "Foo" for a container made by /Applications/Foo.app/Contents/PlugIns/Share.appex.
    static func appName(_ bundlePath: String) -> String? {
        let parts = bundlePath.split(separator: "/")
        guard let outer = parts.first(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(outer.dropLast(4))
    }

    /// Apps waiting in the Trash, by lowercased bundle id, for the names of what was just deleted.
    private func trashedAppNames(home: String) -> [String: String] {
        var names: [String: String] = [:]
        for path in InstalledApps.bundlePaths(in: [home + "/.Trash"]) {
            guard let id = InstalledApps.infoPlist(path)?["CFBundleIdentifier"] as? String else { continue }
            names[id.lowercased()] = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return names
    }

    /// Names of command-line tools and Homebrew packages, which keep Library folders without an app.
    private func commandNames(home: String) -> Set<String> {
        let folders = commandFolders ?? ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home + "/.local/bin", home + "/bin",
                                         home + "/.cargo/bin", home + "/.bun/bin", home + "/.npm-global/bin", home + "/go/bin",
                                         "/opt/homebrew/Cellar", "/usr/local/Cellar"] + caskrooms
        var names = Set<String>()
        for folder in folders {
            for entry in listing(folder) { names.insert(entry.lowercased()) }
        }
        return names
    }

    private func isCommand(_ key: String, _ commands: Set<String>) -> Bool {
        guard let last = key.split(separator: ".").last?.lowercased() else { return false }
        return commands.contains(last)
    }

    private func listing(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
    }
}
