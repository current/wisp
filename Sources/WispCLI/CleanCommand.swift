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
        // --apply cleans only what is safe, and only Junk and Developer list safe items, so it
        // does not read the rest (Large Files hashes up to 20 GB looking for duplicates).
        var tabs = apply ? CleanRegistry.safeTabs : CleanListing.defaultTabs
        if let index = arguments.firstIndex(of: "--tab") {
            guard index + 1 < arguments.count, let tab = CleanListing.tab(named: arguments[index + 1]) else {
                fail("--tab takes junk, developer, large, leftovers or uninstall")
            }
            tabs = [tab]
            arguments.removeSubrange(index...(index + 1))
        }
        var explain: String?
        if let index = arguments.firstIndex(of: "--explain") {
            guard index + 1 < arguments.count else { fail("--explain takes an item's name, path or id") }
            explain = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        if let extra = arguments.first { fail("unknown option \(extra)") }

        if history { return printHistory(json: json) }
        if let explain {
            let explanations = self.explanations(explain, tabs: tabs, rescan: false)
            if json {
                FileHandle.standardOutput.write(Report.json(explanations))
                print()
            } else {
                printExplanations(explanations, query: explain)
            }
            return
        }
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

    /// The JSON the MCP tool `list_cleanable` returns. An assistant may call it at any time, so
    /// Large Files is listed without the duplicate search, which reads up to 20 GB to hash files.
    /// It answers from the Clean Up page's saved scan when that is recent, so it lists the rows the owner sees.
    static func listingJSON(tab name: String?, rescan: Bool) -> Data {
        let tabs = name.flatMap(CleanListing.tab(named:)).map { [$0] } ?? CleanListing.defaultTabs
        return Report.json(CleanListing.current(tabs, rescan: rescan, scanners: assistantScanners))
    }

    /// The JSON the MCP tool `explain_cleanable` returns.
    static func explainJSON(_ query: String, tab name: String?, rescan: Bool) -> Data {
        let tabs = name.flatMap(CleanListing.tab(named:)).map { [$0] } ?? CleanListing.defaultTabs
        let explanations = explanations(query, tabs: tabs, rescan: rescan)
        guard !explanations.isEmpty else {
            return Report.json(Responder.Failure(error: "No Clean Up row matches \"\(query)\". list_cleanable shows every row with its id."))
        }
        return Report.json(explanations)
    }

    private static var assistantScanners: [any CleanScanner] {
        CleanRegistry.scanners.map { $0 is LargeFilesScanner ? LargeFilesScanner(findDuplicates: false) : $0 }
    }

    private static func explanations(_ query: String, tabs: [CleanTab], rescan: Bool) -> [CleanExplanation] {
        let listing = CleanListing.current(tabs, rescan: rescan, scanners: assistantScanners)
        let selected = listing.selected.map(Set.init)
        let use = ProcessUse.snapshot()
        return CleanExplainer.matches(query, in: listing.tabs.flatMap(\.items)).map { item in
            let fromApp = listing.tabs.first { $0.tab == item.tab }?.scannedAt != nil
            return CleanExplainer.explain(item, selected: fromApp ? selected?.contains(item.id) ?? false : nil, processUse: use)
        }
    }

    private static func printExplanations(_ explanations: [CleanExplanation], query: String) {
        guard !explanations.isEmpty else { fail("nothing in Clean Up matches \"\(query)\"") }
        let home = NSHomeDirectory()
        func short(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        for (index, explanation) in explanations.enumerated() {
            if index > 0 { print() }
            let item = explanation.item
            print("\(item.name)  \(Format.bytes(UInt64(item.bytes)))  \(explanation.safety)")
            var rows: [[String]] = []
            if let maker = item.origin?.madeBy { rows.append(["Made by", maker]) }
            if let git = explanation.git {
                rows.append(["Repository", short(git.repository)])
                if let branch = git.branch ?? item.origin?.branch { rows.append(["Branch", branch]) }
                if let remote = git.remote { rows.append(["Remote", remote]) }
                if let files = git.uncommittedFiles { rows.append(["Uncommitted", files == 1 ? "1 file" : "\(files) files"]) }
                if let commits = git.unpushedCommits { rows.append(["Unpushed", commits == 1 ? "1 commit" : "\(commits) commits"]) }
                if let last = git.lastCommit { rows.append(["Last commit", last]) }
            } else if let project = item.origin?.project {
                rows.append(["Project", short(project)])
            }
            if let from = explanation.downloadedFrom { rows.append(["Downloaded from", from[0]]) }
            if let app = explanation.ownerApp { rows.append(["App", short(app) + (explanation.ownerRunning == true ? " (running)" : "")]) }
            if let user = explanation.inUseBy { rows.append(["In use by", user]) }
            for path in item.paths.prefix(5) { rows.append(["Path", short(path)]) }
            if item.paths.count > 5 { rows.append(["", "and \(item.paths.count - 5) more"]) }
            if !explanation.stillThere { rows.append(["", "Some of it is gone since the scan"]) }
            // Not Table.print: it shortens cells, and the paths and commit are the answer.
            let width = rows.map(\.[0].count).max() ?? 0
            for row in rows { print("  " + row[0].padding(toLength: width, withPad: " ", startingAt: 0) + "  " + row[1]) }
            print("  " + item.detail)
        }
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
        // As with wisp uninstall --apply, a script can tell that something stayed.
        defer { if !report.notRemoved.isEmpty { exit(1) } }
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
