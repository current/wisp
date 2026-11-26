import AppKit
import WispCore

/// What each version changed, as the What's New window shows it after an update.
/// A release adds one `Notes` at the top of `all`; older ones stay, so someone who
/// skipped a version still sees what it brought.
@MainActor
enum WhatsNew {
    /// One measured improvement, drawn large: how much better, then the old and the new
    /// figure as two bars on one scale.
    struct Headline {
        var symbol: String
        var title: String
        /// Where it was measured, quiet beside the title.
        var detail: String
        /// The loudest text on the card, such as "66× faster".
        var gain: String
        var before: Double
        var after: Double
        var beforeText: String
        var afterText: String
        var tint: NSColor
    }

    struct Entry {
        var symbol: String
        var title: String
        /// The whole change, shown on hover and read by VoiceOver.
        var text: String
        /// The one line the card shows.
        var line: String
        var tint: NSColor
        /// The page the change is on, which a click on the card opens.
        var page: PageID?
    }

    struct Notes {
        var version: String
        /// What the version is about in a few words, under the window's title.
        var summary: String
        var headlines: [Headline] = []
        /// The version the headline figures were measured against.
        var baseline = ""
        /// Where and against what the headline figures were measured, said once.
        var measured: String?
        var entries: [Entry]
    }

    static let all: [Notes] = [
        Notes(version: "0.5.0", summary: "Faster, lighter and redrawn", headlines: [
            Headline(symbol: "arrow.clockwise", title: "Scanning again", detail: "Clean Up, Developer tab", gain: "66× faster",
                     before: 33, after: 0.5, beforeText: "33 s", afterText: "0.5 s", tint: Theme.cyan),
            Headline(symbol: "menubar.rectangle", title: "Menu bar CPU", detail: "Only the menu bar showing", gain: "Half the CPU",
                     before: 0.4, after: 0.2, beforeText: "0.4 %", afterText: "0.2 %", tint: A2.labelTint(.cpu)),
            Headline(symbol: "doc.viewfinder", title: "First result", detail: "Large Files", gain: "30× faster",
                     before: 4.2, after: 0.14, beforeText: "4.2 s", afterText: "0.14 s", tint: Theme.indigo),
            Headline(symbol: "memorychip", title: "Coding Agents page", detail: "At its peak", gain: "7× less memory",
                     before: 889, after: 118, beforeText: "889 MB", afterText: "118 MB", tint: Theme.purple),
        ], baseline: "0.4.0", measured: "Measured on a MacBook Pro M3 Max against Wisp 0.4.0.", entries: [
            Entry(symbol: "gauge.with.needle", title: "AI usage, straight from each agent",
                  text: "Wisp asks Claude Code, Codex and Antigravity for each signed-in account's limits. It works without T3 Code or any setup, uses no tokens and reads no sign-in.",
                  line: "Each account's limits, with no setup and no tokens", tint: Theme.purple, page: .agents),
            Entry(symbol: "sparkles", title: "Every screen redrawn",
                  text: "Pages and dropdowns share one design, from the full dashboard to Settings, Clean Up and Coding Agents, with charts where they help.",
                  line: "Pages and dropdowns share one design", tint: Theme.blue, page: .overview),
            Entry(symbol: "bolt.fill", title: "Faster scans",
                  text: "Clean Up remembers what it measured, so scanning again takes seconds. Storage reads about a third faster, and a folder that has not changed refreshes in a fraction of a second.",
                  line: "An unchanged folder refreshes in 0.02 s, was 60 s", tint: Theme.cyan, page: .disk),
            Entry(symbol: "checkmark.shield.fill", title: "Safer cleaning",
                  text: "Each item is checked again just before it goes, and a clean can be stopped. Mounted disk images, folders git tracks and live package stores stay put.",
                  line: "Each item is checked again just before it goes", tint: Theme.indigo, page: .cleanup),
            Entry(symbol: "scalemass.fill", title: "Storage that adds up",
                  text: "Hard links and clones count once, so the home folder no longer adds up to more than the disk holds.",
                  line: "Hard links and clones count once", tint: Theme.teal, page: .disk),
            Entry(symbol: "accessibility", title: "VoiceOver and keyboard",
                  text: "The new screens read their charts and states aloud, and Wisp's buttons take keyboard focus.",
                  line: "Charts read aloud, and buttons take keyboard focus", tint: Theme.green, page: nil),
        ]),
        Notes(version: "0.4.0", summary: "A dropdown for every menu bar item", entries: [
            Entry(symbol: "rectangle.stack.fill", title: "A dropdown for every item",
                  text: "Each menu bar item opens its own dropdown of compact cards, with the window's charts. Hover a line to see more about it.",
                  line: "Compact cards with the window's charts", tint: Theme.blue, page: nil),
            Entry(symbol: "clock.arrow.circlepath", title: "Limits with their resets",
                  text: "A usage limit says when it resets, with the clock time on hover, and how long it lasts at the current pace.",
                  line: "When each limit resets, and its pace on hover", tint: Theme.purple, page: .agents),
            Entry(symbol: "arrow.triangle.branch", title: "Agent worktrees in Clean Up",
                  text: "The Developer tab lists the git worktrees coding agents made, with their size and when each was last used.",
                  line: "The worktrees coding agents made, with their size", tint: Theme.cyan, page: .cleanup),
        ]),
    ]

    static var versions: [String] { all.map(\.version) }

    static func notes(_ version: String) -> Notes? { all.first { $0.version == version } }

    /// The notes for the version running, or the newest before it when this build has none.
    static var current: Notes? {
        UpdateNotes.between("0", Wisp.version, versions).first.flatMap(notes)
    }

    static func releasePage(_ version: String) -> URL {
        URL(string: "https://github.com/current/wisp/releases/tag/v\(version)")!
    }

    /// Settings or history that an earlier Wisp left behind. Read before this launch
    /// writes any of its own, so a first install does not mistake itself for an update.
    nonisolated static func earlierVersionLeftTraces() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: AppSettings.key) != nil || defaults.object(forKey: "WispUpdateCheckedAt") != nil { return true }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Wisp").path)) ?? []
        return files.contains { !$0.hasPrefix(".") }
    }
}
