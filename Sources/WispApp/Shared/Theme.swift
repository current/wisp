import AppKit

/// Colours and type for the card style: light grey ground, white cards with a
/// hairline border, small uppercase mono captions and large plain figures.
/// Every colour has a dark value so a later dark mode only needs the switch.
enum Theme {
    /// Liquid Glass is drawn by the window server, so a window drawn into a PNG by
    /// Wisp itself (WISP_SNAPSHOT, WISP_POPOVER_SNAPSHOT) or run with WISP_NO_GLASS
    /// uses solid panels in its place.
    static let solidPanels: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["WISP_NO_GLASS", "WISP_SNAPSHOT", "WISP_POPOVER_SNAPSHOT", "WISP_AUDIT"].contains { environment[$0] != nil }
    }()
    // Tahoe: a light grey content area, white cards with a hairline edge, system
    // colours and SF Pro throughout. Every colour has a dark value.
    static let ground = dynamic(0xF2F2F5, 0x1D1D1F)
    static let panel = dynamic(0xFFFFFF, 0x252527)
    static let card = dynamic(0xFFFFFF, 0x272729)
    static let cardBorder = dynamic(0xE2E2E5, 0x363638)
    /// The sidebar where there is no window-server material behind it (snapshots).
    static let sidebarFill = dynamic(0xECEDF1, 0x2A2B30)
    /// The hairline between the sidebar and the page.
    static let sidebarEdge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08)
    }
    static let sidebarHeader = dynamic(0x9A9AA0, 0x636368)
    static let selectionWash = dynamic(0xE5F1FF, 0x1E3550)
    static let cardBorderHover = dynamic(0xC9C9CE, 0x55555B)
    static let rule = dynamic(0xE8E8EA, 0x36363A)
    static let ink = dynamic(0x262626, 0xEDEDEF)
    static let inkSecondary = dynamic(0x808080, 0x98989D)
    static let inkTertiary = dynamic(0xB0B0B4, 0x636366)
    static let track = dynamic(0xEBEBED, 0x3A3A3E)
    static let hover = dynamic(0xF0F0F2, 0x323236)
    /// Every other row of a table, quieter than hover.
    static let stripe = dynamic(0xF6F6F7, 0x2F2F32)
    static let fill = dynamic(0xF5F5F7, 0x323236)

    static let accent = dynamic(0x0088FF, 0x0A91FF)
    static let accentLow = dynamic(0xDCEDFF, 0x1C3550)
    static let good = dynamic(0x28A745, 0x34C759)
    static let goodWash = dynamic(0xE3F7E8, 0x1D3527)
    static let warn = dynamic(0xD96C00, 0xFF9F0A)
    static let warnWash = dynamic(0xFFF0DE, 0x3A2C17)
    static let bad = dynamic(0xE5302F, 0xFF453A)
    static let badWash = dynamic(0xFFE3E2, 0x44201F)
    static let action = dynamic(0x0088FF, 0x0A91FF)
    static let actionPressed = dynamic(0x0070D6, 0x0077DD)
    static let tooltip = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.96)

    /// Apple's system colours, as Tahoe uses them.
    static let blue = dynamic(0x0088FF, 0x0A91FF)
    static let cyan = dynamic(0x00C0E8, 0x3CD3FE)
    static let green = dynamic(0x34C759, 0x30D158)
    static let orange = dynamic(0xFF8D28, 0xFF9F0A)
    static let red = dynamic(0xFF383C, 0xFF453A)
    static let pink = dynamic(0xFF2D55, 0xFF375F)
    static let purple = dynamic(0xCB30E0, 0xDA8FFF)
    static let indigo = dynamic(0x6155F5, 0x7D7AFF)
    static let yellow = dynamic(0xFFCC00, 0xFFD60A)
    static let teal = dynamic(0x00C3D0, 0x40CBE0)
    static let gray = dynamic(0x8E8E93, 0x98989D)

    /// Category colours, in the order charts use them.
    static let series: [NSColor] = [blue, cyan, indigo, orange, green, pink]

    static let radius: CGFloat = 18
    static let panelRadius: CGFloat = 18

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// Figures: SF Pro semibold with tabular digits.
    static func figure(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight == .regular ? .semibold : weight)
    }

    /// Small figures and labels. Tahoe keeps SF Pro here too, with tabular digits.
    static func mono(_ size: CGFloat = 10, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size + 1, weight: weight == .medium ? .regular : weight)
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

    /// Caption text: SF Pro 11 in the secondary label colour, sentence case.
    static func caption(_ text: String, color: NSColor = Theme.inkSecondary, size: CGFloat = 10) -> NSAttributedString {
        let sentence = text.prefix(1).uppercased() + text.dropFirst()
        return NSAttributedString(string: sentence, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size + 1, weight: .regular),
            .foregroundColor: color == Theme.inkTertiary ? Theme.inkSecondary : color,
        ])
    }

    /// A card's title, Tahoe style: the symbol and the name, both in the card's colour.
    @MainActor
    static func header(_ name: String, symbol: String, tint: NSColor, size: CGFloat = 13, tile: CGFloat = 16,
                       color: NSColor = Theme.inkSecondary, weight: NSFont.Weight = .semibold) -> NSAttributedString {
        let font = sans(13, .semibold)
        let glyph: CGFloat = 16
        let attachment = NSTextAttachment()
        attachment.image = IconTile.glyph(symbol, tint: tint, size: glyph, appearance: NSApp.effectiveAppearance)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - glyph) / 2, width: glyph, height: glyph)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + name, attributes: [.font: font, .foregroundColor: tint]))
        return text
    }

    /// The symbol for a card or tile by its name; a dot when there is none.
    static func symbol(for name: String) -> String {
        let table: [String: String] = [
            "CPU": PageID.cpu.symbol, "Memory": PageID.memory.symbol, "GPU": PageID.gpu.symbol, "Disk": PageID.disk.symbol,
            "Storage": PageID.disk.symbol, "Network": PageID.network.symbol,
            "Power": "bolt.fill", "Temperature": PageID.sensors.symbol, "Developer": "chevron.left.forwardslash.chevron.right",
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
            "Apps": PageID.apps.symbol, "Cores": PageID.cpu.symbol, "By kind": "chart.pie.fill", "Volumes": "internaldrive.fill",
            "Battery": "battery.100percent", "Keeping this Mac awake": "cup.and.saucer.fill", "Worth a look": "lightbulb.fill",
            "Temperatures": PageID.sensors.symbol, "Fans": "fan.fill", "Accessories": "keyboard.fill", "Output": "speaker.wave.2.fill",
            "Input": "mic.fill", "Apps with sound open": "music.note", "Devices": "dot.radiowaves.left.and.right",
            "Disk use": "internaldrive", "Plan limits": "gauge.with.needle.fill", "Running": "sparkles",
            "Mac draws now": "powerplug.fill", "Adapter": "bolt.fill", "Chip power": "cpu", "Low Power Mode": "leaf.fill",
            "Screen on": "sun.max.fill", "Drain": "arrow.down.right", "Battery health": "heart.fill",
            "Battery used by apps": "chart.bar.fill", "Energy used by apps": "chart.bar.fill", "Apps now": "square.grid.2x2.fill",
            "Most data": "chart.bar.fill", "Hosts": "server.rack",
            "Neural Engine": PageID.neural.symbol, "Containers": PageID.docker.symbol, "Projects": PageID.ports.symbol,
            "Coding Agents": PageID.agents.symbol,
        ]
        return table[name] ?? "circle.fill"
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["WISP_NO_MOTION"] != nil
    }
}
