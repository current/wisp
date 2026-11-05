import Foundation
import WispCore

/// `wisp uninstall`: shows what uninstalling an app removes, and with --apply moves the
/// ticked items to the Trash. Runs here, without the app.
enum UninstallCommand {
    struct Plan: Encodable {
        var app: InstalledApp
        var items: [CleanItem]
        var checkedBytes: Int64
    }

    struct Listed: Encodable {
        var app: InstalledApp
        var checkedBytes: Int64
        var items: Int
    }

    static func run(_ arguments: [String], json: Bool) -> Int32 {
        var arguments = arguments
        let apply = arguments.contains("--apply")
        let list = arguments.contains("--list")
        arguments.removeAll { $0 == "--apply" || $0 == "--list" }
        if list { return listApps(json: json) }
        let query = arguments.joined(separator: " ")
        guard !query.isEmpty else {
            fail("name an app, e.g. wisp uninstall Slack, or list them with wisp uninstall --list")
            return 2
        }
        let running = InstalledApps.runningBundlePaths()
        let apps = InstalledApps.scan(isRunning: { running.contains($1) })
        guard let app = InstalledApps.find(query, in: apps) else {
            fail("no installed app called \(query). Apple's apps and Wisp are not listed")
            return 1
        }
        let items = UninstallPlanner(installed: apps).items(for: app)
        let checked = items.filter(\.checkedByDefault)
        if apply {
            if app.isRunning {
                fail("\(app.name) is running. Quit it, then run this again")
                return 1
            }
            let trashable = checked.filter { $0.removal == .trash && $0.paths.allSatisfy { UninstallPlan.mayRemove($0) } }
            let report = Cleaner(exclusions: CleanSettings.load().exclusions).clean(trashable)
            if !report.results.isEmpty { CleanHistory.append(report.record(trigger: .cli)) }
            if json {
                FileHandle.standardOutput.write(Report.json(report.record(trigger: .cli)))
                print()
            } else {
                for result in report.results {
                    let mark = result.outcome.removed ? "Moved to the Trash" : "Left"
                    print("\(mark)  \(result.item.paths.joined(separator: ", "))" + (result.outcome.removed ? "" : "  \(result.outcome.summary)"))
                }
            }
            return report.notRemoved.isEmpty ? 0 : 1
        }
        let total = checked.reduce(Int64(0)) { $0 + $1.bytes }
        if json {
            FileHandle.standardOutput.write(Report.json(Plan(app: app, items: items, checkedBytes: total)))
            print()
            return 0
        }
        print(app.name + (app.version.map { " \($0)" } ?? "") + "  (\(app.bundleID))")
        print(app.path)
        if let token = app.brewToken {
            print("Installed with Homebrew. brew uninstall --cask \(token) removes the app the same way.")
        } else if let cask = app.cask {
            print("Installed with the Homebrew cask \(cask.token), which also installs \(cask.apps.filter { $0 != (app.path as NSString).lastPathComponent }.joined(separator: ", ")).")
        }
        print()
        let home = NSHomeDirectory()
        // Paths are printed whole, after the table columns, so they can be copied.
        var rows: [[String]] = []
        for item in items {
            for (index, path) in item.paths.enumerated() {
                let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
                rows.append(index == 0 ? [item.checkedByDefault ? "[x]" : "[ ]", item.name, Format.bytes(UInt64(max(0, item.bytes))), shown]
                                       : ["", "", "", shown])
            }
        }
        let nameWidth = min(44, rows.map { $0[1].count }.max() ?? 0)
        let sizeWidth = rows.map { $0[2].count }.max() ?? 0
        for row in rows {
            let name = row[1].count > nameWidth ? String(row[1].prefix(nameWidth - 1)) + "…" : row[1]
            print(row[0].padding(toLength: 3, withPad: " ", startingAt: 0) + "  " + name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + "  " + String(repeating: " ", count: sizeWidth - row[2].count) + row[2] + "  " + row[3])
        }
        print()
        let loose = items.count - checked.count
        print("--apply moves the \(checked.count) ticked \(checked.count == 1 ? "item" : "items"), \(Format.bytes(UInt64(max(0, total)))), to the Trash."
            + (loose == 1 ? " The unticked one is a loose match and stays." : loose > 1 ? " The \(loose) unticked ones are loose matches and stay." : ""))
        if app.isRunning { print("\(app.name) is running; quit it first.") }
        return 0
    }

    /// The plan as JSON, for the read-only MCP tool.
    static func planJSON(_ query: String) -> Data {
        let running = InstalledApps.runningBundlePaths()
        let apps = InstalledApps.scan(isRunning: { running.contains($1) })
        guard let app = InstalledApps.find(query, in: apps) else {
            return Report.json(Responder.Failure(error: "No installed app called \(query)."))
        }
        let items = UninstallPlanner(installed: apps).items(for: app)
        return Report.json(Plan(app: app, items: items, checkedBytes: items.filter(\.checkedByDefault).reduce(0) { $0 + $1.bytes }))
    }

    static func listApps(json: Bool) -> Int32 {
        let running = InstalledApps.runningBundlePaths()
        let apps = InstalledApps.scan(isRunning: { running.contains($1) })
        let planner = UninstallPlanner(installed: apps)
        let listed = apps.map { app -> Listed in
            let items = planner.items(for: app)
            return Listed(app: app, checkedBytes: items.filter(\.checkedByDefault).reduce(0) { $0 + $1.bytes }, items: items.count)
        }.sorted { $0.checkedBytes > $1.checkedBytes }
        if json {
            FileHandle.standardOutput.write(Report.json(listed))
            print()
            return 0
        }
        Table.print(["APP", "FREES", "VERSION", "BUNDLE ID", "HOMEBREW"], listed.map {
            [$0.app.name + ($0.app.isRunning ? " (running)" : ""), Format.bytes(UInt64(max(0, $0.checkedBytes))), $0.app.version ?? "",
             $0.app.bundleID, $0.app.brewToken ?? ""]
        }, right: [1])
        return 0
    }

    /// The one place the CLI removes anything. Moves to the Trash, never deletes, and only
    /// what an uninstall plan may touch. The app's Cleaner can take this over.

    private static func fail(_ message: String) {
        FileHandle.standardError.write("wisp: \(message)\n".data(using: .utf8)!)
    }
}
