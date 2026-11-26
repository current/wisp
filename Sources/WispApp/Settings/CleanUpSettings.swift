import AppKit
import WispCore

/// The Clean Up section of Settings: the schedule, the deleted-app watcher, when a
/// project counts as stale, and what is excluded from scans.
@MainActor
enum CleanUpSettings {
    static let customDays = [3, 7, 10, 14, 21, 30, 45, 60, 90]
    static let staleDays = [14, 30, 60, 90, 180, 365]

    static func groups(_ center: CleanUpCenter, rebuild: @escaping () -> Void, open: @escaping () -> Void) -> [SettingsGroup] {
        let s = center.settings
        let tint = SettingsPage.Section.cleanUp.tint
        let schedules = CleanSchedule.allCases
        var schedule: [SettingsRow] = [
            .control("Scheduled clean", next(s),
                     SettingsControls.popup(schedules.map(\.title), schedules.firstIndex(of: s.schedule) ?? 0) { index in
                         center.change { $0.setSchedule(schedules[index]) }
                         rebuild()
                     }),
        ]
        if s.schedule == .custom {
            schedule.append(.control("Days between cleans", nil,
                                     SettingsControls.popup(customDays.map { "\($0) days" }, customDays.firstIndex(of: s.customDays) ?? 3) { index in
                                         center.change { $0.setSchedule(.custom, customDays: customDays[index]) }
                                         rebuild()
                                     }))
        }
        var excluded: [SettingsRow] = s.exclusions.map { path in
            .item(.image(NSWorkspace.shared.icon(forFile: path)), (path as NSString).lastPathComponent, path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                  SettingsControls.pill("Remove") {
                      center.change { $0.exclusions.removeAll { $0 == path } }
                      rebuild()
                  }, tip: path)
        }
        if excluded.isEmpty {
            excluded = [.empty(.symbol("eye.slash", tint), "Nothing excluded", "Right-click an item on the Clean Up page to keep it out of every scan.", nil)]
        }
        let scheduled = s.schedule != .off
        return [
            SettingsGroup("Schedule", symbol: "calendar", summary: "How often Wisp offers to clean.",
                          trailing: .pill(scheduled ? "On" : "Off", scheduled ? .good : .neutral), schedule,
                          footer: "When a clean is due, Wisp says how much safe junk from Junk and Developer can go. Nothing moves until you review it, and only to the Trash.",
                          action: ("Open Clean Up", open)),
            SettingsGroup("Deleted apps", symbol: "trash", summary: s.watchDeletedApps ? "Watching the Applications folders." : "Off. Leftovers show up only in a scan.", [
                .control("Offer to remove what a deleted app leaves", "Watches the Applications folders. When an app goes, Wisp looks for its files in your Library and tells you if it finds any.",
                         SettingsControls.toggle(s.watchDeletedApps) { on in
                             center.change { $0.watchDeletedApps = on }
                             // After the switch has slid over.
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { rebuild() }
                         }),
            ]),
            SettingsGroup("Developer", symbol: "hammer", summary: "When a project's build folders count as safe to clear.", [
                .control("Projects count as stale after", "Build folders of projects untouched this long show up on the Developer tab.",
                         SettingsControls.popup(staleDays.map { "\($0) days" }, staleDays.firstIndex(of: s.staleProjectDays) ?? 1) { index in
                             center.change { $0.staleProjectDays = staleDays[index] }
                         }),
            ]),
            SettingsGroup("Excluded from scans", symbol: "eye.slash", summary: "Kept out of every scan, on every tab.",
                          trailing: s.exclusions.isEmpty ? nil : .text("\(s.exclusions.count)"), excluded),
        ]
    }

    private static func next(_ settings: CleanSettings) -> String {
        guard settings.schedule != .off, let due = settings.nextDue else { return "Off. Wisp cleans only when you ask." }
        return "Next one \(due.formatted(date: .abbreviated, time: .omitted))."
    }
}
