import Foundation

/// What can go, by tab: the answer to `wisp clean --json` and the MCP tool `list_cleanable`.
public struct CleanListing: Codable, Sendable {
    public struct Tab: Codable, Sendable {
        public var tab: CleanTab
        public var title: String
        public var bytes: Int64
        public var items: [CleanItem]
    }

    public var date: Date
    public var tabs: [Tab]
    public var totalBytes: Int64
    /// What Clean Safe Items and `wisp clean --apply` would move to the Trash.
    public var safeTrashBytes: Int64

    public init(items: [CleanItem], tabs: [CleanTab], date: Date = Date()) {
        self.date = date
        self.tabs = tabs.map { tab in
            let found = items.filter { $0.tab == tab }.sorted { $0.bytes > $1.bytes }
            return Tab(tab: tab, title: tab.title, bytes: found.totalBytes, items: found)
        }
        totalBytes = items.totalBytes
        safeTrashBytes = items.filter(\.isSafeTrash).totalBytes
    }

    /// Scans `tabs` now, on the calling thread, with the owner's exclusions.
    public static func scan(_ tabs: [CleanTab], settings: CleanSettings = .load()) -> CleanListing {
        let items = CleanRegistry.scan(tabs, context: CleanScanContext(excluded: settings.exclusions))
        return CleanListing(items: items, tabs: tabs)
    }

    /// "junk", "developer", "large", "leftovers", "uninstall", or the raw tab names.
    public static func tab(named name: String) -> CleanTab? {
        switch name.lowercased() {
        case "large", "large-files", "largefiles": return .largeFiles
        case "history": return nil
        default: return CleanTab(rawValue: name.lowercased())
        }
    }

    /// The tabs `wisp clean` lists when none is named. Uninstall lists every app, so it is asked for by name.
    public static let defaultTabs: [CleanTab] = [.junk, .developer, .largeFiles, .leftovers]
}

extension CleanItem {
    /// "Safe to clean", "Check first" or "Removed for good", as the page and the CLI label it.
    public var safetyLabel: String {
        if removal.isPermanent { return "Removed for good" }
        return safety == .safe ? "Safe to clean" : "Check first"
    }
}
