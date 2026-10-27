import AppKit

/// Colours and type for the card style: light grey ground, white cards with a
/// hairline border, small uppercase mono captions and large plain figures.
/// Every colour has a dark value so a later dark mode only needs the switch.
enum Theme {
    static let ground = dynamic(0xF4F4F6, 0x161618)
    static let panel = dynamic(0xF8F8F9, 0x1C1C1F)
    static let card = dynamic(0xFFFFFF, 0x232327)
    static let cardBorder = dynamic(0xE6E6EA, 0x34343A)
    static let selectionWash = dynamic(0xE6EAFB, 0x2C3350)
    static let cardBorderHover = dynamic(0xD2D2D9, 0x4A4A52)
    static let rule = dynamic(0xEDEDF0, 0x2E2E33)
    static let ink = dynamic(0x17171A, 0xF2F2F4)
    static let inkSecondary = dynamic(0x6E6E78, 0xA0A0AA)
    static let inkTertiary = dynamic(0xA2A2AB, 0x6C6C75)
    static let track = dynamic(0xE7E7EB, 0x34343A)
    static let hover = dynamic(0xF3F3F5, 0x2A2A2F)

    static let accent = dynamic(0x3A4ED6, 0x7383F0)
    static let accentLow = dynamic(0xE3E6FB, 0x2A2F55)
    static let good = dynamic(0x1F9D55, 0x4ACB7E)
    static let goodWash = dynamic(0xE7F6EC, 0x1D3527)
    static let warn = dynamic(0xC7860A, 0xE8B04A)
    static let warnWash = dynamic(0xFBF1DD, 0x3A2F1A)
    static let bad = dynamic(0xD63F2C, 0xF0705E)
    static let badWash = dynamic(0xFBE6E2, 0x41221E)
    static let action = dynamic(0xE85A2C, 0xF06A3C)
    static let actionPressed = dynamic(0xCF4A1F, 0xD85A2C)
    static let tooltip = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.96)

    /// Category colours, in the order charts use them.
    static let series: [NSColor] = [
        dynamic(0x3A4ED6, 0x7383F0),  // indigo
        dynamic(0xE0912A, 0xF0A84A),  // amber
        dynamic(0x8B7BE8, 0xA597F2),  // violet
        dynamic(0x55B9D3, 0x6FCBE2),  // teal
        dynamic(0x6CC48B, 0x84D6A0),  // green
        dynamic(0xD9668A, 0xE884A3),  // rose
    ]

    static let radius: CGFloat = 12
    static let panelRadius: CGFloat = 16

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func figure(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 10, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// The heat scale used by the core map: pale at zero, deep indigo at full.
    static func heat(_ value: Float, appearance: NSAppearance) -> NSColor {
        let t = CGFloat(min(1, max(0, value)))
        var low = NSColor.clear, high = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            low = accentLow.usingColorSpace(.sRGB) ?? .white
            high = (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(0x8C9AF6) : hex(0x2536C4))
        }
        // A curve so mid values read as clearly busy, as in a perceptual ramp.
        let k = pow(t, 0.75)
        return NSColor(srgbRed: low.redComponent + (high.redComponent - low.redComponent) * k,
                       green: low.greenComponent + (high.greenComponent - low.greenComponent) * k,
                       blue: low.blueComponent + (high.blueComponent - low.blueComponent) * k, alpha: 1)
    }

    /// Uppercase caption text with the wide tracking the mono labels use.
    static func caption(_ text: String, color: NSColor = Theme.inkTertiary, size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(size), .foregroundColor: color, .kern: 0.6,
        ])
    }

    /// A card's title: a small icon tile in the page colour, then the name.
    @MainActor
    static func header(_ name: String, symbol: String, tint: NSColor, size: CGFloat = 12.5, tile: CGFloat = 20,
                       color: NSColor = Theme.inkSecondary, weight: NSFont.Weight = .medium) -> NSAttributedString {
        let font = sans(size, weight)
        let attachment = NSTextAttachment()
        attachment.image = IconTile.image(symbol, tint: tint, size: tile, appearance: NSApp.effectiveAppearance)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - tile) / 2, width: tile, height: tile)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: "  " + name, attributes: [.font: font, .foregroundColor: color]))
        return text
    }

    /// The symbol for a card or tile by its name; a dot when there is none.
    static func symbol(for name: String) -> String {
        let table: [String: String] = [
            "CPU": "cpu", "Memory": "memorychip", "GPU": "cube.fill", "Disk": "internaldrive", "Network": "globe",
            "Power": "bolt.fill", "Temperature": "thermometer.medium", "Developer": "chevron.left.forwardslash.chevron.right",
            "User": "person.fill", "System": "gearshape.2.fill", "Load average": "gauge.with.dots.needle.50percent",
            "Processes": "square.stack.3d.up.fill", "Busiest app": "crown.fill", "Pressure": "gauge.with.dots.needle.67percent",
            "Available": "tray.fill", "Swap used": "arrow.left.arrow.right", "Compressed": "arrow.down.right.and.arrow.up.left",
            "Largest app": "crown.fill", "Reading": "arrow.down.doc.fill", "Writing": "arrow.up.doc.fill",
            "Read today": "calendar", "Written today": "calendar", "Busiest writer": "crown.fill",
            "Downloaded today": "arrow.down.circle.fill", "Uploaded today": "arrow.up.circle.fill", "Last 7 days": "calendar",
            "Last 30 days": "calendar", "Using most power": "crown.fill", "Average": "chart.bar.fill", "Peak": "arrow.up.to.line",
            "GPU memory": "memorychip", "GPU power": "bolt.fill", "Power now": "bolt.fill", "Battery power": "battery.75percent",
            "Battery temperature": "thermometer.medium", "Cycle count": "arrow.triangle.2.circlepath", "Maximum capacity": "battery.100percent",
            "Open ports": "point.3.connected.trianglepath.dotted", "Published ports": "point.3.connected.trianglepath.dotted",
            "Closest to its limit": "exclamationmark.triangle.fill", "Agents running": "sparkles", "Tokens today": "text.bubble.fill",
            "Apps": "square.grid.2x2.fill", "Cores": "cpu", "By kind": "chart.pie.fill", "Volumes": "internaldrive.fill",
            "Battery": "battery.100percent", "Keeping this Mac awake": "cup.and.saucer.fill", "Worth a look": "lightbulb.fill",
            "Temperatures": "thermometer.medium", "Fans": "fan.fill", "Accessories": "keyboard.fill", "Output": "speaker.wave.2.fill",
            "Input": "mic.fill", "Apps with sound open": "music.note", "Devices": "dot.radiowaves.left.and.right",
            "Disk use": "internaldrive", "Plan limits": "gauge.with.needle.fill", "Running": "sparkles",
            "Neural Engine": "brain", "Containers": "shippingbox.fill", "Projects": "folder.fill", "Coding Agents": "sparkles",
        ]
        return table[name] ?? "circle.fill"
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["WISP_NO_MOTION"] != nil
    }
}
