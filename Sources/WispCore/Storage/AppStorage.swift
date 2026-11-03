import Foundation
import Security

/// Where one app keeps things on disk: its bundle and the folders in Library that
/// carry its bundle id, name or app groups.
public struct AppStorage: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var name: String
        public var detail: String
        public var paths: [String]
        public var size: UInt64
        public var locked: Bool
    }

    public var parts: [Part]
    /// Cache folders Clear cache moves to the Trash, with their sizes.
    public var caches: [(path: String, size: UInt64)]
    public var measuredAt: Date

    public var total: UInt64 { parts.reduce(0) { $0 + $1.size } }
    public var cacheSize: UInt64 { caches.reduce(0) { $0 + $1.size } }

    public static func == (a: AppStorage, b: AppStorage) -> Bool {
        a.parts == b.parts && a.caches.map(\.path) == b.caches.map(\.path) && a.cacheSize == b.cacheSize
    }

    /// Measures every place the app at `bundlePath` uses. A few folder walks; run it off the main thread.
    public static func measure(bundlePath: String, home: String = NSHomeDirectory(),
                               fullDiskAccess: Bool = StorageAccess.hasFullDiskAccess) -> AppStorage {
        let bundle = Bundle(path: bundlePath)
        let id = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var rules = FolderScanner.Rules()
        rules.skip = StorageAccess.skipped(home: home)
        let scanner = FolderScanner(rules: rules)
        let library = home + "/Library"
        let fm = FileManager.default

        func measure(_ paths: [String]) -> (UInt64, [String]) {
            var total: UInt64 = 0
            var found: [String] = []
            for path in Set(paths) {
                var isFolder: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isFolder) else { continue }
                found.append(path)
                if isFolder.boolValue {
                    total += scanner.folder(at: path).size
                } else {
                    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    total += UInt64(values?.totalFileAllocatedSize ?? 0)
                }
            }
            return (total, found.sorted())
        }

        var parts: [Part] = []
        func add(_ name: String, _ detail: String, _ paths: [String], locked: Bool = false) {
            if locked {
                let exists = paths.contains { fm.fileExists(atPath: $0) }
                if exists { parts.append(Part(name: name, detail: detail, paths: paths, size: 0, locked: true)) }
                return
            }
            let (size, found) = measure(paths)
            if !found.isEmpty { parts.append(Part(name: name, detail: detail, paths: found, size: size, locked: false)) }
        }

        let (appSize, _) = measure([bundlePath])
        parts.append(Part(name: "App", detail: "The app itself", paths: [bundlePath], size: appSize, locked: false))
        var caches: [(String, UInt64)] = []
        if let id {
            let container = library + "/Containers/" + id
            let containerCaches = container + "/Data/Library/Caches"
            if fullDiskAccess {
                let (total, found) = measure([container])
                let (cacheInContainer, _) = measure([containerCaches])
                if !found.isEmpty {
                    parts.append(Part(name: "Container", detail: "Its documents, settings and data in the sandbox", paths: found,
                                      size: total > cacheInContainer ? total - cacheInContainer : 0, locked: false))
                }
                if cacheInContainer > 0 { caches.append((containerCaches, cacheInContainer)) }
                let groups = appGroups(bundlePath).map { library + "/Group Containers/" + $0 }
                add("Group containers", "Data it shares with apps from the same developer", groups)
            } else {
                add("Container", "Needs Full Disk Access to measure", [container], locked: true)
                add("Group containers", "Needs Full Disk Access to measure", appGroups(bundlePath).map { library + "/Group Containers/" + $0 }, locked: true)
            }
            add("Application Support", "Databases, downloads and settings", [library + "/Application Support/" + id, library + "/Application Support/" + name])
            for path in [library + "/Caches/" + id, library + "/Caches/" + name] where fm.fileExists(atPath: path) {
                caches.append((path, measure([path]).0))
            }
            add("Logs", "Records it keeps for problems", [library + "/Logs/" + id, library + "/Logs/" + name])
            add("Website data", "Cookies and site storage", [library + "/WebKit/" + id, library + "/HTTPStorages/" + id])
            var preferences = [library + "/Preferences/" + id + ".plist"]
            if let byHost = try? fm.contentsOfDirectory(atPath: library + "/Preferences/ByHost") {
                preferences += byHost.filter { $0.hasPrefix(id + ".") }.map { library + "/Preferences/ByHost/" + $0 }
            }
            add("Preferences", "Its settings", preferences)
            add("Saved Application State", "Windows macOS reopens at launch", [library + "/Saved Application State/" + id + ".savedState"])
        }
        let cacheTotal = caches.reduce(UInt64(0)) { $0 + $1.1 }
        if cacheTotal > 0 || !caches.isEmpty {
            parts.insert(Part(name: "Caches", detail: "It makes these again as needed", paths: caches.map(\.0), size: cacheTotal, locked: false),
                         at: min(parts.count, 2))
        }
        return AppStorage(parts: parts, caches: caches.map { (path: $0.0, size: $0.1) }, measuredAt: Date())
    }

    /// App groups from the app's code signature, which name its folders in Group Containers.
    static func appGroups(_ bundlePath: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
