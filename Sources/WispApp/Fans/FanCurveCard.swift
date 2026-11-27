import AppKit
import WispCore

/// The Sensors page's curve editor: pick a curve, follow a sensor, drag its points, and
/// keep the result as one of the owner's curves. The presets are built in, so
/// editing one saves a copy. Edits stay a draft until saved; saving a curve the fans
/// follow sends it to the helper again.
@MainActor
final class FanCurveCard: CardView {
    private struct Entry {
        var curve: FanCurve
        var builtIn: Bool
    }

    private let header = A2Header()
    private let picker = SettingsPopUp()
    private let sensor = Segmented(FanSensor.allCases.map(\.title))
    private let chart = FanCurveChart()
    private let hint = TextLine()
    private var buttons: [A2PillButton] = []
    private var entries: [Entry] = []
    private var saved = Entry(curve: .balanced, builtIn: true)
    private var draft = FanCurve.balanced
    private var loaded = false
    /// The fans follow the saved version of this curve now.
    private var active = false

    static let height: CGFloat = 340
    private static let chartTop: CGFloat = 46
    private static let footer: CGFloat = 26

    private var edited: Bool { draft != saved.curve }

    override init() {
        super.init()
        header.title = "Fan curve"
        picker.setAccessibilityLabel("Curve")
        picker.onPick = { [weak self] index in self?.choose(index) }
        sensor.setAccessibilityLabel("Follows")
        sensor.onChange = { [weak self] index in
            guard let self else { return }
            self.draft.sensor = FanSensor.allCases[index]
            self.show()
        }
        chart.onChange = { [weak self] points in
            guard let self else { return }
            self.draft.setPoints(points)
            self.show()
        }
        let words = "Drag a point to move it. Double-click to add one, or drag it off the chart to remove it."
        hint.variants = [words + " At 0% macOS runs the fans.", words, "Double-click to add a point, drag one off to remove it.",
                         "Double-click to add a point", ""]
            .map { NSAttributedString(string: $0, attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary]) }
        for view in [header, picker, sensor, chart, hint] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ service: FanService) {
        entries = FanCurve.presets.map { Entry(curve: $0, builtIn: true) } + service.curves.map { Entry(curve: $0, builtIn: false) }
        let following = service.status?.mode.kind == .curve ? service.status?.mode.curve : nil
        if !loaded {
            loaded = true
            let first = entries.first { $0.curve.name == following?.name } ?? entries[1]
            saved = first
            draft = first.curve
        } else if let fresh = entries.first(where: { $0.curve.name == saved.curve.name }) {
            // Changed elsewhere (`wisp fans`): take it, unless there are edits to keep.
            if fresh.curve != saved.curve, !edited { draft = fresh.curve }
            saved = fresh
        } else {
            saved = entries[1]
            draft = saved.curve
        }
        active = following?.name == saved.curve.name
        chart.overheated = active && service.status?.overheated == true
        show()
    }

    /// The reading the draft's sensor gives now, from the helper's last report.
    private var celsius: Double? { FanService.shared.status?.temperatures.celsius(for: draft.sensor) }

    private func show() {
        picker.titles = entries.map(\.curve.name)
        picker.selected = entries.firstIndex { $0.curve.name == saved.curve.name } ?? 0
        sensor.select(FanSensor.allCases.firstIndex(of: draft.sensor) ?? 0, animated: false)
        chart.points = draft.points
        chart.celsius = celsius
        header.detail = [saved.builtIn ? "Built in" : nil, active && !edited ? "In use" : nil, edited ? "Not saved" : nil]
            .compactMap { $0 }.joined(separator: " · ")

        var actions: [(String, () -> Void)] = []
        if edited {
            actions = [("Revert", { [weak self] in self?.revert() })]
            actions.append(saved.builtIn ? ("Save as New Curve…", { [weak self] in self?.saveAsNew() }) : ("Save", { [weak self] in self?.save() }))
        } else {
            actions = [("New Curve…", { [weak self] in self?.saveAsNew() })]
            if !saved.builtIn {
                actions.append(("Rename…", { [weak self] in self?.rename() }))
                actions.append(("Delete…", { [weak self] in self?.confirmDelete() }))
            }
            if !active, FanService.shared.availability == .ready { actions.append(("Use This Curve", { [weak self] in self?.use() })) }
        }
        while buttons.count < actions.count {
            let button = A2PillButton()
            addSubview(button)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= actions.count
            guard index < actions.count else { continue }
            button.title = actions[index].0
            button.onPress = actions[index].1
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        let mid = A2.padTop + 8
        let sensorWidth = sensor.naturalWidth
        sensor.frame = NSRect(x: bounds.width - A2.padSide - sensorWidth, y: mid - 13, width: sensorWidth, height: 26)
        let pickerWidth = min(SettingsPopUp.width(for: picker.titles), 200)
        picker.frame = NSRect(x: sensor.frame.minX - 10 - pickerWidth, y: mid - SettingsPopUp.height / 2, width: pickerWidth, height: SettingsPopUp.height)
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: max(0, picker.frame.minX - 12 - A2.padSide), height: 16)
        let footerY = bounds.height - A2.padTop - Self.footer
        // The plot's left labels sit in the chart; its edge lines up with the card's padding on the right.
        chart.frame = NSRect(x: 6, y: Self.chartTop, width: bounds.width - 8, height: max(40, footerY - 10 - Self.chartTop))
        var right = bounds.width - A2.padSide
        for button in buttons.reversed() where !button.isHidden {
            let width = button.naturalWidth
            button.frame = NSRect(x: right - width, y: footerY, width: width, height: Self.footer)
            right -= width + 8
        }
        hint.frame = NSRect(x: A2.padSide, y: footerY + 5, width: max(0, min(inner, right - 4 - A2.padSide)), height: 16)
    }

    // MARK: Actions

    private func choose(_ index: Int) {
        guard entries.indices.contains(index), entries[index].curve.name != saved.curve.name else { return }
        let entry = entries[index]
        discardingEdits { [weak self] go in
            guard let self else { return }
            if go {
                self.saved = entry
                self.draft = entry.curve
            }
            self.show()
        }
    }

    /// Asks before throwing away a draft; `body` learns whether to go ahead.
    private func discardingEdits(_ body: @escaping (Bool) -> Void) {
        guard edited, let window else { return body(true) }
        let alert = NSAlert()
        alert.messageText = "Discard your changes to \(saved.curve.name)?"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { body($0 == .alertFirstButtonReturn) }
    }

    private func revert() {
        draft = saved.curve
        show()
    }

    private func save() {
        let name = saved.curve.name
        saved.curve = draft
        FanService.shared.save(draft, replacing: name)
    }

    /// Keeps the curve on screen, edits and all, under a new name.
    private func saveAsNew() {
        let base = saved.builtIn ? "My \(saved.curve.name.lowercased())" : "\(saved.curve.name) copy"
        CurveNamePrompt.ask(in: window, title: "Name the new curve", initial: unique(base), taken: entries.map(\.curve.name)) { [weak self] name in
            guard let self else { return }
            let curve = FanCurve(name: name, sensor: self.draft.sensor, points: self.draft.points)
            self.saved = Entry(curve: curve, builtIn: false)
            self.draft = curve
            FanService.shared.save(curve)
        }
    }

    private func rename() {
        let old = saved.curve.name
        CurveNamePrompt.ask(in: window, title: "Rename \(old)", initial: old, taken: entries.map(\.curve.name).filter { $0 != old }) { [weak self] name in
            guard let self, name != old else { return }
            var curve = self.saved.curve
            curve.name = name
            self.saved.curve = curve
            self.draft.name = name
            FanService.shared.save(curve, replacing: old)
        }
    }

    private func confirmDelete() {
        guard let window else { return }
        let name = saved.curve.name
        let alert = NSAlert()
        alert.messageText = "Delete \(name)?"
        alert.informativeText = active ? "The fans follow this curve now. They go back to macOS when it is deleted." : ""
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.saved = self.entries[1]
            self.draft = self.saved.curve
            FanService.shared.delete(name)
        }
    }

    private func use() { FanService.shared.set(.curve(saved.curve)) }

    private func unique(_ base: String) -> String {
        let taken = Set(entries.map { $0.curve.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// Asks for a curve's name in a sheet, with Save held back until the name can be used:
/// not empty, not one the owner already has, and not a word `wisp fans` reads as a mode.
@MainActor
private final class CurveNamePrompt: NSObject, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    private let reason = NSTextField(labelWithString: "")
    private let taken: [String]
    private weak var save: NSButton?
    private static var open: CurveNamePrompt?
    private static let reserved: Set<String> = ["auto", "automatic", "system", "max", "full", "quiet", "balanced"]
    private static let limit = 40

    private init(taken: [String]) {
        self.taken = taken
        super.init()
    }

    static func ask(in window: NSWindow?, title: String, initial: String, taken: [String], done: @escaping (String) -> Void) {
        guard let window, open == nil else { return }
        let prompt = CurveNamePrompt(taken: taken)
        open = prompt
        prompt.field.stringValue = initial
        prompt.field.delegate = prompt
        prompt.field.frame = NSRect(x: 0, y: 20, width: 260, height: 22)
        prompt.reason.font = Theme.sans(11)
        prompt.reason.textColor = .secondaryLabelColor
        prompt.reason.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 42))
        accessory.addSubview(prompt.field)
        accessory.addSubview(prompt.reason)
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = accessory
        prompt.save = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        prompt.check()
        alert.window.initialFirstResponder = prompt.field
        alert.beginSheetModal(for: window) { response in
            open = nil
            guard response == .alertFirstButtonReturn, prompt.problem == nil else { return }
            done(prompt.name)
        }
    }

    private var name: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    private var problem: String? {
        if name.isEmpty { return "" }
        if Self.reserved.contains(name.lowercased()) || name.hasSuffix("%") { return "That name is a built-in mode" }
        if taken.contains(where: { $0.lowercased() == name.lowercased() }) { return "You already have a curve with that name" }
        return nil
    }

    private func check() {
        let problem = self.problem
        save?.isEnabled = problem == nil
        reason.stringValue = problem ?? ""
    }

    func controlTextDidChange(_ notification: Notification) {
        if field.stringValue.count > Self.limit { field.stringValue = String(field.stringValue.prefix(Self.limit)) }
        check()
    }
}
