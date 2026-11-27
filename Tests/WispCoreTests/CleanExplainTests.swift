import Foundation
import Testing
@testable import WispCore

@Suite struct CleanExplainTests {
    private func item(_ id: String, name: String, paths: [String], bytes: Int64 = 1, tab: CleanTab = .developer,
                      group: String = "Worktrees") -> CleanItem {
        CleanItem(id: id, tab: tab, group: group, name: name, detail: "", paths: paths, bytes: bytes, safety: .checkFirst)
    }

    @Test func rowsMatchByIdPathOrNameWords() {
        let items = [
            item("worktree:/h/.t3/worktrees/t3code/agent-ae2e", name: "agent-ae2e (t3code)", paths: ["/h/.t3/worktrees/t3code/agent-ae2e"], bytes: 4),
            item("worktree:/h/.t3/worktrees/track/rebuild", name: "rebuild (track)", paths: ["/h/.t3/worktrees/track/rebuild"], bytes: 2),
            item("project-node_modules:/h/src/wisp", name: "node_modules in wisp", paths: ["/h/src/wisp/node_modules"], bytes: 3,
                 group: "Projects"),
        ]
        #expect(CleanExplainer.matches("worktree:/h/.t3/worktrees/track/rebuild", in: items).map(\.name) == ["rebuild (track)"])
        #expect(CleanExplainer.matches("/h/src/wisp/node_modules/left-pad/index.js", in: items).map(\.name) == ["node_modules in wisp"])
        #expect(CleanExplainer.matches("AGENT-ae2e", in: items).map(\.name) == ["agent-ae2e (t3code)"])
        #expect(CleanExplainer.matches("node_modules wisp", in: items).map(\.name) == ["node_modules in wisp"])
        // Largest first, as the page lists them.
        #expect(CleanExplainer.matches("worktrees", in: items).map(\.name) == ["agent-ae2e (t3code)", "rebuild (track)"])
        #expect(CleanExplainer.matches("  ", in: items).isEmpty)
        #expect(CleanExplainer.matches("photos", in: items).isEmpty)
    }

    @Test func savedScansAreUsedOnlyWhileRecentAndWithoutRowsThatWent() {
        let home = FakeHome()
        home.file("kept/file", bytes: 10)
        let now = Date()
        let snapshot = CleanSnapshot(tabs: [
            "developer": .init(scannedAt: now.addingTimeInterval(-600), items: [
                item("a", name: "kept", paths: [home.path + "/kept"]),
                item("b", name: "gone", paths: [home.path + "/gone"]),
                item("c", name: "a simulator runtime", paths: []),
            ]),
            "junk": .init(scannedAt: now.addingTimeInterval(-2 * 86_400), items: [item("d", name: "old", paths: [home.path + "/kept"], tab: .junk)]),
        ], selected: ["a"])
        #expect(snapshot.recent(.developer, now: now)?.items.map(\.id) == ["a", "c"])
        #expect(snapshot.recent(.junk, now: now) == nil)
        #expect(snapshot.recent(.leftovers, now: now) == nil)
    }

    @Test func listingsCarryWhenTheirTabWasScannedAndWhatWasTicked() {
        let listing = CleanListing(tabs: [(.developer, [item("a", name: "a", paths: [], bytes: 5)], Date(timeIntervalSince1970: 0))],
                                   selected: ["a"])
        #expect(listing.tabs[0].scannedAt == Date(timeIntervalSince1970: 0))
        #expect(listing.selected == ["a"])
        #expect(listing.totalBytes == 5)
    }

    @Test func downloadsSayWhereTheyCameFrom() throws {
        let home = FakeHome()
        home.file("Downloads/Tool.dmg", bytes: 10)
        let path = home.path + "/Downloads/Tool.dmg"
        #expect(CleanOrigin.downloadedFrom(path) == nil)
        let addresses = ["https://example.com/Tool.dmg", "https://example.com/download"]
        let data = try PropertyListSerialization.data(fromPropertyList: addresses, format: .binary, options: 0)
        let set = data.withUnsafeBytes { setxattr(path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0) }
        #expect(set == 0)
        #expect(CleanOrigin.downloadedFrom(path) == addresses)
    }

    @Test func worktreesExplainTheirGitState() throws {
        let git = try #require(CleanTools.git)
        let home = FakeHome()
        let repo = home.path + "/src/repo", tree = home.path + "/.t3/worktrees/repo/feature"
        func run(_ arguments: [String], in folder: String) -> Int32 {
            CleanTools.run(git, ["-C", folder, "-c", "user.name=T", "-c", "user.email=t@example.com"] + arguments, timeout: 30).status
        }
        home.file("src/repo/README.md", text: "hello")
        #expect(run(["init", "-q", "-b", "main"], in: repo) == 0)
        #expect(run(["add", "."], in: repo) == 0)
        #expect(run(["commit", "-q", "-m", "First"], in: repo) == 0)
        #expect(run(["worktree", "add", "-q", tree, "-b", "feature"], in: repo) == 0)
        home.file(".t3/worktrees/repo/feature/notes.txt", text: "draft")

        let scanned = WorktreeScanner(roots: [home.path + "/src"], workingFolders: { [] }, readsGuardedFolders: { true }).scan(home.context())
        let worktree = try #require(scanned.first)
        #expect(worktree.origin?.madeBy == "T3 Code")
        let explanation = CleanExplainer.explain(worktree, selected: true)
        let facts = try #require(explanation.git)
        // The repository may sit behind a symlinked temporary folder; git reports what it was given.
        #expect(facts.repository.hasSuffix("/src/repo"))
        #expect(facts.branch == "feature")
        #expect(facts.uncommittedFiles == 1)
        #expect(facts.remote == nil && facts.unpushedCommits == nil)
        #expect(facts.lastCommit?.hasSuffix(" First") == true)
        #expect(explanation.stillThere && explanation.selected == true)
    }
}
