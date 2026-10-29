import AppKit
import WispCore

extension PageID {
    /// Each page's colour, used for its icon tile here and its accents on the page.
    var tint: NSColor {
        switch self {
        case .overview: return Theme.blue
        case .apps: return Theme.gray
        case .cpu: return Theme.blue
        case .memory: return Theme.indigo
        case .gpu: return Theme.pink
        case .neural: return Theme.purple
        case .energy: return Theme.orange
        case .disk: return Theme.cyan
        case .network: return Theme.green
        case .sound: return Theme.pink
        case .bluetooth: return Theme.blue
        case .sensors: return Theme.orange
        case .ports: return Theme.blue
        case .docker: return Theme.teal
        case .agents: return Theme.purple
        case .settings: return Theme.gray
        }
    }

    var shortcut: String? {
        PageID.allCases.firstIndex(of: self).flatMap { $0 < 9 ? String($0 + 1) : nil }
    }
}

/// A small rounded square in a page's colour with its symbol on it.
enum IconTile {
    private static var cache: [String: NSImage] = [:]

    /// A bare SF Symbol in a colour, rasterised once like the tiles.
    static func glyph(_ symbol: String, tint: NSColor, size: CGFloat = 16, appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "glyph|\(symbol)|\(size)|\(dark)|\(tint.hash)"
        if let image = cache[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [2, 1] as [CGFloat] {
            let pixels = Int(size * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appearance.performAsCurrentDrawingAppearance {
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .regular)
                    .applying(.init(paletteColors: [tint]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = glyph.size
                    glyph.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        cache[key] = image
        return image
    }

    static func image(_ symbol: String, tint: NSColor, size: CGFloat = 22, solid: Bool = false, appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(symbol)|\(size)|\(solid)|\(dark)|\(tint.hash)"
        if let image = cache[key] { return image }
        // Rasterised once into a bitmap. An image that redraws from a block on every use
        // sends image views through Core Animation's in-process GPU drawing, which keeps
        // a buffer pool of about 190 MB.
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [2, 1] as [CGFloat] {
            let pixels = Int(size * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appearance.performAsCurrentDrawingAppearance {
                let rect = NSRect(x: 0, y: 0, width: size, height: size)
                (solid ? tint : tint.withAlphaComponent(dark ? 0.24 : 0.14)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28).fill()
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
                    .applying(.init(paletteColors: [solid ? .white : tint]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = glyph.size
                    glyph.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
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

    /// A figure worth noticing (memory under pressure, a hot sensor) shows in orange.
    var valueWarns = false { didSet { if valueWarns != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, !selected {
            Theme.ink.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        // Tahoe source list: a plain symbol in the accent colour, the name, the figure.
        IconTile.glyph(page.symbol, tint: Theme.blue, size: 16, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                              .foregroundColor: valueWarns ? Theme.warn : Theme.inkSecondary]
        let valueWidth = value.isEmpty ? 0 : ceil((value as NSString).size(withAttributes: valueAttributes).width)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (page.title as NSString).draw(with: NSRect(x: 33, y: (bounds.height - 16) / 2, width: bounds.width - 45 - valueWidth, height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
        if !value.isEmpty {
            (value as NSString).draw(at: NSPoint(x: bounds.width - 8 - valueWidth, y: (bounds.height - 15) / 2), withAttributes: valueAttributes)
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
            glass.cornerRadius = 16
            glass.style = .regular
            surface = glass
        } else {
            let card = CardView()
            card.fill = Theme.panel
            card.radius = 16
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
        // The selection is a soft grey fill, as in a Tahoe source list.
        highlight.cornerRadius = 9
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        content.layer?.addSublayer(highlight)

        for (title, pages) in PageID.sections {
            if let title {
                let header = TextLine(NSAttributedString(string: title.prefix(1).uppercased() + title.dropFirst().lowercased(),
                                                         attributes: [.font: Theme.sans(11, .semibold), .foregroundColor: Theme.inkSecondary]))
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
        // The first row sits under the window buttons, which live on the sidebar.
        var y: CGFloat = 44
        var rowIndex = 0
        for (sectionIndex, (title, pages)) in PageID.sections.enumerated() {
            if title != nil {
                y += 12
                headers[sectionIndex].frame = NSRect(x: 19, y: y, width: width - 38, height: 14)
                y += 18
            }
            for _ in pages {
                rows[rowIndex].frame = NSRect(x: 10, y: y, width: width - 20, height: 28)
                y += 28
                rowIndex += 1
            }
        }
        settingsRow.frame = NSRect(x: 10, y: bounds.height - 38, width: width - 20, height: 28)
        // A short window hides the settings row rather than draw it over the pages.
        settingsRow.isHidden = y > bounds.height - 44
        placeHighlight(animated: false)
    }

    func select(_ page: PageID) {
        selectedPage = page
        for row in rows { row.selected = row.page == page }
        settingsRow.selected = page == .settings
        placeHighlight(animated: highlight.opacity > 0)
    }

    private func placeHighlight(animated: Bool) {
        guard let page = selectedPage else { return }
        let target: NSView? = page == .settings ? settingsRow : rows.first(where: { $0.page == page })
        guard let target, !target.isHidden else { highlight.opacity = 0; return }
        let from = highlight.presentation()?.frame ?? highlight.frame
        let to = target.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = to
        highlight.opacity = 1
        highlight.backgroundColor = (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.075)).cgColor
        CATransaction.commit()
        guard animated, !Theme.reduceMotion, from.height > 0, abs(from.minY - to.minY) > 1 else { return }
        stretch(from: from, to: to)
    }

    /// The highlight stretches toward the new row: its leading edge gets there
    /// first, the trailing edge follows and the pill settles back to one row.
    private func stretch(from: CGRect, to: CGRect) {
        let down = to.minY > from.minY
        let distance = abs(to.minY - from.minY)
        let duration = min(0.46, 0.3 + Double(distance) / 2400)
        let steps = 24
        var positions: [NSValue] = []
        var sizes: [NSValue] = []
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let lead = CGFloat(Motion.smoothOut(min(1, t / 0.62)))
            let trail = CGFloat(Motion.smoothOut(max(0, (t - 0.14) / 0.86)))
            let top = from.minY + (to.minY - from.minY) * (down ? trail : lead)
            let bottom = from.maxY + (to.maxY - from.maxY) * (down ? lead : trail)
            positions.append(NSValue(point: NSPoint(x: to.midX, y: (top + bottom) / 2)))
            sizes.append(NSValue(size: NSSize(width: to.width, height: bottom - top)))
        }
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = positions
        let size = CAKeyframeAnimation(keyPath: "bounds.size")
        size.values = sizes
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = duration
        highlight.add(group, forKey: "move")
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
        for row in rows {
            row.value = values[row.page] ?? ""
            switch row.page {
            case .memory: row.valueWarns = (s.memory?.pressure ?? .normal) != .normal
            case .sensors: row.valueWarns = (s.thermal?.cpuCelsius ?? 0) >= 90
            default: row.valueWarns = false
            }
        }
    }
}

/// The settings row at the foot of the sidebar.
final class NavRowButton: DrawnView {
    let title: String
    let symbol: String
    var onClick: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
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
        if hovering && !selected {
            Theme.ink.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        IconTile.glyph(symbol, tint: Theme.blue, size: 16, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        (title as NSString).draw(at: NSPoint(x: 33, y: (bounds.height - 16) / 2),
                                 withAttributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink])
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
