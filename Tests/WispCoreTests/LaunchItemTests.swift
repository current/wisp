import Foundation
import Testing
@testable import WispCore

/// A fake Mac: launchd folders and an Applications folder in a temporary directory.
private struct Fixture {
    let root: URL
    var locations: LaunchItemScanner.Locations {
        LaunchItemScanner.Locations(userAgents: root.path + "/home/Library/LaunchAgents", agents: root.path + "/Library/LaunchAgents",
                                    daemons: root.path + "/Library/LaunchDaemons", systemAgents: root.path + "/System/Library/LaunchAgents",
                                    systemDaemons: root.path + "/System/Library/LaunchDaemons", appFolders: [root.path + "/Applications"])
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-launch-\(UUID().uuidString)")
        for folder in ["home/Library/LaunchAgents", "Library/LaunchAgents", "Library/LaunchDaemons", "System/Library/LaunchAgents",
                       "System/Library/LaunchDaemons", "Applications", "bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    func write(_ relative: String, _ plist: [String: Any]) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    func touch(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func app(_ name: String, id: String, executable: String? = nil) throws {
        let base = "Applications/\(name).app/Contents"
        try write(base + "/Info.plist", ["CFBundleIdentifier": id, "CFBundleExecutable": executable ?? name])
        try touch(base + "/MacOS/" + (executable ?? name))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func readsAgentsDaemonsAndLeftovers() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root.path
    try fixture.app("Tool", id: "com.example.tool")
    try fixture.touch("bin/syncer")
    try fixture.write("home/Library/LaunchAgents/com.example.syncer.plist", [
        "Label": "com.example.syncer", "ProgramArguments": [root + "/bin/syncer", "--quiet"], "RunAtLoad": true, "KeepAlive": true,
    ])
    try fixture.write("home/Library/LaunchAgents/com.gone.helper.plist", [
        "Label": "com.gone.helper", "Program": root + "/Applications/Gone.app/Contents/MacOS/helper", "StartInterval": 3600,
    ])
    try fixture.write("Library/LaunchDaemons/com.example.tool.helper.plist", [
        "Label": "com.example.tool.helper", "Program": root + "/bin/syncer", "AssociatedBundleIdentifiers": ["com.example.tool"],
        "MachServices": ["com.example.tool.helper": true],
    ])
    try fixture.write("Library/LaunchAgents/com.removed.updater.plist", [
        "Label": "com.removed.updater", "Program": root + "/bin/syncer", "AssociatedBundleIdentifiers": "com.removed.app",
        "StartCalendarInterval": ["Hour": 10, "Minute": 5],
    ])
    try fixture.write("Library/LaunchAgents/com.apple.something.plist", ["Label": "com.apple.something", "Program": "/usr/bin/true"])
    try fixture.write("System/Library/LaunchDaemons/com.apple.core.plist", ["Label": "com.apple.core", "Program": "/usr/libexec/core"])
    try fixture.touch("Library/LaunchAgents/notes.txt")

    let scanner = LaunchItemScanner(locations: fixture.locations)
    let result = scanner.scan(includeApple: false, state: LaunchdState())
    let items = Dictionary(uniqueKeysWithValues: result.items.map { ($0.label, $0) })
    #expect(Set(items.keys) == ["com.example.syncer", "com.gone.helper", "com.example.tool.helper", "com.removed.updater"])

    let syncer = try #require(items["com.example.syncer"])
    #expect(syncer.kind == .agent && syncer.scope == .user)
    #expect(syncer.programExists && !syncer.isLeftover)
    #expect(syncer.schedule == "At login, kept running")
    #expect(syncer.name == "syncer")

    let gone = try #require(items["com.gone.helper"])
    #expect(gone.isLeftover && gone.appMissing)
    #expect(gone.schedule == "Every hour")
    #expect(gone.appPath == root + "/Applications/Gone.app")

    let helper = try #require(items["com.example.tool.helper"])
    #expect(helper.kind == .daemon && helper.scope == .allUsers)
    #expect(helper.appPath == root + "/Applications/Tool.app")
    #expect(!helper.isLeftover && !helper.canTrash)
    #expect(helper.schedule == "When asked")

    let updater = try #require(items["com.removed.updater"])
    #expect(updater.appMissing && updater.isLeftover)
    #expect(updater.schedule == "Daily at 10:05")

    let everything = scanner.scan(includeApple: true, state: LaunchdState())
    #expect(everything.items.contains { $0.label == "com.apple.core" && $0.scope == .system })
    #expect(everything.items.contains { $0.label == "com.apple.something" })
}

@Test func embeddedHelpersCountOnlyWhenRegistered() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.app("Mover", id: "com.example.mover")
    try fixture.write("Applications/Mover.app/Contents/Library/LoginItems/MoverHelper.app/Contents/Info.plist",
                      ["CFBundleIdentifier": "com.example.mover.helper", "CFBundleExecutable": "MoverHelper"])
    try fixture.touch("Applications/Mover.app/Contents/Library/LoginItems/MoverHelper.app/Contents/MacOS/MoverHelper")
    try fixture.write("Applications/Mover.app/Contents/Library/LaunchAgents/com.example.mover.agent.plist",
                      ["Label": "com.example.mover.agent", "BundleProgram": "Contents/Resources/agent", "RunAtLoad": true])
    try fixture.touch("Applications/Mover.app/Contents/Resources/agent")
    try fixture.write("Applications/Mover.app/Contents/Library/LaunchDaemons/com.example.mover.daemon.plist",
                      ["Label": "com.example.mover.daemon", "BundleProgram": "Contents/Resources/daemon"])

    let scanner = LaunchItemScanner(locations: fixture.locations)
    let none = scanner.scan(includeApple: false, state: LaunchdState())
    #expect(none.items.isEmpty)
    #expect(none.dormant == 3)

    let state = LaunchdState(pids: ["com.example.mover.agent": 812], enabled: ["com.example.mover.helper": false])
    let result = scanner.scan(includeApple: false, state: state)
    let items = Dictionary(uniqueKeysWithValues: result.items.map { ($0.label, $0) })
    #expect(Set(items.keys) == ["com.example.mover.helper", "com.example.mover.agent"])
    #expect(result.dormant == 1)
    let helper = try #require(items["com.example.mover.helper"])
    #expect(helper.kind == .loginItem && helper.name == "MoverHelper" && helper.programExists)
    #expect(helper.appPath == fixture.root.path + "/Applications/Mover.app")
    #expect(state.status(of: helper) == .off)
    let agent = try #require(items["com.example.mover.agent"])
    #expect(agent.program == fixture.root.path + "/Applications/Mover.app/Contents/Resources/agent")
    #expect(agent.programExists)
    #expect(state.status(of: agent) == .running)
}

@Test func onlyUserAgentsWithMissingProgramsCanBeTrashed() {
    let home = NSHomeDirectory()
    let plist: [String: Any] = ["Label": "com.old.thing", "Program": "/Applications/Old.app/Contents/MacOS/old"]
    let user = LaunchItemScanner.item(plist: plist, path: home + "/Library/LaunchAgents/com.old.thing.plist", kind: .agent, scope: .user,
                                      lookup: { _ in nil }, exists: { _ in false })
    #expect(user?.canTrash == true)
    let shared = LaunchItemScanner.item(plist: plist, path: "/Library/LaunchAgents/com.old.thing.plist", kind: .agent, scope: .allUsers,
                                        lookup: { _ in nil }, exists: { _ in false })
    #expect(shared?.canTrash == false)
    let present = LaunchItemScanner.item(plist: plist, path: home + "/Library/LaunchAgents/com.old.thing.plist", kind: .agent, scope: .user,
                                         lookup: { _ in nil }, exists: { _ in true })
    #expect(present?.canTrash == false)
    let relative = LaunchItemScanner.item(plist: ["Label": "x", "ProgramArguments": ["node", "x.js"]],
                                          path: home + "/Library/LaunchAgents/x.plist", kind: .agent, scope: .user,
                                          lookup: { _ in nil }, exists: { _ in false })
    #expect(relative?.isLeftover == false && relative?.canTrash == false)
    #expect(LaunchItemScanner.item(plist: ["Program": "/bin/ls"], path: "/x.plist", kind: .agent, scope: .user, lookup: { _ in nil }) == nil)
}

@Test func schedules() {
    func schedule(_ plist: [String: Any], kind: LaunchItem.Kind = .agent) -> String? {
        var full = plist
        full["Label"] = "l"
        return LaunchItemScanner.item(plist: full, path: "/x.plist", kind: kind, scope: .allUsers, lookup: { _ in nil })?.schedule
    }
    #expect(schedule(["RunAtLoad": true], kind: .daemon) == "At startup")
    #expect(schedule(["KeepAlive": ["NetworkState": true]]) == "Restarted when needed")
    #expect(schedule(["StartInterval": 900]) == "Every 15 min")
    #expect(schedule(["StartInterval": 45]) == "Every 45 s")
    #expect(schedule(["StartCalendarInterval": ["Weekday": 1, "Hour": 3]]) == "Mondays at 3:00")
    #expect(schedule(["StartCalendarInterval": [["Hour": 1], ["Hour": 13]]]) == "On a schedule")
    #expect(schedule(["WatchPaths": ["/Users/a/Library/Preferences/x.plist"]]) == "When x.plist changes")
    #expect(schedule(["KeepAlive": false]) == "When asked")
}

@Test func parsesLaunchctlPrint() {
    let text = """
    gui/501 = {
    \ttype = login
    \tservices = {
    \t\t    1223      - \tapplication.com.caldis.Mos.35498715.35498721
    \t\t   49067   (pe) \tcom.apple.syncdefaultsd
    \t\t       0      0 \tcom.example.idle
    \t}
    \tendpoints = {
    \t\t"com.example.x" = {
    \t\t\tport = 0x1
    \t\t}
    \t}
    \tdisabled services = {
    \t\t"com.bjango.istatmenus.agent" => enabled
    \t\t"com.apple.Siri.agent" => disabled
    \t}
    }
    """
    let state = LaunchdState.parse(text)
    #expect(state.pids["com.apple.syncdefaultsd"] == 49067)
    #expect(state.pids["com.example.idle"] == 0)
    #expect(state.pids.count == 3)
    #expect(state.enabled == ["com.bjango.istatmenus.agent": true, "com.apple.Siri.agent": false])
    #expect(state.knows("com.bjango.istatmenus.agent") && !state.knows("com.nobody"))
}

@Test func joinsCostsByPIDThenPath() {
    let a = LaunchItem(path: "/a.plist", label: "a", kind: .agent, scope: .user, program: "/bin/a", programExists: true)
    let b = LaunchItem(path: "/b.plist", label: "b", kind: .daemon, scope: .allUsers, program: "/bin/b", programExists: true)
    let c = LaunchItem(path: "/c.plist", label: "c", kind: .agent, scope: .user, program: "/bin/c", programExists: true)
    func row(_ pid: Int32, _ path: String, cpu: Double) -> ProcessRow {
        ProcessRow(pid: pid, ppid: 1, uid: 501, name: "", path: path, responsiblePID: pid, groupID: "", readable: true, cpu: cpu,
                   memory: 1000, watts: 0.5, diskReadPerSecond: 0, diskWritePerSecond: 0, networkInPerSecond: 0, networkOutPerSecond: 0,
                   cpuTime: 0, startDate: nil)
    }
    let table = ProcessTable(processes: [row(10, "/bin/a", cpu: 0.2), row(11, "/bin/b", cpu: 0.1), row(12, "/bin/b", cpu: 0.3)])
    let costs = LaunchItemCost.join([a, b, c], state: LaunchdState(pids: ["a": 10, "c": 0]), table: table)
    #expect(costs["/a.plist"]?.pids == [10])
    #expect(costs["/b.plist"]?.pids == [11, 12])
    #expect(abs((costs["/b.plist"]?.cpu ?? 0) - 0.4) < 1e-9)
    #expect(costs["/c.plist"] == nil)
}

@Test func signerNames() {
    #expect(Signer.cleanName("Developer ID Application: Google LLC (EQHXZ8M8AV)") == "Google LLC")
    #expect(Signer.cleanName("Apple Development: Jane Doe (ABC123)") == "Jane Doe")
    #expect(Signer().unknown && Signer().title == "Unknown developer")
    #expect(Signer.read(path: "/bin/ls")?.apple == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_PROBE"] != nil))
func probeLaunchItems() {
    var start = Date()
    let state = LaunchdState.read()
    print("launchctl \(Date().timeIntervalSince(start) * 1000) ms, \(state.pids.count) labels")
    start = Date()
    let result = LaunchItemScanner().scan(includeApple: false, state: state)
    print("scan \(Date().timeIntervalSince(start) * 1000) ms, \(result.items.count) items, \(result.dormant) dormant")
    start = Date()
    for item in result.items {
        let signer = Signer.read(path: item.signedPath ?? item.path)
        print(item.kind.title, item.label, "|", item.name, "|", item.schedule, "|", state.status(of: item).rawValue, "|",
              item.appPath ?? "-", item.isLeftover ? "LEFTOVER" : "", item.canTrash ? "TRASH" : "", "|", signer?.title ?? "?")
    }
    print("signatures \(Date().timeIntervalSince(start) * 1000) ms")
    start = Date()
    let all = LaunchItemScanner().scan(includeApple: true, state: state)
    print("with apple \(Date().timeIntervalSince(start) * 1000) ms, \(all.items.count) items")
}

@Test func scriptsRunByAnInterpreter() {
    let home = NSHomeDirectory()
    let plist: [String: Any] = ["Label": "com.me.watch", "ProgramArguments": ["/bin/bash", "-lc", "/Users/me/bin/watch.sh"]]
    let missing = LaunchItemScanner.item(plist: plist, path: home + "/Library/LaunchAgents/com.me.watch.plist", kind: .agent, scope: .user,
                                         lookup: { _ in nil }, exists: { $0 == "/bin/bash" })
    #expect(missing?.script == "/Users/me/bin/watch.sh")
    #expect(missing?.name == "watch.sh")
    #expect(missing?.isLeftover == true && missing?.canTrash == true)
    #expect(missing?.signedPath == "/Users/me/bin/watch.sh")
    let present = LaunchItemScanner.item(plist: plist, path: home + "/Library/LaunchAgents/com.me.watch.plist", kind: .agent, scope: .user,
                                         lookup: { _ in nil }, exists: { _ in true })
    #expect(present?.isLeftover == false && present?.canTrash == false)
    let inline = LaunchItemScanner.item(plist: ["Label": "x", "ProgramArguments": ["/bin/sh", "-c", "echo hi"]], path: "/x.plist",
                                        kind: .agent, scope: .user, lookup: { _ in nil }, exists: { _ in true })
    #expect(inline?.script == nil && inline?.name == "x")
}

@Test func agentsThatOpenAnApp() {
    let plist: [String: Any] = ["Label": "com.me.status", "ProgramArguments": ["/usr/bin/open", "-g", "/Users/me/Applications/Status.app"],
                                "RunAtLoad": true]
    let item = LaunchItemScanner.item(plist: plist, path: "/x.plist", kind: .agent, scope: .user, lookup: { _ in nil },
                                      exists: { $0 == "/usr/bin/open" })
    #expect(item?.appPath == "/Users/me/Applications/Status.app")
    #expect(item?.name == "Status")
    #expect(item?.appMissing == true && item?.isLeftover == true)
}
