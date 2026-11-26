import Foundation

/// Logs, crash reports and device software updates in the home folder.
public struct SystemJunkScanner: CleanScanner {
    static let group = "System junk"

    public var tab: CleanTab { .junk }
    public var minimumBytes: Int64

    public init(minimumBytes: Int64 = 1 << 20) {
        self.minimumBytes = minimumBytes
    }

    private struct Place {
        let id: String
        let name: String
        let folders: [String]
        let detail: String
        var leaveOut: Set<String> = []
    }

    public func scan(_ context: CleanScanContext) -> [CleanItem] {
        let library = context.homePath + "/Library"
        let places = [
            Place(id: "logs", name: "App logs", folders: [library + "/Logs"],
                  detail: "Records apps write about what they did. Apps start new ones as they run.", leaveOut: ["DiagnosticReports"]),
            Place(id: "crashreports", name: "Crash reports", folders: [library + "/Logs/DiagnosticReports"],
                  detail: "Reports from apps that crashed or hung. Removing them only matters if you meant to send one to a developer."),
            Place(id: "deviceupdates", name: "iPhone and iPad software updates",
                  folders: ["iPhone", "iPad", "iPod"].map { library + "/iTunes/\($0) Software Updates" },
                  detail: "System files Finder downloaded to update or restore a device. Finder downloads them again when needed."),
        ]

        // The folders themselves stay; what is inside them goes.
        let sizer = CleanSizer(context)
        var items: [CleanItem] = []
        for place in places {
            if sizer.cancelled || context.isCancelled() { break }
            let paths = place.folders.flatMap { folder in
                CleanFiles.names(folder).filter { !place.leaveOut.contains($0) && $0 != ".DS_Store" }.map { folder + "/" + $0 }
            }.filter { !context.isBlocked($0) }.sorted()
            guard !paths.isEmpty else { continue }
            let sizes = sizer.sizes(paths)
            var rest = paths
            if place.id == "logs" {
                // One row per app's folder: a log one app holds open then keeps back only that app's.
                for path in paths where CleanFiles.isDirectory(path) {
                    guard let size = sizes[path], size.bytes >= minimumBytes else { continue }
                    rest.removeAll { $0 == path }
                    let folder = (path as NSString).lastPathComponent
                    let app = LibraryArea.isReverseDNS(folder) ? AppNames.name(bundleID: folder) ?? folder : folder
                    items.append(CleanItem(id: "systemjunk:\(path)", tab: .junk, group: Self.group, name: "\(app) logs", detail: place.detail,
                                           paths: [path], bytes: size.bytes, modified: size.modified, safety: .safe).stamped(sizes))
                }
            }
            let size = sizer.total(rest, sizes: sizes)
            guard !rest.isEmpty, size.bytes >= minimumBytes else { continue }
            let name = place.id == "logs" && rest.count < paths.count ? "Other app logs" : place.name
            items.append(CleanItem(id: "systemjunk:\(place.folders[0])", tab: .junk, group: Self.group, name: name, detail: place.detail,
                                   paths: rest, bytes: size.bytes, modified: size.modified, safety: .safe).stamped(sizes))
        }
        if !items.isEmpty { context.found(items) }
        // A process that ends right after its scan, like the CLI, keeps what it measured.
        sizer.cache?.save()
        return items
    }
}
