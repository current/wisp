import AppKit
import WispCore

/// The Clean Up section of Settings: the schedule, the deleted-app watcher, when a
/// project counts as stale, and what is excluded from scans.
@MainActor
enum CleanUpSettings {
    static let customDays = [3, 7, 10, 14, 21, 30, 45, 60, 90]
    static let staleDays = [14, 30, 60, 90, 180, 365]

    static func groups(_ center: CleanUpCenter, rebuild: @escaping () -> Void) -> [SettingsGroup] {
        let s = center.settings
        let schedules = CleanSchedule.allCases
        var schedule: [SettingsRow] = [
            .control("Scheduled clean", next(s),
                     popup(schedules.map(\.title), schedules.firstIndex(of: s.schedule) ?? 0) { index in
                         center.change { $0.setSchedule(schedules[index]) }
                         rebuild()
                     }),
        ]
        if s.schedule == .custom {
            schedule.append(.control("Days between cleans", nil,
                                     popup(customDays.map { "\($0) days" }, customDays.firstIndex(of: s.customDays) ?? 3) { index in
                                         center.change { $0.setSchedule(.custom, customDays: customDays[index]) }
                                         rebuild()
                                     }))
        }
        var excluded: [SettingsRow] = s.exclusions.map { path in
            .control((path as NSString).lastPathComponent, path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), pill("Remove") {
                center.change { $0.exclusions.removeAll { $0 == path } }
                rebuild()
            })
        }
        if excluded.isEmpty {
            excluded = [.control("Nothing excluded", "Right-click an item on the Clean Up page to keep it out of every scan.", nil)]
        }
        return [
            SettingsGroup("Schedule", schedule,
                          footer: "When a clean is due, Wisp says how much safe junk from Junk and Developer can go. Nothing moves until you review it, and only to the Trash."),
            SettingsGroup("Deleted apps", [
                .control("Offer to remove what a deleted app leaves", "Watches the Applications folders. When an app goes, Wisp looks for its files in your Library and tells you if it finds any.",
                         ActionSwitch(on: s.watchDeletedApps) { on in center.change { $0.watchDeletedApps = on } }),
            ]),
            SettingsGroup("Developer", [
                .control("Projects count as stale after", "Build folders of projects untouched this long show up on the Developer tab.",
                         popup(staleDays.map { "\($0) days" }, staleDays.firstIndex(of: s.staleProjectDays) ?? 1) { index in
                             center.change { $0.staleProjectDays = staleDays[index] }
                         }),
            ]),
            SettingsGroup("Excluded from scans", excluded),
        ]
    }

    private static func next(_ settings: CleanSettings) -> String {
        guard settings.schedule != .off, let due = settings.nextDue else { return "Off. Wisp cleans only when you ask." }
        return "Next one \(due.formatted(date: .abbreviated, time: .omitted))."
    }

    private static func popup(_ titles: [String], _ selected: Int, _ body: @escaping (Int) -> Void) -> NSView {
        let button = MenuButton()
        button.titles = titles
        button.selected = selected
        button.onPick = body
        let probe = MenuButton()
        probe.titles = [titles.max { $0.count < $1.count } ?? ""]
        button.frame.size = NSSize(width: probe.naturalWidth, height: 26)
        return button
    }

    private static func pill(_ title: String, _ body: @escaping () -> Void) -> NSView {
        let pill = GlassPill(title)
        pill.onPress = body
        pill.frame.size = NSSize(width: ceil((title as NSString).size(withAttributes: [.font: Theme.sans(13, .semibold)]).width) + 32, height: 30)
        return pill
    }
}
