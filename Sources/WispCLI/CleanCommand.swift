import Darwin
import Foundation
import WispCore

/// `wisp clean`: lists what Clean Up would find, without changing anything. `--apply`
/// moves only the items marked safe to the Trash; nothing permanent runs from here.
enum CleanCommand {
    static func run(_ arguments: [String], json: Bool) {
        var arguments = arguments
        let apply = arguments.contains("--apply")
        let history = arguments.contains("--history")
        arguments.removeAll { $0 == "--apply" || $0 == "--history" }
        var tabs = CleanListing.defaultTabs
        if let index = arguments.firstIndex(of: "--tab") {
            guard index + 1 < arguments.count, let tab = CleanListing.tab(named: arguments[index + 1]) else {
                fail("--tab takes junk, developer, large, leftovers or uninstall")
            }
            tabs = [tab]
            arguments.removeSubrange(index...(index + 1))
        }
        if let extra = arguments.first { fail("unknown option \(extra)") }

        if history { return printHistory(json: json) }
        let settings = CleanSettings.load()
        let listing = scan(tabs, settings: settings)
        if apply { return clean(listing, settings: settings, json: json) }
        if json {
            FileHandle.standardOutput.write(Report.json(listing))
            print()
            return
        }
        printListing(listing)
    }

    /// The JSON the MCP tool `list_cleanable` returns.
    static func listingJSON(tab name: String?) -> Data {
        let tabs = name.flatMap(CleanListing.tab(named:)).map { [$0] } ?? CleanListing.defaultTabs
        return Report.json(scan(tabs, settings: .load()))
    }

    private static func scan(_ tabs: [CleanTab], settings: CleanSettings) -> CleanListing {
        let interactive = isatty(STDERR_FILENO) != 0
        if interactive { FileHandle.standardError.write(Data("Looking for what can go…\r".utf8)) }
        let listing = CleanListing.scan(tabs, settings: settings)
        if interactive { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
        return listing
    }

    private static func printListing(_ listing: CleanListing) {
        let home = NSHomeDirectory()
        var first = true
        for tab in listing.tabs {
            if !first { print() }
            first = false
            guard !tab.items.isEmpty else {
                print("\(tab.title): nothing found")
                continue
            }
            print("\(tab.title)  \(Format.bytes(UInt64(tab.bytes)))")
            var rows: [[String]] = []
            for group in groups(tab.items) {
                for item in group.items {
                    rows.append([group.name, item.name, Format.bytes(UInt64(item.bytes)), item.safetyLabel,
                                 item.paths.count == 1 ? item.paths[0].replacingOccurrences(of: home, with: "~") : "\(item.paths.count) places"])
                }
            }
            Table.print(["GROUP", "ITEM", "SIZE", "", "WHERE"], rows, right: [2])
        }
        let count = listing.tabs.reduce(0) { $0 + $1.items.count }
        guard count > 0 else { return }
        print()
        print("\(Format.bytes(UInt64(listing.totalBytes))) in \(count) items. "
            + (listing.safeTrashBytes > 0 ? "wisp clean --apply moves the \(Format.bytes(UInt64(listing.safeTrashBytes))) marked safe to the Trash."
                                          : "Nothing is marked safe to clean, so --apply would move nothing."))
    }

    /// Groups in the order the scanners found them, each sorted by size.
    private static func groups(_ items: [CleanItem]) -> [(name: String, items: [CleanItem])] {
        var order: [String] = []
        var byGroup: [String: [CleanItem]] = [:]
        for item in items {
            if byGroup[item.group] == nil { order.append(item.group) }
            byGroup[item.group, default: []].append(item)
        }
        return order.map { ($0, byGroup[$0]!.sorted { $0.bytes > $1.bytes }) }
    }

    private static func clean(_ listing: CleanListing, settings: CleanSettings, json: Bool) {
        let items = listing.tabs.flatMap(\.items).filter(\.isSafeTrash)
        let report = Cleaner(exclusions: settings.exclusions).clean(items)
        if !report.results.isEmpty { CleanHistory.append(report.record(trigger: .cli)) }
        if json {
            FileHandle.standardOutput.write(Report.json(report.record(trigger: .cli)))
            print()
            return
        }
        guard !items.isEmpty else {
            print("Nothing marked safe to clean was found.")
            return
        }
        Table.print(["", "ITEM", "SIZE", ""], report.results.map {
            [$0.outcome.removed ? "Moved" : "Left", $0.item.name, Format.bytes(UInt64($0.item.bytes)), $0.outcome.removed ? "" : $0.outcome.summary]
        }, right: [2])
        print()
        print("Moved \(Format.bytes(UInt64(report.bytesFreed))) to the Trash" + (report.notRemoved.isEmpty ? "." : "; \(report.notRemoved.count) left in place."))
    }

    private static func printHistory(json: Bool) {
        let records = CleanHistory.load()
        if json {
            FileHandle.standardOutput.write(Report.json(records))
            print()
            return
        }
        guard !records.isEmpty else {
            print("No cleans yet.")
            return
        }
        Table.print(["DATE", "BY", "FREED", "ITEMS"], records.reversed().map {
            [$0.date.formatted(date: .abbreviated, time: .shortened), $0.trigger.title, Format.bytes(UInt64($0.bytesFreed)),
             "\($0.removedCount) of \($0.items.count)"]
        }, right: [2, 3])
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("wisp clean: \(message)\n".utf8))
        exit(2)
    }
}
