import AppKit
import WispCore

/// Temperatures, fans and the battery. Read only: changing fan speed needs a
/// privileged helper, which Wisp does not install.
@MainActor
final class SensorsPage: NSViewController, Page {
    private unowned let delegate: AppDelegate
    private let temperatures = NSGridView()
    private let fans = NSGridView()
    private let battery = NSGridView()
    private let accessories = NSGridView()
    private var accessoryReadings: [AccessoryBattery] = []
    private var accessoriesRead = Date.distantPast
    private var values: [String: NSTextField] = [:]
    private var layoutKey = ""

    var demand: Demand { [.thermal, .battery] }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for grid in [temperatures, fans, battery, accessories] {
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = Style.gap
            grid.columnSpacing = Style.section
        }
        let stack = Style.stack([heading("Temperatures"), temperatures, heading("Fans"), fans, heading("Battery"), battery, heading("Accessories"), accessories],
                                axis: .vertical, spacing: Style.gap, alignment: .leading)
        stack.setCustomSpacing(Style.section + Style.unit, after: temperatures)
        stack.setCustomSpacing(Style.section + Style.unit, after: fans)
        stack.setCustomSpacing(Style.section + Style.unit, after: battery)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Style.section),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Style.section),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Style.pad),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Style.section),
        ])
        view = scroll
    }

    private func heading(_ text: String) -> NSTextField {
        Style.label(text, font: NSFont.systemFont(ofSize: 15, weight: .semibold))
    }

    func update(system s: SystemSnapshot) {
        let sensors = s.thermal?.sensors ?? []
        let fanList = s.thermal?.fans ?? []
        var batteryRows: [(String, String)] = []
        if let b = s.battery {
            batteryRows.append(("Charge", Format.percent(b.percent / 100)))
            batteryRows.append(("State", b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in, not charging" : "On battery")))
            if let minutes = b.minutesRemaining, minutes > 0 { batteryRows.append(("Time left", Format.duration(Double(minutes) * 60))) }
            if let health = b.health { batteryRows.append(("Capacity", Format.percent(health) + " of new")) }
            if let cycles = b.cycleCount { batteryRows.append(("Cycles", "\(cycles)")) }
            if let watts = b.watts { batteryRows.append((watts < 0 ? "Drawing" : "Charging at", Format.watts(abs(watts)))) }
            if let adapter = b.adapterWatts { batteryRows.append(("Adapter", "\(adapter) W")) }
            if let celsius = b.temperature { batteryRows.append(("Temperature", Format.celsius(celsius))) }
        }

        if Date().timeIntervalSince(accessoriesRead) > 60 {
            accessoriesRead = Date()
            accessoryReadings = Accessories.batteries()
        }

        // Rebuild the grids only when the set of rows changes; otherwise just set text.
        let key = sensors.map(\.key).joined() + "|\(fanList.count)|" + batteryRows.map(\.0).joined() + "|" + accessoryReadings.map(\.name).joined()
        if key != layoutKey {
            layoutKey = key
            values.removeAll()
            fill(temperatures, sensors.map { ("t." + $0.key, $0.name) }, empty: "No temperature sensors found")
            fill(fans, fanList.map { ("f.\($0.index)", "Fan \($0.index + 1)") }, empty: "This Mac has no fans")
            fill(battery, batteryRows.map { ("b." + $0.0, $0.0) }, empty: "No battery")
            fill(accessories, accessoryReadings.map { ("a." + $0.name, $0.name) }, empty: "No Bluetooth keyboard, mouse or trackpad reports a battery")
        }
        for sensor in sensors { values["t." + sensor.key]?.stringValue = Format.celsius(sensor.celsius) }
        for fan in fanList {
            var text = "\(Int(fan.rpm)) rpm"
            if let low = fan.minRPM, let high = fan.maxRPM, high > low { text += "  (\(Int(low))–\(Int(high)))" }
            values["f.\(fan.index)"]?.stringValue = text
        }
        for (name, value) in batteryRows { values["b." + name]?.stringValue = value }
        for accessory in accessoryReadings { values["a." + accessory.name]?.stringValue = "\(accessory.percent)%" }
    }

    private func fill(_ grid: NSGridView, _ rows: [(String, String)], empty: String) {
        grid.clear()
        guard !rows.isEmpty else {
            grid.addRow(with: [Style.secondary(empty, font: Style.body)])
            return
        }
        for (key, name) in rows {
            let value = Style.label("–", font: Style.figure)
            value.alignment = .right
            values[key] = value
            grid.addRow(with: [Style.label(name), value])
        }
        grid.column(at: 0).width = 200
        if grid.numberOfColumns > 1 {
            grid.column(at: 1).xPlacement = .trailing
            grid.column(at: 1).width = 140
        }
    }
}
