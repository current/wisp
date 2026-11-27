import AppKit
import WispCore

extension FanMode {
    /// The same entry in a list of modes: the same kind, and the same speed or curve name.
    func matches(_ other: FanMode) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .auto: return true
        case .fixed: return (percent ?? 0).rounded() == (other.percent ?? 0).rounded()
        case .curve: return curve?.name == other.curve?.name
        }
    }
}

extension FanTemperatures {
    /// The reading a curve follows, as the helper picks it: the hottest sensor stands in
    /// for a CPU or GPU the Mac does not report.
    func celsius(for sensor: FanSensor) -> Double? {
        switch sensor {
        case .hottest: return hottest
        case .cpu: return cpu ?? hottest
        case .gpu: return gpu ?? hottest
        }
    }
}

/// The modes the owner can pick, for the Sensors page and the menu bar.
@MainActor
enum FanModeChoices {
    /// Automatic, the presets, Max and the owner's curves, with the mode in force added
    /// at the end when it is none of them (a speed set with `wisp fans`).
    static func list(_ service: FanService) -> (modes: [FanMode], selected: Int) {
        var modes = service.modes
        guard let current = service.status?.mode else { return (modes, 0) }
        if let index = modes.firstIndex(where: { $0.matches(current) }) { return (modes, index) }
        modes.append(current)
        return (modes, modes.count - 1)
    }

    /// One item per mode, ticked on the one in force, with the owner's curves after a
    /// separator; picking one sets it.
    static func menuItems(_ service: FanService) -> [NSMenuItem] {
        let (modes, selected) = list(service)
        var items: [NSMenuItem] = []
        for (index, mode) in modes.enumerated() {
            if index == 4 { items.append(.separator()) }
            let item = ActionItem(mode.title) { FanService.shared.set(mode) }
            item.state = index == selected ? .on : .off
            items.append(item)
        }
        return items
    }

    /// The line under the Fans card's title: what the fans follow and the speed it asks for.
    static func summary(_ status: FanStatus) -> (text: String, warns: Bool) {
        if status.overheated { return ("Full speed until the chip cools", true) }
        switch status.mode.kind {
        case .auto: return ("macOS sets the speed", false)
        case .fixed: return ((status.mode.percent ?? 0) >= 100 ? "Full speed" : "Fixed at \(status.mode.title)", false)
        case .curve:
            guard let curve = status.mode.curve else { return ("", false) }
            let reading = status.temperatures.celsius(for: curve.sensor).map { "\(curve.sensor.title) \(Format.celsius($0))" }
            let speed = status.percent.map { "\(Int($0.rounded()))% speed" } ?? "macOS runs the fans"
            return ([reading, speed].compactMap { $0 }.joined(separator: " · "), false)
        }
    }

    static func rpm(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }
}

/// The Sensors page's Fans card: the mode the fans follow, each fan's speed against the
/// one Wisp asked for, and setting up the helper while it is not there.
@MainActor
final class FanControlCard: CardView {
    private let header = A2Header()
    private let mode = SettingsPopUp()
    private lazy var more = SymbolButton(symbol: "ellipsis.circle", label: "More", target: self, action: #selector(showMore(_:)))
    private let summary = TextLine()
    private let problem = A2Paragraph()
    private let explanation = A2Paragraph()
    private lazy var action = ActionButton(title: "", target: self, action: #selector(install))
    private let empty = TextLine()
    private var rows: [A2Row] = []
    private var modes: [FanMode] = []
    private var fanCount = 0

    private static let rowHeight: CGFloat = 44
    private static let summaryTop: CGFloat = A2.padTop + 16 + 10

    override init() {
        super.init()
        header.title = "Fans"
        mode.onPick = { [weak self] index in
            guard let self, self.modes.indices.contains(index) else { return }
            FanService.shared.set(self.modes[index])
        }
        mode.setAccessibilityLabel("Fan mode")
        problem.color = A2.warn
        empty.alignment = .center
        empty.text = NSAttributedString(string: "This Mac has no fans", attributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
        action.secondary = false
        for view in [header, mode, more, summary, problem, explanation, action, empty] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the service's state, with `readings` (the monitor's) for the fans' speeds
    /// while the helper has nothing to say.
    func update(_ service: FanService, readings: [FanReading]) {
        let status = service.status
        let fans: [(index: Int, rpm: Double?, low: Double?, high: Double?, target: Double?)] =
            status.map { $0.fans.map { ($0.index, $0.rpm, $0.minRPM, $0.maxRPM, $0.targetRPM) } }
            ?? readings.map { ($0.index, $0.rpm, $0.minRPM, $0.maxRPM, nil) }
        fanCount = fans.count
        let ready = service.availability == .ready

        let (modes, selected) = FanModeChoices.list(service)
        self.modes = modes
        mode.titles = modes.map(\.title)
        mode.selected = selected
        mode.isHidden = !ready || fans.isEmpty
        more.isHidden = !(FanHelper.isInstalled && service.checked) || fans.isEmpty

        var line: (text: String, warns: Bool) = ("", false)
        if service.busy {
            line = ("Waiting for the fan helper", false)
        } else if ready, let status {
            line = FanModeChoices.summary(status)
        }
        summary.text = NSAttributedString(string: line.text, attributes: [.font: A2.subFont, .foregroundColor: line.warns ? A2.warn : A2.secondary])
        summary.isHidden = line.text.isEmpty

        switch service.availability {
        case .ready:
            explanation.text = ""
            action.isHidden = true
        case .notInstalled:
            explanation.text = "Changing fan speed needs a small helper that runs as root. macOS asks for your password once."
            action.title = "Set Up Fan Control…"
            action.isHidden = false
        case .needsRepair(let message):
            explanation.text = service.checked ? message : "Checking the fan helper"
            action.title = "Repair…"
            action.isHidden = !service.checked
        }
        if fans.isEmpty {
            explanation.text = ""
            action.isHidden = true
        }
        explanation.isHidden = explanation.text.isEmpty
        action.isEnabled = !service.busy
        action.alphaValue = service.busy ? 0.5 : 1
        problem.text = fans.isEmpty ? "" : service.problem ?? status?.error ?? ""
        problem.isHidden = problem.text.isEmpty

        let spinning = fans.filter { ($0.rpm ?? 0) > 1 }.count
        header.items = fans.isEmpty || ready ? [] : [.init(text: spinning == 0 ? (fans.count == 2 ? "Both off" : "Off") : "\(spinning) spinning")]
        while rows.count < fans.count {
            let row = A2Row()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= fans.count
            guard index < fans.count else { continue }
            let fan = fans[index]
            row.showsRule = index > 0
            row.name = "Fan \(fan.index + 1)"
            if let target = fan.target {
                row.detail = "Target \(FanModeChoices.rpm(target)) rpm"
            } else if let low = fan.low, let high = fan.high {
                row.detail = "\(FanModeChoices.rpm(low)) to \(FanModeChoices.rpm(high)) rpm"
            } else {
                row.detail = ""
            }
            let rpm = fan.rpm ?? 0
            row.cells = [.init(kind: .text(rpm > 1 ? "\(FanModeChoices.rpm(rpm)) rpm" : "Off", A2.primary, A2.valueFont, .right), width: 72)]
        }
        empty.isHidden = !fans.isEmpty
        needsLayout = true
    }

    /// The text block between the title and the rows: the summary, a problem, the
    /// explanation and its button.
    private func blockHeight(_ inner: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if !summary.isHidden { height += 15 + 8 }
        if !problem.isHidden { height += problem.height(for: inner) + 8 }
        if !explanation.isHidden { height += explanation.height(for: inner) + 8 }
        if !action.isHidden { height += action.intrinsicContentSize.height + 12 }
        return height
    }

    /// The height that shows everything at this width.
    func neededHeight(width: CGFloat) -> CGFloat {
        let inner = max(120, width - A2.padSide * 2)
        return Self.summaryTop + blockHeight(inner) + CGFloat(max(1, fanCount)) * Self.rowHeight + A2.padTop - 4
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        var right = bounds.width - A2.padSide
        if !more.isHidden {
            more.frame = NSRect(x: right - 22, y: A2.padTop + 8 - 11, width: 22, height: 22)
            right = more.frame.minX - 6
        }
        if !mode.isHidden {
            let width = min(SettingsPopUp.width(for: mode.titles), inner * 0.6)
            mode.frame = NSRect(x: right - width, y: A2.padTop + 8 - SettingsPopUp.height / 2, width: width, height: SettingsPopUp.height)
            right = mode.frame.minX - 8
        }
        header.frame = NSRect(x: A2.padSide, y: A2.padTop, width: max(0, right - A2.padSide), height: 16)
        var y = Self.summaryTop
        if !summary.isHidden {
            summary.frame = NSRect(x: A2.padSide, y: y, width: inner, height: 15)
            y += 15 + 8
        }
        for paragraph in [problem, explanation] where !paragraph.isHidden {
            let height = paragraph.height(for: inner)
            paragraph.frame = NSRect(x: A2.padSide, y: y, width: inner, height: height)
            y += height + 8
        }
        if !action.isHidden {
            let size = action.intrinsicContentSize
            action.frame = NSRect(x: A2.padSide, y: y + 2, width: size.width, height: size.height)
            y += size.height + 12
        }
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: A2.padSide, y: y + CGFloat(index) * Self.rowHeight, width: inner, height: Self.rowHeight)
        }
        empty.frame = NSRect(x: A2.padSide, y: (bounds.height + y) / 2 - 9, width: inner, height: 18)
    }

    @objc private func install() { FanService.shared.install() }

    @objc private func showMore(_ sender: NSButton) {
        guard let menu = removeMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? { more.isHidden ? nil : removeMenu() }

    private func removeMenu() -> NSMenu? {
        let menu = NSMenu()
        let remove = ActionItem("Remove Fan Helper…") { [weak self] in self?.confirmRemove() }
        remove.isEnabled = !FanService.shared.busy
        menu.addItem(remove)
        return menu
    }

    private func confirmRemove() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the fan helper?"
        alert.informativeText = "The fans go back to macOS. macOS asks for your password to remove it, and you can set it up again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            FanService.shared.uninstall()
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}
