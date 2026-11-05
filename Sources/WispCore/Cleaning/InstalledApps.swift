import CoreServices
import Darwin
import Foundation
import Security

/// The Homebrew cask that put an app in /Applications.
public struct HomebrewCask: Codable, Sendable, Hashable {
    public var token: String
    /// File names of every app the cask installs, such as "Slack.app".
    public var apps: [String]
    /// The cask also installs a suite folder or a pkg, so it holds more than this app.
    public var installsMore: Bool

    public init(token: String, apps: [String], installsMore: Bool = false) {
        self.token = token
        self.apps = apps
        self.installsMore = installsMore
    }

    /// `brew uninstall --cask` would take only this app with it.
    public var isSingleApp: Bool { apps.count == 1 && !installsMore }
}

/// An app the owner installed in /Applications or ~/Applications.
public struct InstalledApp: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String?
    public var teamID: String?
    /// App groups from the code signature, which name its folders in Group Containers.
    public var appGroups: [String]
    /// Bundle ids of the extensions, XPC services and helper apps inside the bundle.
    public var nestedBundleIDs: [String]
    public var bundleBytes: Int64
    public var isRunning: Bool
    public var cask: HomebrewCask?
    /// CFBundleName when it differs from the file name; some apps name their folders with it.
    public var bundleName: String?

    public init(path: String, name: String, bundleID: String, version: String? = nil, teamID: String? = nil, appGroups: [String] = [],
                nestedBundleIDs: [String] = [], bundleBytes: Int64 = 0, isRunning: Bool = false, cask: HomebrewCask? = nil) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.appGroups = appGroups
        self.nestedBundleIDs = nestedBundleIDs
        self.bundleBytes = bundleBytes
        self.isRunning = isRunning
        self.cask = cask
    }

    /// The cask token when Homebrew can remove this app on its own.
    public var brewToken: String? { cask?.isSingleApp == true ? cask?.token : nil }

    /// Names the app may give its folders in Application Support, Caches and Logs.
    public var folderNames: [String] { [name] + (bundleName.map { [$0] } ?? []) }

    /// The main bundle id and every nested one.
    public var ownBundleIDs: [String] { [bundleID] + nestedBundleIDs.filter { $0 != bundleID } }
}

/// Finds the apps the owner installed. Reads Info.plists, code signatures and the
/// Homebrew Caskroom; runs nothing.
public enum InstalledApps {
    public struct Locations: Sendable {
        /// Read one level deep, plus one level of plain folders such as /Applications/Utilities.
        public var appFolders: [String]
        public var caskrooms: [String]

        public init(appFolders: [String], caskrooms: [String] = []) {
            self.appFolders = appFolders
            self.caskrooms = caskrooms
        }

        public static func standard(home: String = NSHomeDirectory()) -> Locations {
            Locations(appFolders: ["/Applications", home + "/Applications"], caskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
        }
    }

    /// Every installed app, sorted by name. `measure` walks each bundle for its size,
    /// which takes a second or two for a full /Applications.
    public static func scan(locations: Locations = .standard(), measure: Bool = true,
                            isRunning: (_ bundleID: String, _ path: String) -> Bool = { _, _ in false },
                            cancelled: () -> Bool = { false }) -> [InstalledApp] {
        let casks = caskIndex(locations.caskrooms)
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        let scanner = FolderScanner()
        for path in bundlePaths(in: locations.appFolders) {
            if cancelled() { break }
            guard var app = read(path, casks: casks), !seen.contains(app.bundleID) else { continue }
            seen.insert(app.bundleID)
            if measure { app.bundleBytes = Int64(scanner.folder(at: path).size) }
            app.isRunning = isRunning(app.bundleID, path)
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Finds an app by name, file name or bundle id, ignoring case.
    public static func find(_ query: String, in apps: [InstalledApp]) -> InstalledApp? {
        let wanted = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        func same(_ a: String) -> Bool { a.caseInsensitiveCompare(wanted) == .orderedSame }
        return apps.first { same($0.bundleID) || $0.path == query }
            ?? apps.first { same($0.name) || same((($0.path as NSString).lastPathComponent as NSString).deletingPathExtension) }
    }

    /// App bundles directly in the folders, and in plain folders one level down. Never inside another bundle.
    static func bundlePaths(in folders: [String]) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        func children(_ folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { folder + "/" + $0 }
        }
        for folder in folders {
            for path in children(folder) {
                if path.hasSuffix(".app") {
                    paths.append(path)
                } else if (path as NSString).pathExtension.isEmpty, isFolder(path) {
                    paths += children(path).filter { $0.hasSuffix(".app") }
                }
            }
        }
        return paths
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// One app, or nil for Apple's own apps, Wisp, and bundles without an id.
    static func read(_ path: String, casks: [String: HomebrewCask] = [:]) -> InstalledApp? {
        if path.hasPrefix("/System/") { return nil }
        if let real = realpath(path, nil) {
            defer { free(real) }
            if String(cString: real).hasPrefix("/System/") { return nil }
        }
        guard let info = infoPlist(path), let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        if isApple(id) || id == Wisp.bundleIdentifier { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let signature = signature(path)
        var app = InstalledApp(path: path, name: fileName, bundleID: id,
                            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String,
                            teamID: signature.team, appGroups: signature.groups, nestedBundleIDs: nestedBundleIDs(path),
                            cask: casks[(path as NSString).lastPathComponent])
        app.bundleName = [info["CFBundleName"], info["CFBundleDisplayName"]].compactMap { $0 as? String }
            .first { !$0.isEmpty && $0 != fileName }
        return app
    }

    static func isApple(_ id: String) -> Bool { id.hasPrefix("com.apple.") || id == "com.apple" }

    /// The Info.plist of an app, or of the iPhone or iPad app it wraps on Apple silicon.
    static func infoPlist(_ path: String) -> [String: Any]? {
        for candidate in [path + "/Contents/Info.plist", path + "/WrappedBundle/Info.plist", path + "/Info.plist"] {
            if let data = FileManager.default.contents(atPath: candidate),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    /// Team id and app groups, read from the signature without checking it.
    static func signature(_ path: String) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return (nil, []) }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
                entitlements?["com.apple.security.application-groups"] as? [String] ?? [])
    }

    /// Folders inside a bundle that hold extensions and helpers with their own bundle ids,
    /// which name their own containers and preferences.
    static let nestedFolders = ["Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices", "Contents/Library/LoginItems",
                                "Contents/Library/SystemExtensions", "Contents/Library/QuickLook", "Contents/Library/Spotlight",
                                "Contents/Helpers", "Contents/Frameworks", "Contents/MacOS", "Contents/Applications"]

    static func nestedBundleIDs(_ path: String) -> [String] {
        let fm = FileManager.default
        var ids: [String] = []
        for folder in nestedFolders {
            let base = path + "/" + folder
            for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                let ext = (entry as NSString).pathExtension
                // Frameworks and MacOS hold libraries and executables too; only bundles that are apps or extensions count.
                guard ["app", "appex", "xpc", "systemextension", "qlgenerator", "mdimporter"].contains(ext) else { continue }
                if let id = infoPlist(base + "/" + entry)?["CFBundleIdentifier"] as? String, !id.isEmpty, !ids.contains(id) {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// App file name to the cask that installed it, from each cask's install receipt.
    /// A file name two casks claim belongs to neither.
    static func caskIndex(_ caskrooms: [String]) -> [String: HomebrewCask] {
        let fm = FileManager.default
        var index: [String: HomebrewCask] = [:]
        var claimed: [String: Int] = [:]
        for room in caskrooms {
            for token in ((try? fm.contentsOfDirectory(atPath: room)) ?? []).sorted() where !token.hasPrefix(".") {
                guard let cask = cask(token: token, receipt: room + "/" + token + "/.metadata/INSTALL_RECEIPT.json") else { continue }
                for app in cask.apps {
                    claimed[app, default: 0] += 1
                    index[app] = cask
                }
            }
        }
        for (app, count) in claimed where count > 1 { index[app] = nil }
        return index
    }

    static func cask(token: String, receipt path: String) -> HomebrewCask? {
        guard let data = FileManager.default.contents(atPath: path),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]] else { return nil }
        var apps: [String] = []
        var more = false
        for artifact in artifacts {
            if let arguments = artifact["app"] as? [Any], let source = arguments.first as? String {
                let target = arguments.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
                apps.append(((target ?? source) as NSString).lastPathComponent)
            }
            if artifact["suite"] != nil || artifact["pkg"] != nil { more = true }
        }
        return apps.isEmpty ? nil : HomebrewCask(token: token, apps: apps, installsMore: more)
    }

    /// Bundles that have a process running right now, for callers without AppKit.
    public static func runningBundlePaths() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var bundles = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
            if let bundle = AppGrouping.appBundle(in: path) { bundles.insert(bundle) }
        }
        return bundles
    }

    /// Whether LaunchServices knows an app with this id anywhere but the Trash.
    public static func launchServicesHasApp(_ bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
        return urls.contains { url in
            let path = url.path
            return !path.contains("/.Trash/") && FileManager.default.fileExists(atPath: path)
        }
    }
}
