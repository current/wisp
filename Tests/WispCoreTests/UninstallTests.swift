import Foundation
import Testing
@testable import WispCore

/// A fake Mac in a temporary folder: a home with a Library, an Applications folder and a Caskroom.
private struct FakeMac {
    let root: String
    var home: String { root + "/home" }
    var library: String { home + "/Library" }
    var applications: String { root + "/Applications" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-uninstall-\(UUID().uuidString)").path
        for folder in ["home/Library", "Applications", "Caskroom"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func app(_ name: String, id: String, in folder: String? = nil, version: String = "1.0", nested: [String: String] = [:]) throws -> String {
        let path = (folder ?? applications) + "/" + name + ".app"
        try plist(path + "/Contents/Info.plist", ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": name])
        try file(path + "/Contents/MacOS/" + name, bytes: 4096)
        for (relative, nestedID) in nested {
            try plist(path + "/Contents/" + relative + "/Contents/Info.plist", ["CFBundleIdentifier": nestedID])
        }
        return path
    }

    func plist(_ path: String, _ value: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    func file(_ path: String, bytes: Int = 100) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    /// A folder in ~/Library with one file inside, e.g. `folder("Caches/com.foo.Bar")`.
    @discardableResult
    func folder(_ relative: String) throws -> String {
        let path = library + "/" + relative
        try file(path + "/data", bytes: 8192)
        return path
    }

    func agent(_ label: String, program: String, associated: [String] = []) throws -> String {
        let path = library + "/LaunchAgents/" + label + ".plist"
        var value: [String: Any] = ["Label": label, "ProgramArguments": [program], "RunAtLoad": true]
        if !associated.isEmpty { value["AssociatedBundleIdentifiers"] = associated }
        try plist(path, value)
        return path
    }

    func touch(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    func installed() -> [InstalledApp] {
        InstalledApps.scan(locations: InstalledApps.Locations(appFolders: [applications], caskrooms: [root + "/Caskroom"]), measure: false)
    }

    func planner(_ installed: [InstalledApp]) -> UninstallPlanner {
        UninstallPlanner(home: home, installed: installed, fullDiskAccess: true)
    }

    /// Everything written counts as a month old unless a test touches it later.
    func leftovers() -> LeftoversScanner {
        let later = Date().addingTimeInterval(30 * 86_400)
        return LeftoversScanner(appFolders: [applications], caskrooms: [], commandFolders: [root + "/bin"], systemLaunchFolders: [],
                                fullDiskAccess: true, appExists: { _ in false }, now: { later })
    }

    var context: CleanScanContext { CleanScanContext(home: URL(fileURLWithPath: home)) }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private extension Array where Element == CleanItem {
    var checkedPaths: Set<String> { Set(filter(\.checkedByDefault).flatMap(\.paths)) }
    var uncheckedPaths: Set<String> { Set(filter { !$0.checkedByDefault }.flatMap(\.paths)) }
    var allPaths: Set<String> { Set(flatMap(\.paths)) }
}

@Suite struct UninstallTests {
    @Test func strictMatchesAreTickedAndLooseOnesAreNot() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let path = try mac.app("Slack", id: "com.tinyspeck.slackmacgap", nested: ["PlugIns/Share.appex": "com.tinyspeck.slackmacgap.share"])
        let support = try mac.folder("Application Support/com.tinyspeck.slackmacgap")
        let byName = try mac.folder("Application Support/Slack")
        let shipIt = try mac.folder("Caches/com.tinyspeck.slackmacgap.ShipIt")
        let container = try mac.folder("Containers/com.tinyspeck.slackmacgap.share")
        let group = try mac.folder("Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap")
        let unrelated = try mac.folder("Application Support/com.other.App")
        // A helper deep inside the bundle that only its container's metadata points to.
        let deep = try mac.folder("Containers/com.tinyspeck.importer")
        try mac.plist(deep + "/.com.apple.containermanagerd.metadata.plist", ["MCMMetadataInfo": ["SandboxProfileDataValidationInfo": [
            "Parameters": ["application_bundle": path + "/Contents/Frameworks/Core.framework/Importer.app"]]]])
        let preferences = mac.library + "/Preferences/com.tinyspeck.slackmacgap.plist"
        let byHost = mac.library + "/Preferences/ByHost/com.tinyspeck.slackmacgap.1826557D-4B0A-561B-A521-89C5C6BC1982.plist"
        let savedState = try mac.folder("Saved Application State/com.tinyspeck.slackmacgap.savedState")
        let cookies = mac.library + "/HTTPStorages/com.tinyspeck.slackmacgap.binarycookies"
        for file in [preferences, byHost, cookies] { try mac.file(file) }

        var slack = try #require(mac.installed().first)
        #expect(slack.nestedBundleIDs == ["com.tinyspeck.slackmacgap.share"])
        slack.appGroups = ["BQR82RBBHL.com.tinyspeck.slackmacgap"]
        let items = mac.planner([slack]).items(for: slack)

        #expect(items.first?.paths == [path])
        #expect(items.first?.removal == .trash)
        #expect(items.allSatisfy { $0.tab == .uninstall && $0.ownerBundleID == "com.tinyspeck.slackmacgap" })
        #expect(items.checkedPaths == [path, support, container, deep, group, preferences, byHost, savedState, cookies])
        #expect(items.uncheckedPaths == [byName, shipIt])
        #expect(!items.allPaths.contains(unrelated))
        #expect(items.first { $0.paths == [support] }?.bytes ?? 0 >= 8192)
        #expect(items.allSatisfy { !$0.detail.isEmpty && !$0.detail.contains("\n") })
    }

    @Test func appsFromOneVendorNeverShareAPlan() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.app("Google Chrome", id: "com.google.Chrome")
        try mac.app("Google Chrome Canary", id: "com.google.Chrome.canary")
        try mac.app("Google Drive", id: "com.google.drivefs")
        let chrome = try mac.folder("Application Support/com.google.Chrome")
        let canary = try mac.folder("Application Support/com.google.Chrome.canary")
        let canaryHelper = try mac.folder("Caches/com.google.Chrome.canary.helper")
        let drive = try mac.folder("Application Support/com.google.drivefs")
        let keystone = try mac.folder("Caches/com.google.Keystone")
        let vendor = try mac.folder("Application Support/Google")
        let vendorChrome = try mac.folder("Application Support/Google/Chrome")
        let forTesting = try mac.folder("Caches/com.google.chrome.for.testing")
        let sharedGroup = try mac.folder("Group Containers/EQHXZ8M8AV.group.com.google")
        let installed = mac.installed().map { app -> InstalledApp in
            var app = app
            app.appGroups = ["EQHXZ8M8AV.group.com.google"]
            return app
        }
        let planner = mac.planner(installed)
        let chromeApp = try #require(installed.first { $0.bundleID == "com.google.Chrome" })
        let driveApp = try #require(installed.first { $0.bundleID == "com.google.drivefs" })

        let drivePlan = planner.items(for: driveApp)
        #expect(drivePlan.allPaths == [driveApp.path, drive])

        let chromePlan = planner.items(for: chromeApp)
        #expect(chromePlan.checkedPaths == [chromeApp.path, chrome])
        #expect(chromePlan.uncheckedPaths == [vendorChrome])
        for path in [canary, canaryHelper, drive, keystone, vendor, forTesting, sharedGroup] {
            #expect(!chromePlan.allPaths.contains(path), "\(path) is not Chrome's")
        }
    }

    @Test func homebrewIsOfferedOnlyForASingleAppCask() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.app("Slack", id: "com.tinyspeck.slackmacgap")
        try mac.app("Karabiner-Elements", id: "org.pqrs.Karabiner-Elements.Settings")
        try mac.app("Karabiner-EventViewer", id: "org.pqrs.Karabiner-EventViewer")
        func receipt(_ token: String, _ artifacts: [[String: Any]]) throws {
            let path = mac.root + "/Caskroom/" + token + "/.metadata/INSTALL_RECEIPT.json"
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["uninstall_artifacts": artifacts]).write(to: URL(fileURLWithPath: path))
        }
        try receipt("slack", [["uninstall": [["quit": "com.tinyspeck.slackmacgap"]]], ["app": ["Slack.app"]], ["zap": [["trash": ["~/Library/Caches/x"]]]]])
        try receipt("karabiner-elements", [["app": ["Karabiner-Elements.app"]], ["app": ["Karabiner-EventViewer.app"]]])

        let installed = mac.installed()
        let slack = try #require(installed.first { $0.name == "Slack" })
        #expect(slack.cask == HomebrewCask(token: "slack", apps: ["Slack.app"]))
        #expect(slack.brewToken == "slack")
        let brewPlan = mac.planner(installed).items(for: slack, appRemoval: .homebrew)
        #expect(brewPlan.first?.removal == .brewCask(token: "slack"))
        #expect(brewPlan.first?.removal.isPermanent == true)

        let karabiner = try #require(installed.first { $0.name == "Karabiner-Elements" })
        #expect(karabiner.cask?.token == "karabiner-elements")
        #expect(karabiner.brewToken == nil)
        #expect(mac.planner(installed).items(for: karabiner, appRemoval: .homebrew).first?.removal == .trash)
    }

    @Test func installedAppsSkipAppleAndNestedBundles() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.app("Safari", id: "com.apple.Safari")
        try mac.app("Wisp", id: Wisp.bundleIdentifier)
        try mac.app("Host", id: "com.vendor.host", nested: ["Applications/Inner.app": "com.vendor.inner"])
        try mac.app("Tool", id: "com.vendor.tool", in: mac.applications + "/Utilities")
        try mac.app("Grapher", id: "com.apple.grapher", in: mac.applications + "/Utilities")
        let apps = mac.installed()
        #expect(apps.map(\.bundleID) == ["com.vendor.host", "com.vendor.tool"])
        #expect(apps.first?.nestedBundleIDs == ["com.vendor.inner"])
        #expect(apps.first?.version == "1.0")
        #expect(InstalledApps.find("host", in: apps)?.bundleID == "com.vendor.host")
        #expect(InstalledApps.find("com.vendor.tool", in: apps)?.name == "Tool")
        #expect(InstalledApps.find("Inner", in: apps) == nil)
    }

    @Test func launchAgentsMatchByLabelProgramAndAssociatedID() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let path = try mac.app("Stats", id: "eu.exelban.Stats")
        try mac.app("Other", id: "com.other.App")
        let byLabel = try mac.agent("eu.exelban.Stats", program: "/usr/bin/true")
        let byProgram = try mac.agent("eu.exelban.helper", program: path + "/Contents/MacOS/Stats")
        let byAssociated = try mac.agent("eu.exelban.updater", program: "/usr/bin/true", associated: ["eu.exelban.Stats"])
        let subLabel = try mac.agent("eu.exelban.Stats.login", program: "/usr/bin/true")
        let vendorOnly = try mac.agent("eu.exelban.something", program: "/usr/bin/true")
        let other = try mac.agent("com.other.App.agent", program: "/usr/bin/true")
        let installed = mac.installed()
        let stats = try #require(installed.first { $0.bundleID == "eu.exelban.Stats" })
        let items = mac.planner(installed).items(for: stats).filter { $0.name.hasPrefix("Launch agent") }
        #expect(items.checkedPaths == [byLabel, byProgram, byAssociated])
        #expect(items.uncheckedPaths == [subLabel])
        #expect(!items.allPaths.contains(vendorOnly))
        #expect(!items.allPaths.contains(other))
    }

    @Test func leftoversOfADeletedAppAreFoundAndInstalledAppsAreNot() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.app("Kept", id: "com.kept.App")
        try mac.folder("Application Support/com.kept.App")
        try mac.file(mac.library + "/Preferences/com.kept.App.plist")
        try mac.folder("Caches/com.kept.App.ShipIt")
        let support = try mac.folder("Application Support/org.gone.Thing")
        let caches = try mac.folder("Caches/org.gone.Thing.ShipIt")
        let preferences = mac.library + "/Preferences/org.gone.Thing.plist"
        try mac.file(preferences)
        let container = try mac.folder("Containers/org.gone.Thing")
        try mac.plist(container + "/.com.apple.containermanagerd.metadata.plist", ["MCMMetadataInfo": ["SandboxProfileDataValidationInfo": [
            "Parameters": ["application_bundle": mac.applications + "/Gone Thing.app"]]]])
        // An app the owner still has, outside the app folders, that LaunchServices knows of.
        try mac.folder("Application Support/net.elsewhere.App")
        // Named like a bundle id but not one: a rotated log.
        try mac.file(mac.library + "/Logs/warp.log.old.1")
        try mac.folder("Caches/com.apple.Safari")
        try mac.folder("Caches/com.google.Keystone")

        var scanner = mac.leftovers()
        scanner.appExists = { $0 == "net.elsewhere.App" }
        let items = scanner.scan(mac.context)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.name == "Gone Thing")
        #expect(item.ownerBundleID == "org.gone.Thing")
        #expect(Set(item.paths) == [support, caches, preferences, container])
        #expect(item.tab == .leftovers && item.safety == .checkFirst && !item.checkedByDefault)
        #expect(item.bytes >= 3 * 8192)
        #expect(scanner.leftovers(forBundleID: "com.kept.App", context: mac.context) == nil)
        #expect(scanner.leftovers(forBundleID: "org.gone.Thing", context: mac.context)?.paths.count == 4)
    }

    @Test func recentLeftoversAndVendorSiblingsWaitForTheWatcher() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.app("Drive", id: "com.vendor.drive")
        let sibling = try mac.folder("Application Support/com.vendor.browser")
        let recent = try mac.folder("Caches/org.recent.App")
        let recentFile = recent + "/data"
        try mac.folder("Caches/org.old.App")
        let scanner = mac.leftovers()
        try mac.touch(recentFile, scanner.now().addingTimeInterval(-86_400))

        let items = scanner.scan(mac.context)
        #expect(items.map(\.ownerBundleID) == ["org.old.App"])
        // Asked about one app right after it went, neither rule applies.
        #expect(scanner.leftovers(forBundleID: "org.recent.App", context: mac.context)?.paths == [recent])
        #expect(scanner.leftovers(forBundleID: "com.vendor.browser", context: mac.context)?.paths == [sibling])
    }

    @Test func leftoverLaunchAgentsNeedTheirProgramGone() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        let gone = try mac.agent("org.gone.Thing.agent", program: mac.applications + "/Gone.app/Contents/MacOS/Gone")
        try mac.agent("com.owner.watchdog", program: "/usr/bin/true")
        let preferences = mac.library + "/Preferences/org.gone.Thing.plist"
        try mac.file(preferences)
        let items = mac.leftovers().scan(mac.context)
        #expect(items.count == 1)
        #expect(Set(items.first?.paths ?? []) == [gone, preferences])
    }

    @Test func commandLineToolsAreNotLeftovers() throws {
        let mac = try FakeMac()
        defer { mac.remove() }
        try mac.file(mac.root + "/bin/codex")
        try mac.folder("Caches/com.openai.codex")
        #expect(mac.leftovers().scan(mac.context).isEmpty)
    }

    @Test func libraryNames() {
        #expect(LibraryArea.bundleKey("com.foo.Bar.plist") == "com.foo.Bar")
        #expect(LibraryArea.bundleKey("com.foo.Bar.savedState") == "com.foo.Bar")
        #expect(LibraryArea.bundleKey("com.foo.Bar.binarycookies") == "com.foo.Bar")
        #expect(LibraryArea.bundleKey("com.foo.Bar.1826557D-4B0A-561B-A521-89C5C6BC1982.plist") == "com.foo.Bar")
        #expect(LibraryArea.groupKey("6N38VWS5BX.ru.keepcoder.Telegram") == "ru.keepcoder.Telegram")
        #expect(LibraryArea.groupKey("group.com.google.gemini") == "com.google.gemini")
        #expect(LibraryArea.groupKey("group.W5364U7YZB.io.tailscale.shared") == "io.tailscale.shared")
        #expect(LibraryArea.isReverseDNS("org.mozilla.firefox"))
        #expect(!LibraryArea.isReverseDNS("warp.log.old.1"))
        #expect(!LibraryArea.isReverseDNS("harp.log.old.0"))
        #expect(!LibraryArea.isReverseDNS("com.foo"))
        #expect(!LibraryArea.isReverseDNS("Google"))
        #expect(!LibraryArea.isReverseDNS("com.foo bar.baz"))
    }

    @Test func plansOnlyRemoveInsideLibraryFoldersAndAppFolders() {
        let home = "/Users/someone"
        #expect(UninstallPlan.mayRemove("/Applications/Slack.app", home: home))
        #expect(UninstallPlan.mayRemove("/Applications/Utilities/Tool.app", home: home))
        #expect(UninstallPlan.mayRemove(home + "/Applications/Slack.app", home: home))
        #expect(UninstallPlan.mayRemove(home + "/Library/Caches/com.foo.Bar", home: home))
        #expect(!UninstallPlan.mayRemove(home + "/Library/Caches", home: home))
        #expect(!UninstallPlan.mayRemove(home + "/Library", home: home))
        #expect(!UninstallPlan.mayRemove(home + "/Documents/thing", home: home))
        #expect(!UninstallPlan.mayRemove("/Applications", home: home))
        #expect(!UninstallPlan.mayRemove("/System/Applications/Notes.app", home: home))
        #expect(!UninstallPlan.mayRemove(home + "/Library/Caches/../Preferences", home: home))
    }
}
