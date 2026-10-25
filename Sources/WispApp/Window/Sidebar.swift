import AppKit
import WispCore

extension PageID {
    /// Each page's colour, used for its icon tile here and its accents on the page.
    var tint: NSColor {
        switch self {
        case .overview: return Theme.dynamic(0x3A4ED6, 0x7383F0)
        case .apps: return Theme.dynamic(0x5B6472, 0x9AA3B2)
        case .cpu: return Theme.dynamic(0x2F6BF0, 0x5C8DF6)
        case .memory: return Theme.dynamic(0x7B61E6, 0x9C88F2)
        case .gpu: return Theme.dynamic(0xD9487A, 0xEB6F98)
        case .neural: return Theme.dynamic(0x9B57D6, 0xB77CEB)
        case .energy: return Theme.dynamic(0xE08A1E, 0xF0A84A)
        case .disk: return Theme.dynamic(0xE0662A, 0xF0864E)
        case .network: return Theme.dynamic(0x1F9D72, 0x4ACB98)
        case .sound: return Theme.dynamic(0xE0457B, 0xF06A97)
        case .bluetooth: return Theme.dynamic(0x2F7CF6, 0x5C9BF8)
        case .sensors: return Theme.dynamic(0xE2553A, 0xF0785E)
        case .ports: return Theme.dynamic(0x2E95D3, 0x5CB2E6)
        case .docker: return Theme.dynamic(0x1FA2B4, 0x48C2D2)
        case .agents: return Theme.dynamic(0x6E56E0, 0x9480F0)
        }
    }

    var shortcut: String? {
        PageID.allCases.firstIndex(of: self).flatMap { $0 < 9 ? String($0 + 1) : nil }
    }
}

/// A small rounded square in a page's colour with its symbol on it.
enum IconTile {
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String, tint: NSColor, size: CGFloat = 22, solid: Bool = false, appearance: NSAppearance) -> NSImage {
        let key = "\(symbol)|\(size)|\(solid)|\(appearance.name.rawValue)|\(tint.hash)"
        if let image = cache[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                (solid ? tint : tint.withAlphaComponent(0.14)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28).fill()
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
                    .applying(.init(paletteColors: [solid ? .white : tint]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = glyph.size
                    glyph.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
                }
            }
            return true
        }
        cache[key] = image
        return image
    }
}

/// One page in the sidebar: icon tile, name, and a live figure on the right.
final class NavRow: DrawnView {
    let page: PageID
    var value = "" { didSet { if value != oldValue { needsDisplay = true } } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(page: PageID) {
        self.page = page
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(page.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, !selected {
            Theme.ink.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let tile = IconTile.image(page.symbol, tint: page.tint, solid: selected, appearance: effectiveAppearance)
        tile.draw(in: NSRect(x: 8, y: (bounds.height - 22) / 2, width: 22, height: 22), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Theme.mono(10, .regular), .foregroundColor: Theme.inkTertiary]
        let valueWidth = value.isEmpty ? 0 : ceil((value as NSString).size(withAttributes: valueAttributes).width)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (page.title as NSString).draw(with: NSRect(x: 40, y: (bounds.height - 17) / 2, width: bounds.width - 52 - valueWidth, height: 17),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: Theme.sans(13, selected ? .semibold : .regular),
                                                   .foregroundColor: selected ? Theme.ink : Theme.ink.withAlphaComponent(0.82),
                                                   .paragraphStyle: paragraph])
        if !value.isEmpty {
            (value as NSString).draw(at: NSPoint(x: bounds.width - 10 - valueWidth, y: (bounds.height - 13) / 2), withAttributes: valueAttributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The floating sidebar: brand, pages in sections with live figures, settings.
/// It sits on Liquid Glass where the system has it. Behind it is only the window's
/// ground, which never changes, so the glass has nothing to re-render.
@MainActor
final class Sidebar: NSView {
    var onSelect: ((PageID) -> Void)?
    var onSettings: (() -> Void)?
    private(set) var rows: [NavRow] = []
    private var headers: [TextLine] = []
    private let brand = TextLine()
    private let machine = TextLine()
    private let highlight = CALayer()
    private let surface: NSView
    private let content = FlippedContent()
    private let settingsRow = NavRowButton(title: "Settings", symbol: "gearshape")
    private var selectedPage: PageID?

    final class FlippedContent: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.style = .regular
            surface = glass
        } else {
            let card = CardView()
            card.fill = Theme.panel
            card.radius = 18
            surface = card
        }
        super.init(frame: frame)
        addSubview(surface)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = content
        } else {
            surface.addSubview(content)
        }
        content.wantsLayer = true
        highlight.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        highlight.cornerRadius = 9
        highlight.shadowColor = NSColor.black.cgColor
        highlight.shadowOpacity = 0.08
        highlight.shadowRadius = 3
        highlight.shadowOffset = CGSize(width: 0, height: -1)
        highlight.opacity = 0
        content.layer?.addSublayer(highlight)

        brand.text = NSAttributedString(string: "Wisp", attributes: [.font: Theme.sans(15, .semibold), .foregroundColor: Theme.ink])
        machine.text = Theme.caption(Self.machineName(), size: 9)
        content.addSubview(brand)
        content.addSubview(machine)
        for (title, pages) in PageID.sections {
            if let title {
                let header = TextLine(Theme.caption(title, size: 9.5))
                headers.append(header)
                content.addSubview(header)
            } else {
                headers.append(TextLine())
            }
            for page in pages {
                let row = NavRow(page: page)
                row.onClick = { [weak self] in self?.onSelect?(page) }
                rows.append(row)
                content.addSubview(row)
            }
        }
        settingsRow.onClick = { [weak self] in self?.onSettings?() }
        content.addSubview(settingsRow)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    static func machineName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = String(cString: bytes).replacingOccurrences(of: "Apple ", with: "")
        let memory = ProcessInfo.processInfo.physicalMemory
        return "\(chip) · \(Int((Double(memory) / 1_073_741_824).rounded())) GB"
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        content.frame = surface.bounds
        let width = bounds.width
        // Room for the window buttons, which sit over the sidebar.
        brand.frame = NSRect(x: 18, y: 46, width: width - 36, height: 20)
        machine.frame = NSRect(x: 18, y: 67, width: width - 36, height: 12)
        var y: CGFloat = 92
        var rowIndex = 0
        for (sectionIndex, (title, pages)) in PageID.sections.enumerated() {
            if title != nil {
                y += 10
                headers[sectionIndex].frame = NSRect(x: 18, y: y, width: width - 36, height: 14)
                y += 20
            }
            for _ in pages {
                rows[rowIndex].frame = NSRect(x: 8, y: y, width: width - 16, height: 30)
                y += 30
                rowIndex += 1
            }
        }
        settingsRow.frame = NSRect(x: 8, y: bounds.height - 44, width: width - 16, height: 32)
        // A short window hides the settings row rather than draw it over the pages.
        settingsRow.isHidden = y > bounds.height - 44
        placeHighlight(animated: false)
    }

    func select(_ page: PageID) {
        selectedPage = page
        for row in rows { row.selected = row.page == page }
        placeHighlight(animated: highlight.opacity > 0)
    }

    private func placeHighlight(animated: Bool) {
        guard let page = selectedPage, let row = rows.first(where: { $0.page == page }) else { return }
        CATransaction.begin()
        if animated && !Theme.reduceMotion {
            CATransaction.setAnimationDuration(0.26)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        highlight.frame = row.frame
        highlight.opacity = 1
        highlight.backgroundColor = (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.92)).cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        placeHighlight(animated: false)
    }

    /// Live figures beside the machine pages. Only rows whose text changed redraw.
    func update(system s: SystemSnapshot) {
        var values: [PageID: String] = [:]
        if let cpu = s.cpu { values[.cpu] = String(format: "%.0f%%", cpu.total * 100) }
        if let memory = s.memory { values[.memory] = Format.memory(memory.used).replacingOccurrences(of: " ", with: "\u{2009}") }
        if let gpu = s.gpu?.utilization { values[.gpu] = String(format: "%.0f%%", gpu * 100) }
        if let power = s.power, let cpu = power.cpu { values[.energy] = String(format: "%.0f W", cpu + (power.gpu ?? 0) + (power.ane ?? 0)) }
        if let ane = s.power?.ane { values[.neural] = ane < 0.05 ? "Idle" : String(format: "%.1f W", ane) }
        if let net = s.network { values[.network] = Format.rate(net.receivedBytesPerSecond + net.sentBytesPerSecond) }
        if let disk = s.disk { values[.disk] = Format.rate(disk.readBytesPerSecond + disk.writeBytesPerSecond) }
        if let celsius = s.thermal?.cpuCelsius { values[.sensors] = Format.celsius(celsius) }
        for row in rows { row.value = values[row.page] ?? "" }
    }
}

/// The settings row at the foot of the sidebar.
final class NavRowButton: DrawnView {
    let title: String
    let symbol: String
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.ink.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        IconTile.image(symbol, tint: Theme.inkSecondary, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 8, y: (bounds.height - 22) / 2, width: 22, height: 22), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        (title as NSString).draw(at: NSPoint(x: 40, y: (bounds.height - 17) / 2),
                                 withAttributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink.withAlphaComponent(0.82)])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
