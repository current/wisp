import Foundation
import Security

/// Something that starts with the Mac or the user's session: a launchd agent or
/// daemon, or a login item helper that an app ships inside its bundle.
public struct LaunchItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case loginItem, agent, daemon

        public var title: String {
            switch self {
            case .loginItem: return "Login item"
            case .agent: return "Agent"
            case .daemon: return "Daemon"
            }
        }
    }

    /// Where the item is defined.
    public enum Scope: String, Sendable {
        /// ~/Library/LaunchAgents
        case user
        /// /Library/LaunchAgents or /Library/LaunchDaemons
        case allUsers
        /// Inside an app bundle, registered by the app with launchd
        case app
        /// /System/Library
        case system
    }

    /// The file that defines the item: its plist, or the helper app for a login item.
    public var id: String { path }
    public var path: String
    public var label: String
    public var kind: Kind
    public var scope: Scope
    /// The executable launchd runs, as an absolute path when one could be worked out.
    public var program: String?
    public var programExists: Bool
    /// The script an interpreter runs (`/bin/sh /path/run.sh`), when there is one.
    public var script: String?
    public var scriptExists = true
    /// The app the item belongs to, if it could be found.
    public var appPath: String?
    public var associatedBundleIDs: [String] = []
    /// The plist names apps that are not installed any more.
    public var appMissing = false
    public var runAtLoad = false
    public var keepAlive = false
    /// KeepAlive given as conditions (network up, path exists) rather than always.
    public var keepAliveConditional = false
    public var startInterval: Int?
    public var calendar: [[String: Int]] = []
    public var watchPaths: [String] = []
    public var onDemand = false
    public var disabledInPlist = false

    public var isApple: Bool {
        label.hasPrefix("com.apple.") || path.hasPrefix("/System/") || (program?.hasPrefix("/System/") ?? false)
    }

    /// The program is gone, or the app it came with is.
    public var isLeftover: Bool {
        if let program, program.hasPrefix("/"), !programExists { return true }
        if script != nil, !scriptExists { return true }
        return appMissing
    }

    /// The file that says who made the item: the app, else the script, else the program.
    public var signedPath: String? { appPath ?? script ?? program }

    static let interpreters: Set<String> = ["sh", "bash", "zsh", "env", "python", "python3", "node", "ruby", "perl", "osascript", "bun", "deno", "uv"]

    /// A per-user agent whose program no longer exists: safe to move to the Trash.
    public var canTrash: Bool {
        guard scope == .user, kind == .agent, let program, program.hasPrefix("/") else { return false }
        guard !programExists || (script != nil && !scriptExists) else { return false }
        return path.hasPrefix(NSHomeDirectory() + "/Library/LaunchAgents/")
    }

    /// A short name for people: the owning app's name, else the label's last useful part.
    public var name: String {
        if kind == .loginItem { return ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        if let script { return (script as NSString).lastPathComponent }
        if program?.hasSuffix("/open") == true, let appPath {
            return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        if let program, program.hasPrefix("/") {
            let file = (program as NSString).lastPathComponent
            if !file.isEmpty, !Self.interpreters.contains(file), file != "open" { return file }
        }
        return label
    }

    /// When launchd starts it, in a few words.
    public var schedule: String {
        var parts: [String] = []
        if runAtLoad || kind == .loginItem { parts.append(kind == .daemon ? "At startup" : "At login") }
        if keepAlive { parts.append(keepAliveConditional ? "restarted when needed" : "kept running") }
        if let startInterval, startInterval > 0 { parts.append("every " + Self.interval(startInterval)) }
        if !calendar.isEmpty { parts.append(Self.calendarText(calendar)) }
        if let watched = watchPaths.first {
            parts.append("when \((watched as NSString).lastPathComponent) changes")
        }
        if parts.isEmpty { return "When asked" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func interval(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return seconds == 86_400 ? "day" : "\(seconds / 86_400) days" }
        if seconds % 3600 == 0 { return seconds == 3600 ? "hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "minute" : "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    static func calendarText(_ entries: [[String: Int]]) -> String {
        guard entries.count == 1, let entry = entries.first else { return "on a schedule" }
        let time = entry["Hour"].map { String(format: "%d:%02d", $0, entry["Minute"] ?? 0) }
        if let weekday = entry["Weekday"] {
            let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
            let day = names.indices.contains(weekday) ? names[weekday] : "weekly"
            return time.map { "\(day) at \($0)" } ?? day
        }
        if entry["Day"] != nil { return time.map { "monthly at \($0)" } ?? "monthly" }
        if let time { return "daily at \(time)" }
        if let minute = entry["Minute"] { return "hourly at :\(String(format: "%02d", minute))" }
        return "on a schedule"
    }
}

/// What launchd has loaded right now, from `launchctl print`.
public struct LaunchdState: Sendable, Equatable {
    /// Label to pid; 0 when loaded but not running.
    public var pids: [String: Int32] = [:]
    /// Labels switched on or off in System Settings (Login Items & Extensions) or with launchctl.
    public var enabled: [String: Bool] = [:]

    public init(pids: [String: Int32] = [:], enabled: [String: Bool] = [:]) {
        self.pids = pids
        self.enabled = enabled
    }

    public enum Status: String, Sendable { case running, loaded, off, notLoaded }

    public func status(of item: LaunchItem) -> Status {
        if let pid = pids[item.label] { return pid > 0 ? .running : .loaded }
        if enabled[item.label] == false || item.disabledInPlist { return .off }
        return .notLoaded
    }

    /// Whether launchd has heard of the label at all.
    public func knows(_ label: String) -> Bool { pids[label] != nil || enabled[label] != nil }

    public mutating func merge(_ other: LaunchdState) {
        pids.merge(other.pids) { max($0, $1) }
        enabled.merge(other.enabled) { a, _ in a }
    }

    /// Parses the output of `launchctl print gui/<uid>` or `launchctl print system`.
    public static func parse(_ text: String) -> LaunchdState {
        var state = LaunchdState()
        enum Block { case none, services, disabled }
        var block = Block.none
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\t") && !raw.hasPrefix("\t\t") {
                if line == "services = {" { block = .services; continue }
                if line == "disabled services = {" { block = .disabled; continue }
                if line == "}" { block = .none; continue }
                if line.hasSuffix("= {") { block = .none; continue }
            }
            switch block {
            case .none:
                continue
            case .services:
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }
                state.pids[String(fields[2...].joined(separator: " "))] = pid
            case .disabled:
                // "label" => enabled
                guard let arrow = line.range(of: "\" => ") else { continue }
                let label = line[line.index(after: line.startIndex)..<arrow.lowerBound]
                state.enabled[String(label)] = line[arrow.upperBound...].hasPrefix("enabled")
            }
        }
        return state
    }

    /// Reads the user's GUI domain and the system domain. Two `launchctl` runs, about 10 ms in all.
    public static func read() -> LaunchdState {
        var state = parse(run(["print", "gui/\(getuid())"]))
        state.merge(parse(run(["print", "system"])))
        return state
    }

    static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Who signed a program, from its code signature.
public struct Signer: Sendable, Equatable {
    public var team: String?
    /// The certificate's name, without "Developer ID Application:" and the team id.
    public var name: String?
    public var apple: Bool

    public init(team: String? = nil, name: String? = nil, apple: Bool = false) {
        self.team = team
        self.name = name
        self.apple = apple
    }

    /// Unsigned or signed ad hoc: no developer Apple knows of.
    public var unknown: Bool { !apple && team == nil }

    public var title: String {
        if apple { return "Apple" }
        if let name { return name }
        return team ?? "Unknown developer"
    }

    /// Reads the signature without checking it, which keeps it to a millisecond or so.
    public static func read(path: String) -> Signer? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return Signer() }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let platform = (dict[kSecCodeInfoPlatformIdentifier as String] as? NSNumber)?.intValue ?? 0
        var name: String?
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            name = cleanName(summary)
        }
        let apple = platform != 0 || (team == nil && name == "Software Signing")
        return Signer(team: team, name: name, apple: apple)
    }

    static func cleanName(_ summary: String) -> String {
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
        return name
    }
}

/// Finds launch items by reading plists and app bundles. Needs no privileges.
public final class LaunchItemScanner: @unchecked Sendable {
    public struct Locations: Sendable {
        public var userAgents: String
        public var agents: String
        public var daemons: String
        public var systemAgents: String
        public var systemDaemons: String
        /// Folders holding apps; each is read one level deep, plus folders of apps inside it.
        public var appFolders: [String]

        public static var standard: Locations {
            let home = NSHomeDirectory()
            return Locations(userAgents: home + "/Library/LaunchAgents", agents: "/Library/LaunchAgents", daemons: "/Library/LaunchDaemons",
                             systemAgents: "/System/Library/LaunchAgents", systemDaemons: "/System/Library/LaunchDaemons",
                             appFolders: ["/Applications", home + "/Applications"])
        }

        public init(userAgents: String, agents: String, daemons: String, systemAgents: String, systemDaemons: String, appFolders: [String]) {
            self.userAgents = userAgents
            self.agents = agents
            self.daemons = daemons
            self.systemAgents = systemAgents
            self.systemDaemons = systemDaemons
            self.appFolders = appFolders
        }
    }

    public struct Result: Sendable {
        public var items: [LaunchItem]
        /// Items that apps ship but launchd has not been asked to run.
        public var dormant: Int
    }

    let locations: Locations
    private let fileManager = FileManager()

    public init(locations: Locations = .standard) {
        self.locations = locations
    }

    /// Every item that starts with this Mac. App-embedded helpers count only when
    /// launchd knows their label, as an app has to register them first.
    /// `appForBundleID` finds apps outside the scanned folders.
    public func scan(includeApple: Bool, state: LaunchdState, appForBundleID: (String) -> String? = { _ in nil },
                     cancelled: () -> Bool = { false }) -> Result {
        let apps = installedApps()
        func lookup(_ id: String) -> String? { apps[id] ?? appForBundleID(id) }
        var items: [LaunchItem] = []
        var folders: [(String, LaunchItem.Kind, LaunchItem.Scope)] = [
            (locations.userAgents, .agent, .user), (locations.agents, .agent, .allUsers), (locations.daemons, .daemon, .allUsers),
        ]
        if includeApple { folders += [(locations.systemAgents, .agent, .system), (locations.systemDaemons, .daemon, .system)] }
        for (folder, kind, scope) in folders {
            for file in plists(in: folder) {
                if cancelled() { return Result(items: [], dormant: 0) }
                guard let item = Self.item(plistAt: file, kind: kind, scope: scope, lookup: lookup) else { continue }
                if !includeApple, item.isApple { continue }
                items.append(item)
            }
        }
        var labels = Set(items.map(\.label))
        var dormant = 0
        for app in apps.values.sorted() {
            if cancelled() { return Result(items: [], dormant: 0) }
            for item in embedded(in: app, lookup: lookup) where !labels.contains(item.label) {
                if !includeApple, item.isApple { continue }
                guard state.knows(item.label) else {
                    dormant += 1
                    continue
                }
                labels.insert(item.label)
                items.append(item)
            }
        }
        return Result(items: items, dormant: dormant)
    }

    /// Bundle id to app path for the apps in the app folders.
    func installedApps() -> [String: String] {
        var apps: [String: String] = [:]
        for folder in locations.appFolders {
            for path in children(of: folder) {
                if path.hasSuffix(".app") {
                    if let id = Self.bundleID(path) { apps[id] = apps[id] ?? path }
                } else if !path.hasPrefix(".") {
                    for inner in children(of: path) where inner.hasSuffix(".app") {
                        if let id = Self.bundleID(inner) { apps[id] = apps[id] ?? inner }
                    }
                }
            }
        }
        return apps
    }

    /// Login item helpers and launchd plists an app carries inside its bundle.
    func embedded(in app: String, lookup: (String) -> String?) -> [LaunchItem] {
        var items: [LaunchItem] = []
        let library = app + "/Contents/Library"
        for helper in children(of: library + "/LoginItems") where helper.hasSuffix(".app") {
            guard let id = Self.bundleID(helper) else { continue }
            let executable = Self.executable(helper)
            var item = LaunchItem(path: helper, label: id, kind: .loginItem, scope: .app, program: executable,
                                  programExists: executable.map { fileManager.fileExists(atPath: $0) } ?? false)
            item.appPath = app
            item.runAtLoad = true
            items.append(item)
        }
        for (folder, kind) in [("LaunchAgents", LaunchItem.Kind.agent), ("LaunchDaemons", .daemon)] {
            for file in plists(in: library + "/" + folder) {
                guard var item = Self.item(plistAt: file, kind: kind, scope: .app, host: app, lookup: lookup) else { continue }
                item.appPath = item.appPath ?? app
                items.append(item)
            }
        }
        return items
    }

    /// Reads one launchd plist. `host` is the app for plists inside a bundle, where
    /// BundleProgram is relative to the bundle.
    static func item(plistAt path: String, kind: LaunchItem.Kind, scope: LaunchItem.Scope, host: String? = nil,
                     lookup: (String) -> String?) -> LaunchItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return item(plist: plist, path: path, kind: kind, scope: scope, host: host, lookup: lookup)
    }

    static func item(plist: [String: Any], path: String, kind: LaunchItem.Kind, scope: LaunchItem.Scope, host: String? = nil,
                     lookup: (String) -> String?, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LaunchItem? {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        var program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        if let bundleProgram = plist["BundleProgram"] as? String, let host {
            program = (host as NSString).appendingPathComponent(bundleProgram)
        }
        if let value = program, value.hasPrefix("~/") { program = NSHomeDirectory() + value.dropFirst() }
        let absolute = program.map { $0.hasPrefix("/") } ?? false
        var item = LaunchItem(path: path, label: label, kind: kind, scope: scope, program: program,
                              programExists: absolute && exists(program!))
        if let program, program.hasSuffix("/open"), let arguments = plist["ProgramArguments"] as? [String],
           let app = arguments.dropFirst().first(where: { $0.hasSuffix(".app") || $0.hasSuffix(".app/") }) {
            // `open -g /Applications/Some.app`: the item launches that app.
            let full = app.hasPrefix("~/") ? NSHomeDirectory() + app.dropFirst() : app
            item.appPath = full.hasSuffix("/") ? String(full.dropLast()) : full
            if full.hasPrefix("/"), !exists(full) { item.appMissing = true }
        } else if let program, let arguments = plist["ProgramArguments"] as? [String],
           LaunchItem.interpreters.contains((program as NSString).lastPathComponent) {
            // The first argument that names a file is the script, after any flags and `env` names.
            let candidates = arguments.dropFirst().filter { !$0.hasPrefix("-") && !$0.contains("=") }
            if let script = candidates.first(where: { $0.hasPrefix("/") || $0.hasPrefix("~/") }) {
                let full = script.hasPrefix("~/") ? NSHomeDirectory() + script.dropFirst() : script
                item.script = full
                item.scriptExists = exists(full)
            }
        }
        item.associatedBundleIDs = plist["AssociatedBundleIdentifiers"] as? [String]
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        if let program, absolute, let bundle = AppGrouping.appBundle(in: program) {
            item.appPath = bundle
            if !item.programExists, !exists(bundle) { item.appMissing = true }
        }
        if item.appPath == nil, !item.associatedBundleIDs.isEmpty {
            let found = item.associatedBundleIDs.lazy.compactMap(lookup).first
            item.appPath = found
            if found == nil { item.appMissing = true }
        }
        item.runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        switch plist["KeepAlive"] {
        case let value as Bool:
            item.keepAlive = value
        case let value as [String: Any]:
            item.keepAlive = !value.isEmpty
            item.keepAliveConditional = true
        default:
            break
        }
        item.startInterval = (plist["StartInterval"] as? NSNumber)?.intValue
        switch plist["StartCalendarInterval"] {
        case let entry as [String: Any]: item.calendar = [entry.compactMapValues { ($0 as? NSNumber)?.intValue }]
        case let entries as [[String: Any]]: item.calendar = entries.map { $0.compactMapValues { ($0 as? NSNumber)?.intValue } }
        default: break
        }
        item.watchPaths = (plist["WatchPaths"] as? [String] ?? []) + (plist["QueueDirectories"] as? [String] ?? [])
        item.onDemand = plist["MachServices"] != nil || plist["Sockets"] != nil || plist["LaunchEvents"] != nil
        item.disabledInPlist = plist["Disabled"] as? Bool ?? false
        return item
    }

    static func bundleID(_ app: String) -> String? {
        guard let data = FileManager.default.contents(atPath: app + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    static func executable(_ app: String) -> String? {
        guard let data = FileManager.default.contents(atPath: app + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String else { return nil }
        return app + "/Contents/MacOS/" + name
    }

    private func children(of folder: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.map { folder + "/" + $0 }
    }

    private func plists(in folder: String) -> [String] {
        children(of: folder).filter { $0.hasSuffix(".plist") }
    }
}

/// An item joined with what it costs right now.
public struct LaunchItemCost: Sendable, Equatable {
    public var pids: [Int32] = []
    public var cpu: Double = 0
    public var memory: UInt64 = 0
    public var watts: Double = 0

    /// Processes launchd says it started, else processes running the item's program.
    public static func join(_ items: [LaunchItem], state: LaunchdState, table: ProcessTable) -> [String: LaunchItemCost] {
        var byPID: [Int32: Int] = [:]
        var byPath: [String: [Int]] = [:]
        for (index, row) in table.processes.enumerated() {
            byPID[row.pid] = index
            if let path = row.path { byPath[path, default: []].append(index) }
        }
        var costs: [String: LaunchItemCost] = [:]
        for item in items {
            var rows: [Int] = []
            if let pid = state.pids[item.label], pid > 0, let index = byPID[pid] { rows = [index] }
            if rows.isEmpty, let program = item.program { rows = byPath[program] ?? [] }
            guard !rows.isEmpty else { continue }
            var cost = LaunchItemCost()
            for index in rows {
                let row = table.processes[index]
                cost.pids.append(row.pid)
                cost.cpu += row.cpu
                cost.memory += row.memory
                cost.watts += row.watts
            }
            costs[item.id] = cost
        }
        return costs
    }
}
