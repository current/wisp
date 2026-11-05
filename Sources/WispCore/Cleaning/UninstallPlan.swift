import Foundation

/// What goes when an app is uninstalled: the bundle and what it left in ~/Library.
///
/// Matching is strict. A folder named with the app's bundle id, the id of an extension
/// inside it, or one of its app groups arrives ticked. A folder named after the app,
/// or after something below its bundle id ("com.foo.Bar.ShipIt"), arrives unticked.
/// Nothing that another installed app could own is listed: no vendor prefixes, no
/// app group another app also declares.
public enum UninstallPlan {
    public enum AppRemoval: String, Codable, Sendable {
        /// Move the bundle to the Trash.
        case trash
        /// `brew uninstall --cask`, only offered when the app is the cask's only app.
        case homebrew
    }

    /// The plan for one app. `installed` is every installed app, so their folders stay out of it.
    public static func make(for app: InstalledApp, appRemoval: AppRemoval = .trash, installed: [InstalledApp]? = nil,
                            home: String = NSHomeDirectory(), fullDiskAccess: Bool = StorageAccess.hasFullDiskAccess) -> [CleanItem] {
        let others = installed ?? InstalledApps.scan(locations: .standard(home: home), measure: false)
        return UninstallPlanner(home: home, installed: others, fullDiskAccess: fullDiskAccess).items(for: app, appRemoval: appRemoval)
    }

    /// Whether a plan may remove `path`: an app bundle in an Applications folder, or an
    /// entry inside a folder of ~/Library. Never a top-level folder or anything outside home.
    public static func mayRemove(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standard = (path as NSString).standardizingPath
        guard standard == path, !path.contains("/../"), path.hasPrefix("/") else { return false }
        for folder in ["/Applications/", home + "/Applications/"] where path.hasPrefix(folder) {
            let rest = path.dropFirst(folder.count).split(separator: "/")
            return path.hasSuffix(".app") && (1...2).contains(rest.count)
        }
        let library = home + "/Library/"
        guard path.hasPrefix(library) else { return false }
        let parts = path.dropFirst(library.count).split(separator: "/")
        // iCloud Drive, synced cloud folders, keychains and mail hold the user's own data, never an app's leftovers.
        let userData: Set<Substring> = ["Mobile Documents", "CloudStorage", "Keychains", "Mail", "Messages", "Accounts"]
        return parts.count >= 2 && !userData.contains(parts[0])
    }
}

/// Builds uninstall plans, listing each Library folder once so a plan for every app stays cheap.
public final class UninstallPlanner: @unchecked Sendable {
    let home: String
    let library: String
    let installed: [InstalledApp]
    let fullDiskAccess: Bool
    private let meter: FootprintMeter
    private var listings: [String: [String]] = [:]
    private let lock = NSLock()

    public init(home: String = NSHomeDirectory(), installed: [InstalledApp], fullDiskAccess: Bool = StorageAccess.hasFullDiskAccess,
                measure: Bool = true) {
        self.home = home
        library = home + "/Library"
        self.installed = installed
        self.fullDiskAccess = fullDiskAccess
        meter = FootprintMeter(home: home, fullDiskAccess: fullDiskAccess, enabled: measure)
    }

    public func items(for app: InstalledApp, appRemoval: UninstallPlan.AppRemoval = .trash) -> [CleanItem] {
        lock.lock()
        defer { lock.unlock() }
        let others = installed.filter { $0.bundleID != app.bundleID && $0.path != app.path }
        let otherIDs = Set(others.flatMap(\.ownBundleIDs).map { $0.lowercased() })
        let otherMains = others.map(\.bundleID)
        let otherNames = Set(others.flatMap(\.folderNames).map { $0.lowercased() })
        var ownIDs = app.ownBundleIDs.filter { !otherIDs.contains($0.lowercased()) }
        ownIDs += containerIDs(for: app, known: Set(ownIDs.map { $0.lowercased() }).union(otherIDs))
        let ownLower = Set(ownIDs.map { $0.lowercased() })
        // "com.google.Chrome.canary.x" is Canary's, not Chrome's, when Canary is installed.
        func claimedByAnother(_ key: String) -> Bool {
            otherIDs.contains(key.lowercased())
                || otherMains.contains { LibraryArea.isWithin($0, app.bundleID) && LibraryArea.isWithin(key, $0) }
        }

        enum Match { case strict, loose }
        func match(_ entry: String, in area: LibraryArea) -> Match? {
            let key = LibraryArea.bundleKey(entry)
            if ownLower.contains(key.lowercased()) { return .strict }
            // Case-sensitive: "com.google.chrome.for.testing" is another app, not part of "com.google.Chrome".
            if key.hasPrefix(app.bundleID + "."), !claimedByAnother(key) { return .loose }
            if area.byName, !LibraryArea.isReverseDNS(entry), entry.count >= 3, !otherNames.contains(entry.lowercased()),
               app.folderNames.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
                return .loose
            }
            return nil
        }

        var items: [CleanItem] = [appItem(app, removal: appRemoval)]
        func add(_ area: LibraryArea, strict: [String], loose: [String]) {
            if !strict.isEmpty { items.append(item(app, area: area, paths: strict, checked: true)) }
            for path in loose { items.append(item(app, area: area, paths: [path], checked: false)) }
        }

        for area in LibraryArea.all {
            let base = library + "/" + area.folder
            var strict: [String] = []
            var loose: [String] = []
            if area.guarded && !fullDiskAccess {
                // Listing a guarded folder can make macOS ask the owner; check the exact names only.
                for id in ownIDs {
                    for name in exactNames(id, area: area) where exists(base + "/" + name) { strict.append(base + "/" + name) }
                }
            } else {
                for entry in listing(base) {
                    switch match(entry, in: area) {
                    case .strict: strict.append(base + "/" + entry)
                    case .loose: loose.append(base + "/" + entry)
                    case nil: break
                    }
                }
            }
            if area.byName { loose += vendorFolders(app, base: base, otherNames: otherNames) }
            add(area, strict: strict, loose: loose)
        }

        let groupBase = library + "/Group Containers"
        let otherGroups = Set(others.flatMap(\.appGroups))
        let groups = app.appGroups.filter { !otherGroups.contains($0) && !$0.contains("/") && !$0.isEmpty }
            .map { groupBase + "/" + $0 }.filter(exists)
        add(.groupContainers, strict: groups, loose: [])

        let (strictAgents, looseAgents) = launchAgents(for: app, ownIDs: ownLower, claimedByAnother: claimedByAnother)
        add(.launchAgents, strict: strictAgents, loose: looseAgents)
        return items
    }

    /// Ids of helpers nested deeper than InstalledApps looks, found through the containers
    /// macOS made for them: the container's metadata names a bundle inside this app. Only
    /// containers from the app's vendor are opened.
    private func containerIDs(for app: InstalledApp, known: Set<String>) -> [String] {
        guard fullDiskAccess else { return [] }
        let base = library + "/Containers"
        let vendor = LibraryArea.vendor(app.bundleID) + "."
        let inside = app.path + "/"
        return listing(base).filter { entry in
            entry.hasPrefix(vendor) && !known.contains(entry.lowercased())
                && (LibraryArea.containerBundle(base + "/" + entry)?.hasPrefix(inside) ?? false)
        }
    }

    /// "Google/Chrome" for Google Chrome: a folder for the app inside one for its vendor.
    private func vendorFolders(_ app: InstalledApp, base: String, otherNames: Set<String>) -> [String] {
        guard let space = app.name.firstIndex(of: " ") else { return [] }
        let vendor = String(app.name[..<space])
        var names = [String(app.name[app.name.index(after: space)...])]
        if let bundleName = app.bundleName, bundleName != vendor, !names.contains(bundleName) { names.append(bundleName) }
        return names.filter { $0.count >= 3 && !otherNames.contains($0.lowercased()) }
            .map { base + "/" + vendor + "/" + $0 }.filter(exists)
    }

    /// The names an area uses for a bundle id when it can't be listed.
    private func exactNames(_ id: String, area: LibraryArea) -> [String] {
        switch area.folder {
        case "Cookies": return [id + ".binarycookies"]
        default: return [id]
        }
    }

    private func appItem(_ app: InstalledApp, removal: UninstallPlan.AppRemoval) -> CleanItem {
        var bytes = app.bundleBytes
        if bytes == 0 { bytes = meter.measure(app.path).bytes }
        let version = app.version.map { ", version \($0)" } ?? ""
        if removal == .homebrew, let token = app.brewToken {
            return CleanItem(id: "uninstall:" + app.path, tab: .uninstall, group: app.name, name: app.name,
                             detail: "Homebrew deletes the app\(version) for good with brew uninstall --cask \(token).",
                             paths: [app.path], bytes: bytes, safety: .checkFirst, removal: .brewCask(token: token),
                             ownerBundleID: app.bundleID, checkedByDefault: true)
        }
        return CleanItem(id: "uninstall:" + app.path, tab: .uninstall, group: app.name, name: app.name,
                         detail: "The app itself\(version).", paths: [app.path], bytes: bytes, safety: .checkFirst,
                         removal: .trash, ownerBundleID: app.bundleID, checkedByDefault: true)
    }

    private func item(_ app: InstalledApp, area: LibraryArea, paths: [String], checked: Bool) -> CleanItem {
        var bytes: Int64 = 0
        var modified: Date?
        let measurable = fullDiskAccess || !area.guarded
        for path in paths where measurable {
            let figure = meter.measure(path)
            bytes += figure.bytes
            if let date = figure.modified { modified = max(modified ?? date, date) }
        }
        let entry = String(paths[0].dropFirst(library.count + area.folder.count + 2))
        let name = checked ? area.label : "\(area.label) named \(entry)"
        var detail = area.detail
        if !checked { detail = "Named \(entry), which looks like \(app.name)'s but is not its exact bundle id." }
        else if !measurable { detail = String(detail.dropLast()) + ", not measured without Full Disk Access." }
        return CleanItem(id: "uninstall:" + paths[0], tab: .uninstall, group: app.name, name: name, detail: detail, paths: paths,
                         bytes: bytes, modified: modified, safety: area.safe ? .safe : .checkFirst, removal: .trash,
                         ownerBundleID: app.bundleID, checkedByDefault: checked)
    }

    /// Agents whose label is the app's id or an extension's, that run something inside the
    /// bundle, or that launchd ties to the app. A label below the app's id alone is a loose match.
    private func launchAgents(for app: InstalledApp, ownIDs: Set<String>,
                              claimedByAnother: (String) -> Bool) -> (strict: [String], loose: [String]) {
        let base = library + "/LaunchAgents"
        var strict: [String] = []
        var loose: [String] = []
        let inside = app.path + "/"
        for entry in listing(base) where entry.hasSuffix(".plist") {
            let path = base + "/" + entry
            guard let item = LaunchItemScanner.item(plistAt: path, kind: .agent, scope: .user, lookup: { _ in nil }) else { continue }
            let runsBundle = [item.program, item.script, item.appPath].contains { $0 == app.path || ($0?.hasPrefix(inside) ?? false) }
            if ownIDs.contains(item.label.lowercased()) || runsBundle || item.associatedBundleIDs.contains(where: { ownIDs.contains($0.lowercased()) }) {
                strict.append(path)
            } else if item.label.hasPrefix(app.bundleID + "."), !claimedByAnother(item.label) {
                loose.append(path)
            }
        }
        return (strict, loose)
    }

    private func listing(_ folder: String) -> [String] {
        if let cached = listings[folder] { return cached }
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        listings[folder] = entries
        return entries
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
