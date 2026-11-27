import Foundation
import Testing
@testable import WispCore

@Suite struct DeveloperScannerTests {
    static let mb = 1 << 20

    private func projects(_ home: FakeHome, busy: [String] = [], excluded: [String] = [], staleDays: Double = 30) -> [CleanItem] {
        let scanner = ProjectArtifactScanner(staleAfter: staleDays * 86_400, roots: [home.path + "/src"],
                                             workingFolders: { busy.map { home.path + "/" + $0 } }, readsGuardedFolders: { true })
        return scanner.scan(home.context(excluded: excluded))
    }

    /// A git project with a package.json, its node_modules and its history, all `days` old.
    private func nodeProject(_ home: FakeHome, _ name: String, days: Double) {
        home.file("src/\(name)/package.json", text: "{}")
        home.file("src/\(name)/index.js", text: "export {}")
        home.file("src/\(name)/.git/HEAD", text: "ref: refs/heads/main")
        home.file("src/\(name)/node_modules/left-pad/index.js", bytes: 2 * Self.mb)
        home.age("src/\(name)", days: days)
    }

    @Test func staleProjectsListTheirArtifacts() throws {
        let home = FakeHome()
        nodeProject(home, "old", days: 60)
        nodeProject(home, "fresh", days: 2)
        let items = projects(home)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.name == "node_modules in old")
        #expect(item.paths == [home.path + "/src/old/node_modules"])
        #expect(item.safety == .safe && item.checkedByDefault)
        #expect(item.bytes >= Int64(2 * Self.mb))
        #expect(item.group == "Projects" && item.tab == .developer)
        // The threshold is a parameter.
        #expect(projects(home, staleDays: 1).count == 2)
    }

    @Test func recentGitActivityKeepsAProjectFresh() {
        let home = FakeHome()
        nodeProject(home, "old", days: 60)
        home.file("src/old/.git/index", bytes: 100)
        #expect(projects(home).isEmpty)
    }

    @Test func newArtifactsDoNotMakeAProjectFresh() {
        let home = FakeHome()
        nodeProject(home, "old", days: 60)
        home.file("src/old/node_modules/new-package/index.js", bytes: Self.mb)
        home.file("src/old/.next/cache/page.bin", bytes: 2 * Self.mb)
        let items = projects(home)
        #expect(Set(items.map(\.name)) == ["node_modules in old", ".next in old"])
    }

    @Test func artifactsNeedTheirMarker() {
        let home = FakeHome()
        home.file("src/loose/node_modules/x/index.js", bytes: 2 * Self.mb)
        home.file("src/loose/target/debug/app", bytes: 2 * Self.mb)
        home.file("src/loose/venv/lib/site.py", bytes: 2 * Self.mb)
        home.file("src/loose/notes.txt", text: "no markers here")
        home.age("src/loose", days: 90)
        #expect(projects(home).isEmpty)
    }

    @Test func eachKindOfArtifactIsFoundWithItsSafety() throws {
        let home = FakeHome()
        home.file("src/rusty/Cargo.toml", text: "[package]")
        home.file("src/rusty/target/debug/app", bytes: 2 * Self.mb)
        home.file("src/py/pyproject.toml", text: "")
        home.file("src/py/.venv/pyvenv.cfg", text: "home = /usr")
        home.file("src/py/.venv/lib/big.so", bytes: 2 * Self.mb)
        home.file("src/swifty/Package.swift", text: "// swift-tools-version: 6.0")
        home.file("src/swifty/.build/debug/app", bytes: 2 * Self.mb)
        home.file("src/ios/App.xcodeproj/project.pbxproj", text: "")
        home.file("src/ios/Podfile", text: "")
        home.file("src/ios/Pods/Lib/lib.a", bytes: 2 * Self.mb)
        home.file("src/ios/DerivedData/Build/app", bytes: 2 * Self.mb)
        home.file("src/droid/build.gradle", text: "")
        home.file("src/droid/.gradle/8.0/cache.bin", bytes: 2 * Self.mb)
        home.file("src/droid/build/outputs/app.apk", bytes: 2 * Self.mb)
        home.age("src", days: 90)

        let items = projects(home)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["target in rusty", ".venv in py", ".build in swifty", "Pods in ios", "DerivedData in ios",
                                     ".gradle in droid", "build in droid"])
        #expect(byName["target in rusty"]?.safety == .safe)
        #expect(byName[".build in swifty"]?.safety == .safe)
        #expect(byName["DerivedData in ios"]?.safety == .safe)
        let venv = try #require(byName[".venv in py"])
        #expect(venv.safety == .checkFirst && !venv.checkedByDefault)
        #expect(byName["build in droid"]?.safety == .checkFirst)
    }

    @Test func monorepoArtifactsGroupUnderTheRepository() throws {
        let home = FakeHome()
        home.file("src/mono/.git/HEAD", text: "ref: refs/heads/main")
        home.file("src/mono/package.json", text: "{}")
        home.file("src/mono/node_modules/a/index.js", bytes: 2 * Self.mb)
        home.file("src/mono/packages/web/package.json", text: "{}")
        home.file("src/mono/packages/web/node_modules/b/index.js", bytes: 2 * Self.mb)
        home.age("src/mono", days: 60)
        let item = try #require(projects(home).first)
        #expect(item.name == "node_modules in mono")
        #expect(item.paths == [home.path + "/src/mono/node_modules", home.path + "/src/mono/packages/web/node_modules"])

        // A file changed deep inside makes the whole repository fresh.
        home.file("src/mono/packages/web/src/app.ts", text: "export {}")
        #expect(projects(home).isEmpty)
    }

    @Test func busyAndExcludedProjectsAreLeftAlone() {
        let home = FakeHome()
        nodeProject(home, "busy", days: 60)
        nodeProject(home, "kept", days: 60)
        nodeProject(home, "other", days: 60)
        let items = projects(home, busy: ["src/busy/lib"], excluded: ["src/kept"])
        #expect(items.map(\.name) == ["node_modules in other"])
        #expect(projects(home, excluded: ["src/other/node_modules/left-pad"]).map(\.name).sorted() == ["node_modules in busy", "node_modules in kept"])
    }

    // MARK: Worktrees

    private func worktree(_ home: FakeHome, _ relative: String, gitdir: String) {
        home.file(relative + "/.git", text: "gitdir: \(gitdir)\n")
        home.file(relative + "/README.md", bytes: 10_000)
    }

    @Test func onlyTrackedWorktreesAreOffered() throws {
        let home = FakeHome()
        home.file("src/repo/.git/HEAD", text: "ref: refs/heads/main")
        home.folder("src/repo/.git/worktrees/live")
        worktree(home, ".t3/worktrees/repo/live", gitdir: home.path + "/src/repo/.git/worktrees/live")
        worktree(home, ".t3/worktrees/repo/gone", gitdir: home.path + "/src/repo/.git/worktrees/gone")
        worktree(home, ".claude/worktrees/deleted-repo", gitdir: home.path + "/src/deleted/.git/worktrees/deleted-repo")
        worktree(home, "src/repo-worktrees/beside", gitdir: home.path + "/src/repo/.git/worktrees/beside")
        worktree(home, "src/repo/.claude/worktrees/inner", gitdir: "../../../.git/worktrees/inner")
        worktree(home, "src/repo-worktrees/busy", gitdir: home.path + "/src/repo/.git/worktrees/busy")
        worktree(home, ".codex/worktrees/abc/offline", gitdir: "/Volumes/NotMounted-\(UUID().uuidString)/repo/.git/worktrees/offline")
        // A submodule's .git file is not a worktree.
        home.file(".cursor/worktrees/sub/.git", text: "gitdir: ../.git/modules/sub")

        let scanner = WorktreeScanner(roots: [home.path + "/src"], workingFolders: { [home.path + "/src/repo-worktrees/busy"] },
                                      readsGuardedFolders: { true })
        let items = scanner.scan(home.context())
        // "live" is still tracked, and listed because it is in an agent's folder. The ones their
        // repository forgot are left: git cannot say what in them was never committed.
        #expect(Set(items.map(\.name)) == ["live (repo)"])
        #expect(items.allSatisfy { $0.safety == .checkFirst && $0.group == "Worktrees" && !$0.checkedByDefault })
        let live = try #require(items.first)
        #expect(live.paths == [home.path + "/.t3/worktrees/repo/live"])
    }

    @Test func agentWorktreesAllListButHandMadeOnesOnlyWhenStale() throws {
        let home = FakeHome()
        home.file("src/repo/.git/HEAD", text: "ref: refs/heads/main")
        for name in ["old", "fresh", "pinned", "busy"] {
            home.file("src/repo/.git/worktrees/\(name)/HEAD", text: "ref: refs/heads/\(name)")
            worktree(home, ".t3/worktrees/repo/\(name)", gitdir: home.path + "/src/repo/.git/worktrees/\(name)")
        }
        for name in ["mine-old", "mine-fresh"] {
            home.file("src/repo/.git/worktrees/\(name)/HEAD", text: "ref: refs/heads/\(name)")
            worktree(home, "src/repo-worktrees/\(name)", gitdir: home.path + "/src/repo/.git/worktrees/\(name)")
        }
        home.file("src/repo/.git/worktrees/pinned/locked", text: "")
        for name in ["old", "pinned", "busy"] {
            home.age(".t3/worktrees/repo/\(name)", days: 40)
            home.age("src/repo/.git/worktrees/\(name)", days: 40)
        }
        home.age("src/repo-worktrees/mine-old", days: 40)
        home.age("src/repo/.git/worktrees/mine-old", days: 40)
        // An agent ran git in this one yesterday, though its files are old.
        home.age(".t3/worktrees/repo/fresh", days: 40)
        home.age("src/repo/.git/worktrees/fresh", days: 1)

        let scanner = WorktreeScanner(roots: [home.path + "/src"], workingFolders: { [home.path + "/.t3/worktrees/repo/busy"] },
                                      readsGuardedFolders: { true })
        let items = scanner.scan(home.context())
        #expect(Set(items.map(\.name)) == ["old (repo)", "fresh (repo)", "mine-old (repo)"])
        #expect(items.allSatisfy { $0.safety == .checkFirst && !$0.checkedByDefault })
        let fresh = try #require(items.first { $0.name == "fresh (repo)" })
        #expect(fresh.detail.hasPrefix("A git worktree T3 Code made, last used yesterday."))
        #expect(fresh.origin == CleanOrigin(madeBy: "T3 Code", project: home.path + "/src/repo", branch: "fresh"))
        let old = try #require(items.first { $0.name == "old (repo)" })
        #expect(old.detail.hasPrefix("A git worktree T3 Code made, last used 40 days ago."))
        let mine = try #require(items.first { $0.name == "mine-old (repo)" })
        #expect(mine.detail.hasPrefix("A git worktree, last used 40 days ago."))
        #expect(mine.origin == CleanOrigin(project: home.path + "/src/repo", branch: "mine-old"))
    }

    @Test func worktreesNameTheToolWhoseFolderHoldsThem() {
        let home = "/Users/me"
        #expect(WorktreeScanner.maker(of: home + "/.t3/worktrees/track/mac-live", home: home) == "T3 Code")
        #expect(WorktreeScanner.maker(of: home + "/.codex/worktrees/1a2b/repo", home: home) == "Codex")
        #expect(WorktreeScanner.maker(of: home + "/conductor/workspaces/repo/denver", home: home) == "Conductor")
        #expect(WorktreeScanner.maker(of: home + "/src/t3code/.claude/worktrees/agent-ae2e", home: home) == "Claude Code")
        #expect(WorktreeScanner.maker(of: home + "/src/repo-worktrees/mine", home: home) == nil)
    }

    // MARK: Tool caches

    @Test func toolCachesListOnlyWhatExists() throws {
        let home = FakeHome()
        home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/app", bytes: 2 * Self.mb)
        home.file(".npm/_cacache/content/blob", bytes: 2 * Self.mb)
        home.file(".npm/_logs/debug.log", bytes: 2 * Self.mb)
        home.file("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 2 * Self.mb)
        home.file(".m2/repository/org/lib.jar", bytes: 2 * Self.mb)
        home.file("go/pkg/mod/example.com/mod.go", bytes: 2 * Self.mb)
        home.file(".gradle/gradle.properties", text: "secret=1")
        home.file(".cargo/registry/cache/crate.crate", bytes: 100_000)

        let scanner = DeveloperCacheScanner(goModuleCache: { $0 + "/go/pkg/mod" })
        let items = scanner.scan(home.context(excluded: ["Library/Caches/Homebrew"]))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Xcode DerivedData", "npm cache", "Maven repository", "Go modules"])
        #expect(byName["npm cache"]?.paths == [home.path + "/.npm/_cacache"])
        #expect(byName["Xcode DerivedData"]?.safety == .safe)
        #expect(byName["Xcode DerivedData"]?.group == "Xcode")
        #expect(byName["Maven repository"]?.safety == .checkFirst)
        #expect(byName["Go modules"]?.safety == .checkFirst)
    }

    // MARK: Simulators

    @Test func simulatorsAndUnusedRuntimes() throws {
        let devices = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": "A", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true, "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/A/data", "dataPathSize": 4000},
            {"udid": "B", "name": "iPhone 18", "state": "Booted", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
            {"udid": "C", "name": "iPhone 15", "state": "Shutdown", "isAvailable": false, "dataPathSize": 9000}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": []
        }}
        """
        let runtimes = """
        {"R1": {"identifier": "R1", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "sizeBytes": 8000, "deletable": true, "build": "24A434"},
         "R2": {"identifier": "R2", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.xrOS-3-0", "sizeBytes": 7000, "deletable": true, "build": "23N1"}}
        """
        let scanner = SimulatorScanner(simctl: { $0.first == "runtime" ? runtimes : devices })
        let items = scanner.scan(CleanScanContext(home: URL(fileURLWithPath: "/Users/x")))
        #expect(items.map(\.name) == ["iPhone 15, iOS 17.2", "visionOS 3.0 runtime (23N1)", "iPhone 18 Pro, iOS 27.0"])
        #expect(items.map(\.removal) == [.simulator(udid: "C"), .simulatorRuntime(identifier: "R2"), .simulator(udid: "A")])
        #expect(items.allSatisfy { $0.removal.isPermanent && $0.safety == .checkFirst })
        #expect(items[0].checkedByDefault && !items[2].checkedByDefault)
        #expect(items[2].paths == ["/Users/x/Library/Developer/CoreSimulator/Devices/A"])

        #expect(SimulatorScanner(simctl: { _ in nil }).scan(CleanScanContext()).isEmpty)
    }
}
