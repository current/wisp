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
            let size = sizer.total(paths, sizes: sizes)
            guard size.bytes >= minimumBytes else { continue }
            items.append(CleanItem(id: "systemjunk:\(place.folders[0])", tab: .junk, group: Self.group, name: place.name, detail: place.detail,
                                   paths: paths, bytes: size.bytes, modified: size.modified, safety: .safe))
        }
        if !items.isEmpty { context.found(items) }
        return items
    }
}
