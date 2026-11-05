import Darwin
import Foundation

/// macOS installers in /Applications and installer files left in Downloads, Desktop and Documents.
public struct InstallerScanner: CleanScanner {
    static let group = "Installers"

    static let kinds: [String: String] = [
        "dmg": "A disk image, usually an app download. Once the app is in Applications it is no longer needed.",
        "pkg": "An installer package. Once installed it is no longer needed.",
        "mpkg": "An installer package. Once installed it is no longer needed.",
        "ipsw": "A system image. Only needed to set up a Mac, a device or a virtual machine.",
        "xip": "A signed archive, often an Xcode download. Once expanded it is no longer needed.",
    ]

    /// Bundles that are not walked into.
    static let packages: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "xcarchive", "framework",
                                        "bundle", "sparsebundle", "pkg", "mpkg", "imovielibrary", "logicx"]

    /// Folders a build writes into. A .pkg or .dmg there is the project's own output, not a download.
    static let buildFolders: Set<String> = ["build", "builds", "dist", "out", "target", "deriveddata", "node_modules", "pods", "carthage"]

    public var tab: CleanTab { .junk }
    public var minimumBytes: Int64
    public var applications: String
    public var depth: Int
    /// Downloads, Desktop and Documents need Full Disk Access; without it macOS asks the owner.
    public var readsGuardedFolders: @Sendable () -> Bool

    public init(minimumBytes: Int64 = 1 << 20, applications: String = "/Applications", depth: Int = 3,
                readsGuardedFolders: @escaping @Sendable () -> Bool = { StorageAccess.hasFullDiskAccess }) {
        self.minimumBytes = minimumBytes
        self.applications = applications
        self.depth = depth
        self.readsGuardedFolders = readsGuardedFolders
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let sizer = CleanSizer(context)
        var items: [CleanItem] = []

        let installers = CleanFiles.names(applications).filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }.sorted()
        for name in installers {
            let path = applications + "/" + name
            guard !context.isBlocked(path), !sizer.cancelled else { continue }
            let size = sizer.size(path)
            guard size.bytes >= minimumBytes else { continue }
            items.append(CleanItem(id: "installer:\(path)", tab: .junk, group: Self.group, name: String(name.dropLast(4)),
                                   detail: "The macOS installer. Only needed to install that version again, and the App Store has it.",
                                   paths: [path], bytes: size.bytes, modified: size.modified, safety: .checkFirst,
                                   checkedByDefault: false))
        }
        if !items.isEmpty { context.found(items) }

        guard readsGuardedFolders() else { return items }
        for folder in ["Downloads", "Desktop", "Documents"] {
            var found: [String] = []
            collect(context.homePath + "/" + folder, depth: 0, context: context, into: &found)
            let sizes = sizer.sizes(found)
            var batch: [CleanItem] = []
            for path in found {
                guard let size = sizes[path], size.bytes >= minimumBytes else { continue }
                let ext = (path as NSString).pathExtension.lowercased()
                batch.append(CleanItem(id: "installer:\(path)", tab: .junk, group: Self.group, name: (path as NSString).lastPathComponent,
                                       detail: Self.kinds[ext] ?? "", paths: [path], bytes: size.bytes, modified: size.modified,
                                       safety: .checkFirst, checkedByDefault: false))
            }
            if !batch.isEmpty { context.found(batch) }
            items += batch
        }
        return items
    }

    private func collect(_ folder: String, depth level: Int, context: CleanScanContext, into found: inout [String]) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // A folder with more entries than this holds data, not downloads worth sorting through.
        guard !context.isCancelled(), let entries = CleanFiles.entries(folder, limit: 10_000, dates: false, buffer: &buffer) else { return }
        // A git working tree holds a project, and its installers are what it builds or ships.
        if entries.contains(where: { $0.name == ".git" }) { return }
        var subfolders: [String] = []
        for entry in entries where !entry.name.hasPrefix(".") {
            let path = folder + "/" + entry.name
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if Self.kinds[ext] != nil, entry.isFile || entry.isFolder {
                if !context.isBlocked(path) && !isDataless(path) { found.append(path) }
            } else if entry.isFolder, !Self.packages.contains(ext), !Self.buildFolders.contains(entry.name.lowercased()),
                      !context.isExcluded(path) {
                subfolders.append(path)
            }
        }
        guard level < depth else { return }
        for subfolder in subfolders.sorted() { collect(subfolder, depth: level + 1, context: context, into: &found) }
    }

    /// A file whose contents are only in the cloud takes no space here.
    private func isDataless(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
