import Foundation

/// Decides which app row a process belongs to.
///
/// The kernel already tracks who is responsible for a process (the app that
/// launched an XPC service, the terminal that ran a shell command), so grouping
/// starts from the responsible process's executable path:
/// - inside an .app bundle: the outermost bundle, unless the inner one is an app in
///   its own right that the outer one ships (Xcode's Simulator, Instruments);
/// - under the OS's own directories: the shared "macOS" row, except WindowServer,
///   which is big enough to want its own;
/// - anything else: a row named after the executable.
public enum AppGrouping {
    public struct Identity: Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: AppKind
        public var bundlePath: String?
    }

    public static let systemID = "system"

    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/", "/Library/Developer/CommandLineTools/"]
    static let standaloneNestedApps = [["Contents", "Applications"], ["Contents", "Developer", "Applications"]]

    public static func identity(path: String?, name: String) -> Identity {
        guard let path, !path.isEmpty else {
            return Identity(id: systemID, name: "macOS", kind: .system)
        }
        if let bundle = appBundle(in: path) {
            if bundle.hasPrefix("/System/") && !bundle.hasPrefix("/System/Applications/") && !bundle.hasPrefix("/System/Library/CoreServices/") {
                return Identity(id: systemID, name: "macOS", kind: .system)
            }
            let fileName = (bundle as NSString).lastPathComponent
            return Identity(id: bundle, name: String(fileName.dropLast(4)), kind: .app, bundlePath: bundle)
        }
        if path.hasSuffix("/WindowServer") {
            return Identity(id: "windowserver", name: "WindowServer", kind: .system)
        }
        if systemPrefixes.contains(where: path.hasPrefix) {
            return Identity(id: systemID, name: "macOS", kind: .system)
        }
        let executable = (path as NSString).lastPathComponent
        return Identity(id: "tool:" + path, name: executable.isEmpty ? name : executable, kind: .tool)
    }

    /// The app bundle a path belongs to, or nil.
    public static func appBundle(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var bundleEnd: Int?
        for index in parts.indices where parts[index].hasSuffix(".app") {
            guard let outer = bundleEnd else {
                bundleEnd = index
                continue
            }
            let between = parts[(outer + 1)..<index].map(String.init)
            if standaloneNestedApps.contains(between) { bundleEnd = index }
        }
        guard let bundleEnd else { return nil }
        return parts[...bundleEnd].joined(separator: "/")
    }

    /// Sums process rows into app rows, ordered by CPU.
    public static func group(_ rows: [ProcessRow], names: (String) -> (name: String, kind: AppKind, bundlePath: String?, bundleIdentifier: String?)) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        groups.reserveCapacity(96)
        for row in rows {
            if var group = groups[row.groupID] {
                group.pids.append(row.pid)
                group.cpu += row.cpu
                group.memory += row.memory
                group.watts += row.watts
                group.diskReadPerSecond += row.diskReadPerSecond
                group.diskWritePerSecond += row.diskWritePerSecond
                group.networkInPerSecond += row.networkInPerSecond
                group.networkOutPerSecond += row.networkOutPerSecond
                group.wakeupsPerSecond += row.wakeupsPerSecond
                if !row.readable { group.unreadable += 1 }
                groups[row.groupID] = group
            } else {
                let info = names(row.groupID)
                groups[row.groupID] = AppGroup(id: row.groupID, name: info.name, kind: info.kind,
                                               bundlePath: info.bundlePath, bundleIdentifier: info.bundleIdentifier,
                                               pids: [row.pid], cpu: row.cpu, memory: row.memory, watts: row.watts,
                                               diskReadPerSecond: row.diskReadPerSecond, diskWritePerSecond: row.diskWritePerSecond,
                                               networkInPerSecond: row.networkInPerSecond, networkOutPerSecond: row.networkOutPerSecond,
                                               unreadable: row.readable ? 0 : 1, wakeupsPerSecond: row.wakeupsPerSecond)
            }
        }
        return groups.values.sorted { ($0.cpu, $0.memory, $1.name) > ($1.cpu, $1.memory, $0.name) }
    }
}
