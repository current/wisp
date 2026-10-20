import AppKit
import WispCore

/// The popover behind every status item: the machine at a glance and the apps
/// using the most right now. Built once; while closed it receives no updates.
@MainActor
final class DashboardPopover: NSObject, NSPopoverDelegate {
    private unowned let delegate: AppDelegate
    private let popover = NSPopover()
    private var content: DashboardView?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.popover.isShown else { return }
            self.content?.update(snapshot, history: delegate.monitor.history)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.popover.isShown else { return }
            self.content?.update(table, settings: delegate.settings)
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
        view.update(delegate.table, settings: delegate.settings)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        delegate.dashboardOpen = true
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        delegate.dashboardOpen = false
    }
}

@MainActor
final class DashboardView: NSView {
    private unowned let delegate: AppDelegate
    private let cpu = MetricRow(title: "CPU")
    private let memory = MetricRow(title: "Memory")
    private let network = MetricRow(title: "Network")
    private let disk = MetricRow(title: "Disk")
    private let gpu = MetricRow(title: "GPU")
    private let thermal = MetricRow(title: "Temperature")
    private let battery = MetricRow(title: "Battery")
    private let power = MetricRow(title: "Power")
    private var appRows: [AppLine] = []
    private let appsHeader = Style.secondary("Most CPU right now")

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: 100))

        let metrics = NSGridView(views: [[cpu, memory], [network, disk], [gpu, thermal], [power, battery]])
        metrics.translatesAutoresizingMaskIntoConstraints = false
        metrics.columnSpacing = Style.section
        metrics.rowSpacing = Style.pad + Style.unit
        metrics.column(at: 0).width = 158
        metrics.column(at: 1).width = 158
        metrics.xPlacement = .fill

        appRows = (0..<5).map { _ in AppLine() }
        let apps = Style.stack([appsHeader] + appRows, axis: .vertical, spacing: Style.unit, alignment: .leading)
        for row in appRows { row.widthAnchor.constraint(equalTo: apps.widthAnchor).isActive = true }

        let open = NSButton(title: "Open Wisp", target: self, action: #selector(openWindow))
        open.bezelStyle = .push
        open.keyEquivalent = "\r"
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                                target: self, action: #selector(openSettings))
        settings.bezelStyle = .texturedRounded
        settings.isBordered = false
        let quit = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Wisp")!,
                            target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = Style.stack([settings, quit, spacer, open], axis: .horizontal, spacing: Style.gap)

        let root = Style.stack([metrics, Style.separator(), apps, Style.separator(), footer],
                               axis: .vertical, spacing: Style.pad, alignment: .leading)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.pad + Style.unit),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Style.pad + Style.unit)),
            root.topAnchor.constraint(equalTo: topAnchor, constant: Style.pad + Style.unit),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Style.pad),
            widthAnchor.constraint(equalToConstant: 364),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openWindow() { delegate.showWindow() }
    @objc private func openSettings() { delegate.showSettings() }

    func update(_ s: SystemSnapshot, history: HistoryStore) {
        if let c = s.cpu {
            cpu.set(value: Format.percent(c.total),
                    detail: "User \(Format.percent(c.user)), system \(Format.percent(c.system))",
                    strained: Strain.cpu(c))
        }
        cpu.chart.ceiling = 1
        cpu.chart.values = history.recent(.cpu)

        if let m = s.memory {
            memory.set(value: Format.memory(m.used),
                       detail: "of \(Format.memory(m.total))" + (m.swapUsed > 0 ? ", \(Format.memory(m.swapUsed)) swap" : ""),
                       strained: Strain.memory(m))
            memory.chart.ceiling = Float(m.total)
        }
        memory.chart.values = history.recent(.memory)

        if let n = s.network {
            network.set(value: Format.rate(n.receivedBytesPerSecond),
                        detail: Format.rate(n.sentBytesPerSecond) + " up", strained: false)
        }
        network.chart.values = history.recent(.networkIn)
        network.chart.secondary = history.recent(.networkOut)

        if let d = s.disk {
            disk.set(value: Format.rate(d.readBytesPerSecond + d.writeBytesPerSecond),
                     detail: "\(Format.bytes(d.volumeFree)) free", strained: false, detailStrained: Strain.disk(d))
        }
        disk.chart.values = history.recent(.diskRead)
        disk.chart.secondary = history.recent(.diskWrite)

        gpu.isHidden = s.gpu?.utilization == nil
        if let g = s.gpu, let u = g.utilization {
            gpu.set(value: Format.percent(u), detail: g.name, strained: Strain.gpu(g))
            gpu.chart.ceiling = 1
            gpu.chart.values = history.recent(.gpu)
        }

        thermal.isHidden = s.thermal?.cpuCelsius == nil
        if let t = s.thermal, let celsius = t.cpuCelsius {
            let fans = t.fans.isEmpty ? "No fans" : t.fans.map { "\(Int($0.rpm)) rpm" }.joined(separator: ", ")
            thermal.set(value: Format.celsius(celsius), detail: fans, strained: Strain.temperature(t))
            thermal.chart.ceiling = 110
            thermal.chart.values = history.recent(.cpuTemperature)
        }

        power.isHidden = s.power?.cpu == nil
        if let p = s.power, let cpuWatts = p.cpu {
            let total = cpuWatts + (p.gpu ?? 0) + (p.ane ?? 0)
            power.set(value: Format.watts(total), detail: "CPU \(Format.watts(cpuWatts)), GPU \(Format.watts(p.gpu ?? 0))", strained: false)
            power.chart.ceiling = nil
            power.chart.values = history.recent(.power)
        }

        battery.isHidden = s.battery == nil
        if let b = s.battery {
            var detail = b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "On battery")
            if let minutes = b.minutesRemaining, minutes > 0 { detail += ", " + Format.duration(Double(minutes) * 60) + " left" }
            battery.set(value: Format.percent(b.percent / 100), detail: detail, strained: Strain.battery(b))
            battery.chart.ceiling = 100
            battery.chart.values = history.recent(.battery)
        }
    }

    func update(_ table: ProcessTable, settings: AppSettings) {
        let top = table.apps.prefix(appRows.count)
        for (index, row) in appRows.enumerated() {
            guard index < top.count else {
                row.isHidden = true
                continue
            }
            let app = top[top.startIndex + index]
            row.isHidden = false
            row.set(icon: Icons.icon(for: app), name: app.name,
                    value: Style.appCPU(app.cpu, machine: settings.cpuOfMachine, coreCount: table.coreCount),
                    detail: Format.memory(app.memory))
        }
    }
}

/// Title and figure on one line, a detail line under them and a sparkline below.
final class MetricRow: NSView {
    let chart = SparklineView()
    private let value = Style.label("–", font: Style.figure)
    private let detail = Style.secondary()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = Style.label(title, font: Style.title)
        value.alignment = .right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = Style.stack([name, spacer, value], axis: .horizontal, spacing: Style.gap)
        chart.translatesAutoresizingMaskIntoConstraints = false
        let stack = Style.stack([top, detail, chart], axis: .vertical, spacing: 2, alignment: .leading)
        stack.setCustomSpacing(Style.unit + 2, after: detail)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            chart.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(value text: String, detail detailText: String, strained: Bool, detailStrained: Bool = false) {
        if value.stringValue != text { value.stringValue = text }
        if detail.stringValue != detailText { detail.stringValue = detailText }
        value.textColor = strained ? .systemRed : .labelColor
        detail.textColor = detailStrained ? .systemRed : .secondaryLabelColor
        chart.color = strained ? .systemRed : .controlAccentColor
    }
}

/// An app in a short list: icon, name, main figure and a quieter second figure.
final class AppLine: NSView {
    private let icon = NSImageView()
    private let name = Style.label()
    private let value = Style.label("", font: Style.figure)
    private let detail = Style.label("", font: Style.smallFigure, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        value.alignment = .right
        detail.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = Style.stack([icon, name, detail, value], axis: .horizontal, spacing: Style.gap)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            value.widthAnchor.constraint(equalToConstant: 52),
            detail.widthAnchor.constraint(equalToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(icon image: NSImage, name text: String, value figure: String, detail second: String) {
        icon.image = image
        if name.stringValue != text { name.stringValue = text }
        if value.stringValue != figure { value.stringValue = figure }
        if detail.stringValue != second { detail.stringValue = second }
    }
}
