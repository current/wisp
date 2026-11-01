import Foundation

/// One line in a breakdown: a known place, its size and when anything in it last changed.
public struct StorageRow: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var detail: String
    public var category: StorageCategory
    /// Nil when it could not be measured.
    public var size: UInt64?
    public var lastUsed: Date?
    /// The folders it is made of, largest first.
    public var paths: [String]
    public var count: Int
    public var locked: Bool
}

/// Something that can go to the Trash, with exactly which folders and how much.
public struct ReclaimItem: Codable, Sendable, Identifiable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var name: String
        public var size: UInt64
        public var lastUsed: Date?
    }

    public var id: String
    public var name: String
    /// A few words for the list.
    public var detail: String
    /// What happens once they are gone, for the confirmation.
    public var consequence: String
    public var entries: [Entry]
    public var size: UInt64 { entries.reduce(0) { $0 + $1.size } }
}

public struct StorageSummary: Codable, Sendable {
    public struct Segment: Codable, Sendable, Equatable {
        public var category: StorageCategory
        public var size: UInt64
        /// False for slices macOS does not size for us (snapshots) or that are what is left over.
        public var measured: Bool
    }

    public var date: Date
    public var volume: StorageVolume
    public var segments: [Segment]
    public var rows: [StorageRow]
    public var reclaimable: [ReclaimItem]
    public var snapshots: [LocalSnapshot]
    public var swap: SwapUsage?
    public var scannedAt: Date?
    /// Folders that were not read, absolute paths.
    public var locked: [String]
    public var fullDiskAccess: Bool

    public func segment(_ category: StorageCategory) -> Segment? { segments.first { $0.category == category } }
    public func rows(_ category: StorageCategory) -> [StorageRow] { rows.filter { $0.category == category } }
    public func row(_ id: String) -> StorageRow? { rows.first { $0.id == id } }
}

/// Turns scanned trees and the volume's figures into the bar, the breakdowns and
/// the list of what can go. Pure: everything it reads from disk comes in as closures.
public enum StorageAnalysis {
    public static let staleAfter: TimeInterval = 90 * 86_400

    public struct Input {
        public var volume: StorageVolume
        /// Scanned trees by absolute root path.
        public var roots: [String: FolderNode]
        public var home: String
        public var snapshots: [LocalSnapshot]
        public var swap: SwapUsage?
        public var scannedAt: Date?
        public var fullDiskAccess: Bool
        public var now: Date
        /// Whether a file exists, for telling a Rust `target` from any folder named target.
        public var exists: (String) -> Bool
        /// A simulator's name from its folder.
        public var deviceName: (String) -> String?

        public init(volume: StorageVolume, roots: [String: FolderNode], home: String = NSHomeDirectory(), snapshots: [LocalSnapshot] = [],
                    swap: SwapUsage? = nil, scannedAt: Date? = nil, fullDiskAccess: Bool = true, now: Date = Date(),
                    exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                    deviceName: @escaping (String) -> String? = { _ in nil }) {
            self.volume = volume
            self.roots = roots
            self.home = home
            self.snapshots = snapshots
            self.swap = swap
            self.scannedAt = scannedAt
            self.fullDiskAccess = fullDiskAccess
            self.now = now
            self.exists = exists
            self.deviceName = deviceName
        }
    }

    private struct Found {
        var path: String
        var node: FolderNode
    }

    private final class Tally {
        var rowSize: [String: UInt64] = [:]
        var rowEntries: [String: [Found]] = [:]
        var rowLocked: Set<String> = []
        var category: [StorageCategory: UInt64] = [:]
        var locked: [String] = []
        var staleModules: [ReclaimItem.Entry] = []
        var artifactTitles: [String: (String, String)] = [:]
    }

    public static func summarize(_ input: Input) -> StorageSummary {
        let tally = Tally()
        for (root, node) in input.roots {
            if root == input.home {
                walkHome(node, input: input, tally: tally)
            } else if root.hasPrefix("/private/var/folders/") {
                let rule = StorageCatalog.temporary
                tally.rowEntries[rule.row, default: []].append(Found(path: root, node: node))
                visit(node, path: root, relative: nil, inherited: (rule.category, rule.row), parent: nil, input: input, tally: tally)
            } else if let rule = StorageCatalog.rules[root] {
                visit(node, path: root, relative: nil, inherited: (rule.category, rule.row), parent: nil, input: input, tally: tally)
            }
        }

        let volume = input.volume
        var segments: [StorageSummary.Segment] = []
        let measured: [StorageCategory] = [.apps, .developer, .documents, .mail]
        var counted: UInt64 = 0
        for category in measured {
            let size = tally.category[category] ?? 0
            counted += size
            segments.append(.init(category: category, size: size, measured: true))
        }
        let purgeable = volume.purgeable
        let taken = counted + purgeable + volume.available
        let system = volume.capacity > taken ? volume.capacity - taken : 0
        segments.insert(.init(category: .system, size: system, measured: false), at: 4)
        segments.append(.init(category: .snapshots, size: 0, measured: false))
        segments.append(.init(category: .purgeable, size: purgeable, measured: true))
        segments.append(.init(category: .free, size: volume.available, measured: true))

        var rows: [StorageRow] = []
        func add(_ id: String, _ name: String, _ detail: String, _ category: StorageCategory, size: UInt64?) {
            let entries = (tally.rowEntries[id] ?? []).sorted { $0.node.size > $1.node.size }
            let last = entries.map(\.node.modified).max().flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            rows.append(StorageRow(id: id, name: name, detail: detail, category: category, size: size, lastUsed: last,
                                   paths: entries.prefix(400).map(\.path), count: entries.count, locked: tally.rowLocked.contains(id)))
        }

        // Every scanned row, in the catalog's order.
        var seen: Set<String> = []
        for location in StorageCatalog.places + [StorageCatalog.temporary] + StorageCatalog.developer where !seen.contains(location.row) {
            seen.insert(location.row)
            guard let size = tally.rowSize[location.row], size > 0 || tally.rowLocked.contains(location.row) else { continue }
            add(location.row, location.name, location.detail, location.category, size: size)
        }
        for (row, (title, detail)) in tally.artifactTitles.sorted(by: { $0.key < $1.key }) {
            add(row, title, detail, .developer, size: tally.rowSize[row] ?? 0)
        }
        for (id, name, detail, category) in [("code", "Projects and code", "Your code folders, without the build output listed under Developer", StorageCategory.documents),
                                             ("otherfiles", "Other folders in your home", "", .documents),
                                             ("homefiles", "Files in your home folder", "", .documents),
                                             ("hidden", "Hidden folders in your home", "Settings and data tools keep in dot folders", .system)] {
            if let size = tally.rowSize[id], size > 0 { add(id, name, detail, category, size: size) }
        }

        // What macOS lumps into System Data and Wisp can put a number on without a scan.
        var systemFixed: [StorageRow] = []
        if let size = volume.systemVolume { systemFixed.append(row("macos", "macOS", "The sealed system volume. Updates replace it as a whole", size)) }
        let preboot = (volume.preboot ?? 0) + (volume.update ?? 0) + volume.otherSystemVolumes
        if preboot > 0 { systemFixed.append(row("preboot", "Startup and update files", "What the Mac needs to start up and to install updates", preboot)) }
        if let vm = volume.vm {
            let note = input.swap.map { "Memory moved out to disk, \(Format.bytes($0.used)) of \(Format.bytes($0.total)) in use now" }
                ?? "Memory moved out to disk"
            systemFixed.append(row("vm", "Swap and sleep image", note, vm))
        }
        rows.insert(contentsOf: systemFixed, at: 0)
        let systemRows = rows.filter { $0.category == .system }
        let explained = systemRows.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
        if system > explained {
            let detail = tally.locked.isEmpty
                ? "Folders only an administrator can read, other accounts on this Mac and space APFS keeps for itself"
                : "Folders Wisp could not read, folders only an administrator can read and other accounts on this Mac"
            rows.append(row("unmeasured", "Not measured", detail, system - explained))
        }

        return StorageSummary(date: input.now, volume: volume, segments: segments, rows: rows,
                              reclaimable: reclaimable(input, tally: tally), snapshots: input.snapshots, swap: input.swap,
                              scannedAt: input.scannedAt, locked: tally.locked, fullDiskAccess: input.fullDiskAccess)
    }

    private static func row(_ id: String, _ name: String, _ detail: String, _ size: UInt64) -> StorageRow {
        StorageRow(id: id, name: name, detail: detail, category: .system, size: size, lastUsed: nil, paths: [], count: 0, locked: false)
    }

    private static func walkHome(_ home: FolderNode, input: Input, tally: Tally) {
        add(home.ownFiles + home.otherSize, row: "homefiles", category: .documents, tally: tally)
        for child in home.children where !child.isFile {
            let path = input.home + "/" + child.name
            let inherited: (StorageCategory, String)
            if child.name.hasPrefix(".") {
                inherited = (.system, "hidden")
            } else if StorageCatalog.codeFolders.contains(child.name) {
                inherited = (.documents, "code")
            } else {
                inherited = (.documents, "otherfiles")
            }
            visit(child, path: path, relative: child.name, inherited: inherited, parent: home, input: input, tally: tally)
        }
    }

    private static func add(_ size: UInt64, row: String, category: StorageCategory, tally: Tally) {
        tally.rowSize[row, default: 0] += size
        tally.category[category, default: 0] += size
    }

    private static func visit(_ node: FolderNode, path: String, relative: String?, inherited: (StorageCategory, String),
                              parent: FolderNode?, input: Input, tally: Tally) {
        var assigned = inherited
        if let rule = StorageCatalog.rules[relative ?? path] {
            assigned = (rule.category, rule.row)
            tally.rowEntries[rule.row, default: []].append(Found(path: path, node: node))
            if node.locked { tally.rowLocked.insert(rule.row) }
        } else if let relative, inherited.0 != .developer, !relative.hasPrefix("Library/"), let parent,
                  let artifact = artifact(node, path: path, input: input) {
            // Build output inside a project: the whole folder counts, nothing below it matters.
            tally.artifactTitles[artifact.row] = (artifact.title, artifact.detail)
            tally.rowEntries[artifact.row, default: []].append(Found(path: path, node: node))
            add(node.size, row: artifact.row, category: .developer, tally: tally)
            if artifact.row == "node_modules" {
                let active = projectActivity(parent)
                if active > 0, input.now.timeIntervalSince1970 - active > staleAfter {
                    tally.staleModules.append(.init(path: path, name: parent.name, size: node.size,
                                                    lastUsed: Date(timeIntervalSince1970: active)))
                }
            }
            return
        }
        if node.locked { tally.locked.append(path) }
        let folders = node.children.reduce(UInt64(0)) { $0 + ($1.isFile ? 0 : $1.size) }
        add(node.size > folders ? node.size - folders : 0, row: assigned.1, category: assigned.0, tally: tally)
        for child in node.children where !child.isFile {
            visit(child, path: path + "/" + child.name, relative: relative.map { $0 + "/" + child.name }, inherited: assigned,
                  parent: node, input: input, tally: tally)
        }
    }

    private static func artifact(_ node: FolderNode, path: String, input: Input) -> StorageCatalog.Artifact? {
        guard StorageCatalog.artifactNames.contains(node.name) else { return nil }
        let parentPath = String(path.dropLast(node.name.count + 1))
        for artifact in StorageCatalog.artifacts where artifact.name == node.name {
            if artifact.markers.isEmpty { return artifact }
            let base = artifact.markerInside ? path : parentPath
            if artifact.markers.contains(where: { input.exists(base + "/" + $0) }) { return artifact }
        }
        return nil
    }

    /// When a project last changed, leaving out what installs and builds write.
    static func projectActivity(_ project: FolderNode) -> Double {
        var latest = project.ownModified
        for child in project.children where !StorageCatalog.artifactNames.contains(child.name) && child.name != ".git" {
            latest = max(latest, child.modified)
        }
        return latest
    }

    private static func reclaimable(_ input: Input, tally: Tally) -> [ReclaimItem] {
        let home = input.roots[input.home]
        let cutoff = input.now.timeIntervalSince1970 - staleAfter
        var items: [ReclaimItem] = []
        func entries(_ relative: String, minimum: UInt64, olderThan: Double? = nil, name: ((String, FolderNode) -> String)? = nil,
                     exclude: (String) -> Bool = { _ in false }) -> [ReclaimItem.Entry] {
            guard let folder = home?.descendant(relative) else { return [] }
            return folder.children.filter { child in
                !child.isFile && !child.locked && child.size >= minimum && !exclude(child.name)
                    && (olderThan.map { child.modified > 0 && child.modified < $0 } ?? true)
            }.map { child in
                let path = input.home + "/" + relative + "/" + child.name
                return .init(path: path, name: name?(path, child) ?? child.name, size: child.size,
                             lastUsed: child.modified > 0 ? Date(timeIntervalSince1970: child.modified) : nil)
            }
        }
        func whole(_ relative: String, minimum: UInt64) -> [ReclaimItem.Entry] {
            guard let node = home?.descendant(relative), !node.locked, node.size >= minimum else { return [] }
            return [.init(path: input.home + "/" + relative, name: node.name, size: node.size,
                          lastUsed: node.modified > 0 ? Date(timeIntervalSince1970: node.modified) : nil)]
        }
        let developerCaches = Set(StorageCatalog.developer.flatMap(\.paths).filter { $0.hasPrefix("Library/Caches/") }
            .map { String($0.dropFirst("Library/Caches/".count)) })
        let caches = entries("Library/Caches", minimum: 50 << 20) { name in developerCaches.contains(name) || name.hasPrefix("com.apple.") }
        items.append(ReclaimItem(id: "caches", name: "App caches", detail: "Apps make these again", consequence: "Apps make their caches again as needed. Quit an app before clearing its cache",
                                 entries: caches))
        items.append(ReclaimItem(id: "backups", name: "Old device backups", detail: "Not updated in 90 days", consequence: "These iPhone and iPad backups have not been updated in 90 days",
                                 entries: entries("Library/Application Support/MobileSync/Backup", minimum: 1 << 20, olderThan: cutoff)))
        items.append(ReclaimItem(id: "deriveddata", name: "Xcode DerivedData", detail: "Xcode builds it again", consequence: "Xcode makes it again; the next build of each project takes longer",
                                 entries: whole("Library/Developer/Xcode/DerivedData", minimum: 10 << 20)))
        items.append(ReclaimItem(id: "archives", name: "Old Xcode archives", detail: "Older than 90 days",
                                 consequence: "Their debug symbols go too, so crash reports from those builds can no longer be read",
                                 entries: entries("Library/Developer/Xcode/Archives", minimum: 1 << 20, olderThan: cutoff)))
        items.append(ReclaimItem(id: "simulators", name: "Unused simulators", detail: "Not used in 90 days", consequence: "Each simulator goes with the apps and data in it",
                                 entries: entries("Library/Developer/CoreSimulator/Devices", minimum: 10 << 20, olderThan: cutoff,
                                                  name: { path, node in input.deviceName(path) ?? node.name })))
        items.append(ReclaimItem(id: "homebrew", name: "Homebrew downloads", detail: "brew fetches them again", consequence: "brew downloads them again when it needs them",
                                 entries: whole("Library/Caches/Homebrew", minimum: 10 << 20)))
        items.append(ReclaimItem(id: "node_modules", name: "Old node_modules", detail: "Projects untouched for 90 days",
                                 consequence: "npm install brings them back when you return to a project",
                                 entries: tally.staleModules.filter { $0.size >= 1 << 20 }.sorted { $0.size > $1.size }))
        return items.filter { !$0.entries.isEmpty }
    }
}
