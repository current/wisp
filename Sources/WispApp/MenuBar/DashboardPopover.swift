import AppKit
import WispCore

/// The popover behind every status item. Built once; while closed it receives no updates.
@MainActor
final class DashboardPopover: NSObject, NSPopoverDelegate {
    private unowned let delegate: AppDelegate
    private let popover = NSPopover()
    private var content: DashboardView?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        // WISP_PIN keeps the popover open for screenshots and UI tests.
        popover.behavior = ProcessInfo.processInfo.environment["WISP_PIN"] == nil ? .transient : .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.appearance = NSAppearance(named: .aqua)
        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.popover.isShown else { return }
            self.content?.update(snapshot, history: delegate.monitor.history)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.popover.isShown else { return }
            self.content?.update(table)
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let view = content ?? DashboardView(delegate: delegate)
        content = view
        if popover.contentViewController == nil {
            let controller = NSViewController()
            controller.view = view
            popover.contentViewController = controller
        }
        view.update(delegate.system, history: delegate.monitor.history)
        view.update(delegate.table)
        popover.contentSize = view.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        delegate.dashboardOpen = true
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        delegate.dashboardOpen = false
        content?.hideTooltip()
    }
}

/// The dashboard: the CPU with its recent line and six meters, a map of every
/// core (or memory by kind), and the busiest apps. Laid out by hand.
@MainActor
final class DashboardView: DrawnView {
    private unowned let delegate: AppDelegate
    static let width: CGFloat = 384
    private let outer: CGFloat = 10
    private let inner: CGFloat = 16

    // Header
    private let title = TextLine(NSAttributedString(string: "Wisp", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink]))
    private let chip = MachineChip()
    private lazy var settingsButton = SymbolButton(symbol: "slider.horizontal.3", label: "Settings", target: self, action: #selector(openSettings))
    private lazy var closeButton = SymbolButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeDashboard))

    // CPU card
    private let cpuCard = CardView()
    private let cpuCaption = TextLine(Theme.caption("CPU"))
    private let cpuState = Pill()
    private let cpuFigure = BigNumber()
    private let cpuMeta = TextLine()
    private let cpuLine = LiveLine()
    private let cpuSpan = TextLine()
    private let cpuRule = DashedRule()
    private let meters = (0..<6).map { _ in Meter() }

    // Cores and memory card
    private let mapCard = CardView()
    private let mapTitle = TextLine()
    private let mapMeta = TextLine()
    private let mapTabs = Segmented(["Cores", "Memory"])
    private let heatmap = Heatmap()
    private let heatHint = TextLine(Theme.caption("Hover a core", size: 9.5))
    private let heatKey = HeatKey()
    private let waffle = Waffle()
    private let legend = LegendStrip()
    private let pressure = Meter()
    private let swap = Meter()

    // Apps card
    private let appsCard = CardView()
    private let appsTitle = TextLine(NSAttributedString(string: "Apps", attributes: [.font: Theme.sans(14), .foregroundColor: Theme.ink]))
    private let appsMeta = TextLine()
    private let appsTabs = Segmented(["CPU", "Memory", "Power", "Net"])
    private let appRows = (0..<5).map { _ in ListRow() }

    // Footer
    private lazy var moreButton = SymbolButton(symbol: "ellipsis", label: "More", target: self, action: #selector(showMore(_:)))
    private let footerRule = CardView()
    private let status = TextLine()
    private lazy var openButton = ActionButton(title: "Open Wisp", target: self, action: #selector(openWindow))

    private let tooltip = Tooltip()
    private var lastSystem: SystemSnapshot?
    private var lastTable: ProcessTable?
    private var coreHistory: [[Float]] = []

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 780))
        wantsLayer = true

        for view in [title, chip, settingsButton, closeButton, cpuCard, mapCard, appsCard, moreButton, footerRule, status, openButton] as [NSView] {
            addSubview(view)
        }
        for view in [cpuCaption, cpuState, cpuFigure, cpuMeta, cpuLine, cpuSpan, cpuRule] as [NSView] { cpuCard.addSubview(view) }
        meters.forEach(cpuCard.addSubview)
        for view in [mapTitle, mapMeta, mapTabs, heatmap, heatHint, heatKey, waffle, legend, pressure, swap] as [NSView] { mapCard.addSubview(view) }
        for view in [appsTitle, appsMeta, appsTabs] as [NSView] { appsCard.addSubview(view) }
        appRows.forEach(appsCard.addSubview)
        tooltip.isHidden = true
        addSubview(tooltip)

        footerRule.fill = Theme.cardBorder
        footerRule.stroke = .clear
        footerRule.radius = 0
        cpuFigure.format = { (String(format: "%.0f", $0 * 100), "%") }
        cpuLine.ceiling = 1
        cpuLine.capacity = HistoryStore.recentSamples
        cpuState.dot = false
        for (index, caption) in ["Memory", "GPU", "Power", "Network", "Disk", "Battery"].enumerated() { meters[index].caption = caption }
        pressure.caption = "Pressure"
        swap.caption = "Swap"
        appRows.last?.showsRule = false
        heatmap.rowPitch = 11
        heatmap.labelWidth = 30
        heatmap.valueWidth = 34
        heatmap.columns = HistoryStore.recentCoreSamples

        mapTabs.onChange = { [weak self] _ in self?.showMapTab(animated: true) }
        appsTabs.onChange = { [weak self] _ in
            guard let self, let table = self.lastTable else { return }
            self.update(table)
        }
        heatmap.onHover = { [weak self] hover in self?.hoverCore(hover) }
        waffle.onHover = { [weak self] hover in
            self?.legend.highlighted = hover?.0
            self?.hoverMemory(hover)
        }
        legend.onHover = { [weak self] index in
            self?.waffle.highlighted = index
            self?.hideTooltip()
        }
        // WISP_TABS=1,2 opens on the given map and apps tabs, for screenshots.
        if let tabs = ProcessInfo.processInfo.environment["WISP_TABS"]?.split(separator: ",").compactMap({ Int($0) }), tabs.count == 2 {
            mapTabs.select(tabs[0], animated: false)
            appsTabs.select(tabs[1], animated: false)
        }
        showMapTab(animated: false)
        layoutAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.panel.cgColor }

    // MARK: Layout

    private func layoutAll() {
        let width = Self.width
        let cardWidth = width - outer * 2
        let content = cardWidth - inner * 2

        title.frame = NSRect(x: 18, y: 16, width: 60, height: 20)
        closeButton.frame = NSRect(x: width - 14 - 26, y: 13, width: 26, height: 26)
        settingsButton.frame = NSRect(x: closeButton.frame.minX - 30, y: 13, width: 26, height: 26)
        let chipWidth = chip.naturalWidth
        chip.frame = NSRect(x: settingsButton.frame.minX - 8 - chipWidth, y: 12, width: chipWidth, height: 28)

        // CPU card
        var y: CGFloat = 52
        cpuCaption.frame = NSRect(x: inner, y: 16, width: 28, height: 16)
        cpuState.frame = NSRect(x: inner + 34, y: 15, width: cpuState.naturalWidth, height: 18)
        cpuFigure.frame = NSRect(x: inner, y: 38, width: 160, height: 40)
        cpuMeta.frame = NSRect(x: inner, y: 82, width: content - 96, height: 14)
        cpuLine.frame = NSRect(x: inner + content - 158, y: 14, width: 158, height: 64)
        cpuSpan.frame = NSRect(x: inner + content - 90, y: 82, width: 90, height: 14)
        cpuRule.frame = NSRect(x: inner, y: 108, width: content, height: 1)
        let column = (content - 32) / 3
        for (index, meter) in meters.enumerated() {
            meter.frame = NSRect(x: inner + CGFloat(index % 3) * (column + 16), y: 122 + CGFloat(index / 3) * 56, width: column, height: 44)
        }
        cpuCard.frame = NSRect(x: outer, y: y, width: cardWidth, height: 122 + 56 + 44 + 16)
        y = cpuCard.frame.maxY + 8

        // Map card
        mapTitle.frame = NSRect(x: inner, y: 14, width: 180, height: 20)
        mapMeta.frame = NSRect(x: inner, y: 42, width: content, height: 14)
        let tabsWidth = mapTabs.naturalWidth
        mapTabs.frame = NSRect(x: inner + content - tabsWidth, y: 14, width: tabsWidth, height: 26)
        let bodyTop: CGFloat = 68
        let rows = max(lastSystem?.cpu?.cores.count ?? 14, 1)
        let mapHeight = CGFloat(rows) * heatmap.rowPitch - heatmap.cellGap
        heatmap.frame = NSRect(x: inner, y: bodyTop, width: content, height: mapHeight)
        heatHint.frame = NSRect(x: inner, y: bodyTop + mapHeight + 12, width: 120, height: 14)
        heatKey.frame = NSRect(x: inner + content - 150, y: bodyTop + mapHeight + 12, width: 150, height: 14)
        let bodyHeight = mapHeight + 26
        waffle.frame = NSRect(x: inner, y: bodyTop, width: content, height: 7 * 9.5 - 2.5)
        legend.frame = NSRect(x: inner, y: waffle.frame.maxY + 14, width: content, height: 34)
        let half = (content - 16) / 2
        pressure.frame = NSRect(x: inner, y: legend.frame.maxY + 14, width: half, height: 44)
        swap.frame = NSRect(x: inner + half + 16, y: legend.frame.maxY + 14, width: half, height: 44)
        let memoryHeight = pressure.frame.maxY - bodyTop
        mapCard.frame = NSRect(x: outer, y: y, width: cardWidth, height: bodyTop + max(bodyHeight, memoryHeight) + 14)
        y = mapCard.frame.maxY + 8

        // Apps card
        appsTitle.frame = NSRect(x: inner, y: 14, width: 120, height: 20)
        appsMeta.frame = NSRect(x: inner, y: 42, width: content, height: 14)
        let appsTabsWidth = appsTabs.naturalWidth
        appsTabs.frame = NSRect(x: inner + content - appsTabsWidth, y: 14, width: appsTabsWidth, height: 26)
        for (index, row) in appRows.enumerated() {
            row.frame = NSRect(x: inner, y: 64 + CGFloat(index) * 30, width: content, height: 30)
        }
        appsCard.frame = NSRect(x: outer, y: y, width: cardWidth, height: 64 + 30 * CGFloat(appRows.count) + 8)
        y = appsCard.frame.maxY

        // Footer
        moreButton.frame = NSRect(x: 12, y: y + 14, width: 26, height: 26)
        footerRule.frame = NSRect(x: 44, y: y + 18, width: 1, height: 18)
        let openSize = openButton.intrinsicContentSize
        openButton.frame = NSRect(x: width - outer - 4 - openSize.width, y: y + 12, width: openSize.width, height: openSize.height)
        status.frame = NSRect(x: 56, y: y + 20, width: openButton.frame.minX - 64, height: 14)

        let height = y + 54
        if frame.height != height { setFrameSize(NSSize(width: width, height: height)) }
    }

    private func showMapTab(animated: Bool) {
        let cores = mapTabs.selected == 0
        let showing: [NSView] = cores ? [heatmap, heatHint, heatKey] : [waffle, legend, pressure, swap]
        let hiding: [NSView] = cores ? [waffle, legend, pressure, swap] : [heatmap, heatHint, heatKey]
        hiding.forEach { $0.isHidden = true }
        showing.forEach { $0.isHidden = false }
        if animated, !Theme.reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            mapCard.layer?.add(fade, forKey: "tab")
        }
        hideTooltip()
        if let system = lastSystem { updateMapHeader(system) }
    }

    // MARK: Updates

    func update(_ s: SystemSnapshot, history: HistoryStore) {
        let coreCountChanged = (lastSystem?.cpu?.cores.count ?? 0) != (s.cpu?.cores.count ?? 0)
        lastSystem = s
        chip.set(s)
        if chip.frame.width != chip.naturalWidth {
            chip.frame = NSRect(x: settingsButton.frame.minX - 8 - chip.naturalWidth, y: 12, width: chip.naturalWidth, height: 28)
        }
        if let c = s.cpu {
            cpuFigure.set(c.total)
            cpuState.text = c.total >= 0.85 ? "Strained" : (c.total >= 0.6 ? "Busy" : "Normal")
            cpuState.tone = c.total >= 0.85 ? .bad : (c.total >= 0.6 ? .warn : .good)
            cpuState.frame.size.width = cpuState.naturalWidth
            var meta = "User \(Format.percent(c.user)) · System \(Format.percent(c.system))"
            if let load = c.loadAverage.first { meta += String(format: " · Load %.1f", load) }
            cpuMeta.text = Theme.caption(meta)
        }
        cpuLine.values = history.recent(.cpu)
        let seconds = Double(HistoryStore.recentSamples) * max(delegate.settings.interval, 1)
        let span = NSMutableAttributedString(string: "● ", attributes: [.font: Theme.mono(9), .foregroundColor: Theme.good])
        span.append(Theme.caption("Last \(Int((seconds / 60).rounded())) min"))
        cpuSpan.text = span
        cpuSpan.alignment = .right

        if let m = s.memory {
            meters[0].set(value: Format.memory(m.used).split(separator: " ").first.map(String.init) ?? "",
                          unit: "/ " + Format.memory(m.total), fraction: m.usedFraction,
                          color: Strain.memory(m) ? Theme.bad : Theme.accent)
        }
        if let g = s.gpu?.utilization {
            meters[1].set(value: String(format: "%.0f", g * 100), unit: "%", fraction: g, color: Theme.accent)
        } else {
            meters[1].set(value: "–", unit: "", fraction: 0, color: Theme.accent)
        }
        if let p = s.power, let cpuWatts = p.cpu {
            let total = cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0)
            let peak = Double(history.recent(.power).filter { !$0.isNaN }.max() ?? 0)
            meters[2].set(value: String(format: total >= 10 ? "%.0f" : "%.1f", total), unit: "W",
                          fraction: total / max(peak * 1.2, 20), color: Theme.accent)
        } else {
            meters[2].set(value: "–", unit: "", fraction: 0, color: Theme.accent)
        }
        if let n = s.network {
            let rate = n.receivedBytesPerSecond + n.sentBytesPerSecond
            let peak = Double(zip(history.recent(.networkIn), history.recent(.networkOut)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            let (value, unit) = Self.split(Format.rate(rate))
            meters[3].set(value: value, unit: unit, fraction: rate / max(peak, 1), color: Theme.accent)
        }
        if let d = s.disk {
            let rate = d.readBytesPerSecond + d.writeBytesPerSecond
            let peak = Double(zip(history.recent(.diskRead), history.recent(.diskWrite)).map { $0 + $1 }.filter { !$0.isNaN }.max() ?? 0)
            let (value, unit) = Self.split(Format.rate(rate))
            meters[4].caption = Strain.disk(d) ? "Disk · low space" : "Disk"
            meters[4].set(value: value, unit: unit, fraction: rate / max(peak, 1), color: Strain.disk(d) ? Theme.bad : Theme.accent)
        }
        if let b = s.battery {
            meters[5].caption = b.isCharging ? "Charging" : (b.isPluggedIn ? "Battery" : "On battery")
            meters[5].set(value: String(format: "%.0f", b.percent), unit: "%", fraction: b.percent / 100,
                          color: Strain.battery(b) ? Theme.bad : Theme.good)
        } else if let t = s.thermal?.cpuCelsius {
            meters[5].caption = "Temperature"
            meters[5].set(value: String(format: "%.0f", t), unit: "°C", fraction: t / 110,
                          color: Strain.temperature(s.thermal) ? Theme.bad : Theme.accent)
        }

        coreHistory = history.cores()
        updateCores(s)
        updateMemory(s)
        updateMapHeader(s)
        if coreCountChanged { layoutAll() }

        let interval = delegate.settings.interval
        let live = NSMutableAttributedString(string: "● ", attributes: [.font: Theme.mono(9), .foregroundColor: Theme.good])
        live.append(Theme.caption("Live · every \(interval.formatted()) s"))
        status.text = live
    }

    private func updateCores(_ s: SystemSnapshot) {
        guard let c = s.cpu, !coreHistory.isEmpty else { return }
        // The kernel lists efficiency cores first; show performance cores on top.
        let efficiency = min(c.efficiencyCores, coreHistory.count)
        var rows: [Heatmap.Row] = []
        for (number, index) in (efficiency..<coreHistory.count).enumerated() {
            rows.append(Heatmap.Row(label: "P\(number + 1)", tag: "", values: coreHistory[index]))
        }
        for index in 0..<efficiency {
            rows.append(Heatmap.Row(label: "E\(index + 1)", tag: "", values: coreHistory[index]))
        }
        heatmap.rows = rows
    }

    private func updateMemory(_ s: SystemSnapshot) {
        guard let m = s.memory else { return }
        let parts: [(String, UInt64, NSColor)] = [
            ("App", m.app, Theme.series[0]), ("Wired", m.wired, Theme.series[1]), ("Compressed", m.compressed, Theme.series[2]),
            ("Cached", m.cached, Theme.series[3]), ("Free", m.free, Theme.track),
        ]
        waffle.parts = parts.map { Waffle.Part(name: $0.0, value: Double($0.1), color: $0.2) }
        let total = Double(max(m.total, 1))
        legend.items = parts.map {
            LegendStrip.Item(name: ["Compressed": "Comp.", "Cached": "Cache"][$0.0] ?? $0.0, value: Format.memory($0.1),
                             share: String(format: "%.0f%%", Double($0.1) / total * 100), color: $0.2)
        }
        let level = m.pressure == .normal ? "Normal" : (m.pressure == .warning ? "Warning" : "Critical")
        pressure.set(value: level, unit: "", fraction: m.pressure == .normal ? 0.33 : (m.pressure == .warning ? 0.66 : 1),
                     color: m.pressure == .normal ? Theme.good : (m.pressure == .warning ? Theme.warn : Theme.bad))
        let (swapValue, swapUnit) = Self.split(Format.memory(m.swapUsed))
        swap.set(value: swapValue, unit: swapUnit, fraction: m.swapTotal > 0 ? Double(m.swapUsed) / Double(m.swapTotal) : 0,
                 color: Theme.accent)
    }

    private func updateMapHeader(_ s: SystemSnapshot) {
        if mapTabs.selected == 0, let c = s.cpu {
            mapTitle.text = Self.titleText("Cores", "\(c.cores.count)")
            let busy = c.cores.filter { $0 >= 0.8 }.count
            mapMeta.text = Theme.caption("\(c.performanceCores) performance · \(c.efficiencyCores) efficiency · \(busy) busy")
        } else if let m = s.memory {
            mapTitle.text = Self.titleText("Memory", Format.memory(m.total))
            mapMeta.text = Theme.caption("\(Format.memory(m.used)) in use · \(Format.percent(m.usedFraction)) of total")
        }
    }

    func update(_ table: ProcessTable) {
        lastTable = table
        let tab = appsTabs.selected
        let key: (AppGroup) -> Double = {
            switch tab {
            case 1: return Double($0.memory)
            case 2: return $0.watts
            case 3: return $0.networkPerSecond
            default: return $0.cpu
            }
        }
        let top = table.apps.sorted { key($0) > key($1) }.prefix(appRows.count)
        let peak = max(top.first.map(key) ?? 0, 0.000_001)
        let settings = delegate.settings
        for (index, row) in appRows.enumerated() {
            guard index < top.count else {
                row.isHidden = true
                continue
            }
            let app = top[top.startIndex + index]
            row.isHidden = false
            row.icon = Icons.icon(for: app)
            row.name = app.name
            row.note = app.processCount > 1 ? "\(app.processCount) procs" : ""
            row.fraction = key(app) / peak
            switch tab {
            case 1: row.value = Format.memory(app.memory)
            case 2: row.value = app.watts > 0.005 ? Format.watts(app.watts) : "–"
            case 3: row.value = table.networkMeasured ? (app.networkPerSecond > 0 ? Format.rate(app.networkPerSecond) : "–") : "Off"
            default: row.value = Style.appCPU(app.cpu, machine: settings.cpuOfMachine, coreCount: table.coreCount)
            }
            let id = app.id
            row.onClick = { [weak self] in self?.delegate.showWindow(selecting: id) }
        }
        appsMeta.text = Theme.caption("\(table.apps.count) apps · \(table.processes.count) processes")
    }

    // MARK: Hover

    private func hoverCore(_ hover: (Int, Int, NSRect)?) {
        guard let (row, column, rect) = hover, heatmap.rows.indices.contains(row) else { return hideTooltip() }
        let values = heatmap.rows[row].values
        let index = values.count - 1 - column
        guard index >= 0 else { return hideTooltip() }
        let seconds = Double(column) * max(delegate.settings.interval, 1)
        tooltip.title = "Core \(heatmap.rows[row].label)"
        tooltip.detail = column == 0 ? "Now" : Format.duration(seconds) + " ago"
        tooltip.lines = [Tooltip.Line(color: Theme.heat(values[index], appearance: effectiveAppearance),
                                      name: "Busy", value: String(format: "%.0f%%", values[index] * 100))]
        tooltip.show(in: self, above: convert(rect, from: heatmap))
    }

    private func hoverMemory(_ hover: (Int, NSRect)?) {
        guard let (index, rect) = hover, waffle.parts.indices.contains(index), let m = lastSystem?.memory else { return hideTooltip() }
        let part = waffle.parts[index]
        tooltip.title = part.name
        tooltip.detail = String(format: "%.0f%%", part.value / Double(max(m.total, 1)) * 100)
        tooltip.lines = [Tooltip.Line(color: part.color, name: "Size", value: Format.memory(part.value))]
        tooltip.show(in: self, above: convert(rect, from: waffle))
    }

    func hideTooltip() { tooltip.hide() }

    // MARK: Actions

    @objc private func openWindow() { delegate.showWindow() }
    @objc private func openSettings() { delegate.showSettings() }
    @objc private func closeDashboard() { delegate.closeDashboard() }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: Helpers

    static func split(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (text, "")
    }

    static func titleText(_ name: String, _ count: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: Theme.sans(14), .foregroundColor: Theme.ink])
        text.append(NSAttributedString(string: " · " + count, attributes: [.font: Theme.sans(14), .foregroundColor: Theme.inkTertiary]))
        return text
    }
}

/// Caption, figure with unit, and a tick meter, stacked.
final class Meter: DrawnView {
    var caption = "" { didSet { if caption != oldValue { needsDisplay = true } } }
    private var value = ""
    private var unit = ""
    private let ticks = TickMeter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(ticks)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(value newValue: String, unit newUnit: String, fraction: Double, color: NSColor) {
        if newValue != value || newUnit != unit {
            value = newValue
            unit = newUnit
            needsDisplay = true
        }
        ticks.fraction = fraction.isFinite ? fraction : 0
        if ticks.color != color { ticks.color = color }
    }

    override func layout() {
        super.layout()
        ticks.frame = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.caption(caption, size: 9.5).draw(at: .zero)
        let text = NSMutableAttributedString(string: value, attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink])
        if !unit.isEmpty {
            text.append(NSAttributedString(string: " " + unit, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkTertiary]))
        }
        text.draw(at: NSPoint(x: 0, y: 13))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { caption }
    override func accessibilityValue() -> Any? { value + " " + unit }
}

/// The chip in the header naming this Mac's chip and memory.
final class MachineChip: DrawnView {
    private(set) var chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer)
        return name.isEmpty ? "This Mac" : name
    }()
    private var memory = ""

    private var text: String {
        let short = chipName.replacingOccurrences(of: "Apple ", with: "")
        return memory.isEmpty ? short : "\(short) · \(memory)"
    }

    var naturalWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Theme.sans(12)]).width) + 40
    }

    func set(_ s: SystemSnapshot) {
        let value = s.memory.map { Format.memory($0.total) } ?? ""
        if value != memory {
            memory = value
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.card.setFill()
        shape.fill()
        Theme.cardBorder.setStroke()
        shape.stroke()
        if let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                Theme.inkSecondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 10, y: (bounds.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (text as NSString).draw(at: NSPoint(x: 28, y: (bounds.height - 15) / 2),
                                withAttributes: [.font: Theme.sans(12), .foregroundColor: Theme.ink])
    }
}
