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
        case .startup: return Theme.teal
        case .cleanup: return Theme.cyan
        case .settings: return Theme.gray
        }
    }

    var shortcut: String? {
        PageID.allCases.firstIndex(of: self).flatMap { $0 < 9 ? String($0 + 1) : nil }
    }
}

/// A small rounded square in a page's colour with its symbol on it.
enum IconTile {
    private static var cache: [String: NSImage] = [:] {
        didSet { if cache.count > 600 { cache.removeAll() } }
    }

    /// The colour as it draws in `appearance`. Its hash would not do: most tints are dynamic
    /// colours made fresh on each call, and keying on those kept every bitmap forever.
    private static func colorKey(_ color: NSColor, _ appearance: NSAppearance) -> String {
        var key = ""
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else {
                key = color.description
                return
            }
            key = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                .map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
        }
        return key
    }

    /// A bare SF Symbol in a colour, rasterised once like the tiles.
    static func glyph(_ symbol: String, tint: NSColor, size: CGFloat = 16, appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "glyph|\(symbol)|\(size)|\(dark)|\(colorKey(tint, appearance))"
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
        let key = "\(symbol)|\(size)|\(solid)|\(dark)|\(colorKey(tint, appearance))"
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
            .draw(in: NSRect(x: 10.5, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Theme.digits(12, .regular),
                                                              .foregroundColor: valueWarns ? Theme.warn : Theme.inkSecondary]
        let valueWidth = value.isEmpty ? 0 : ceil((value as NSString).size(withAttributes: valueAttributes).width)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (page.title as NSString).draw(with: NSRect(x: 36, y: (bounds.height - 16) / 2, width: bounds.width - 50 - valueWidth, height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink,
                                                   .paragraphStyle: paragraph])
        if !value.isEmpty {
            (value as NSString).draw(at: NSPoint(x: bounds.width - 10 - valueWidth, y: (bounds.height - 15) / 2), withAttributes: valueAttributes)
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

/// The sidebar: pages in sections with live figures, settings at the foot. It runs the
/// full height of the window on a blur of the desktop behind the window.
/// The window's own corners round its left side. Snapshots, which have no glass, use a
/// tinted surface in its place.
@MainActor
final class Sidebar: NSView {
    var onSelect: ((PageID) -> Void)?
    /// The Settings row opens the Settings window.
    var onSettings: (() -> Void)?
    private(set) var rows: [NavRow] = []
    private var headers: [SectionHeader] = []
    /// Sections folded shut from their header; kept between launches.
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "WispSidebarCollapsed") ?? [])
    private let brand = TextLine()
    private let machine = TextLine()
    private let highlight = CALayer()
    private let surface: NSView

    /// The window server's blur needs a real window behind it; snapshots draw a tint instead.
    static var usesGlass: Bool { !Theme.solidPanels }
    private let content = FlippedContent()
    /// Dark mode lays a dark wash over the blur: the window server blurs whatever is
    /// behind the window, which in dark mode is often a light window.
    private let wash = SidebarWash()
    /// The hairline on the right edge, against the page, and the one over the Settings row.
    private let edge = CALayer()
    private let footRule = CALayer()
    private let settingsRow = NavRowButton(title: "Settings", symbol: PageID.settings.symbol)
    private var selectedPage: PageID?

    final class FlippedContent: NSView {
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    override init(frame: NSRect) {
        if Self.usesGlass {
            // Of the behind-window materials, this one keeps the most of the desktop's colour.
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            surface = blur
        } else {
            surface = SidebarSurface()
        }
        super.init(frame: frame)
        addSubview(surface)
        if Self.usesGlass { addSubview(wash) }
        addSubview(content)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        for rule in [edge, footRule] {
            rule.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
            content.layer?.addSublayer(rule)
        }
        // The selection is a soft grey fill, as in a Tahoe source list.
        highlight.cornerRadius = 9
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        content.layer?.addSublayer(highlight)

        for (title, pages) in PageID.sections {
            let header = SectionHeader(title: title.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() } ?? "")
            header.collapsed = title.map(collapsed.contains) ?? false
            if let title {
                header.onClick = { [weak self] in self?.toggle(section: title) }
                content.addSubview(header)
            }
            headers.append(header)
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
        wash.frame = bounds
        content.frame = bounds
        placeRules()
        apply(frames())
        placeHighlight(animated: false)
    }

    private func placeRules() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height)
        footRule.frame = CGRect(x: 12, y: bounds.height - 50, width: bounds.width - 24, height: 0.5)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edge.backgroundColor = Theme.sidebarEdge.cgColor
            footRule.backgroundColor = Theme.sidebarEdge.cgColor
        }
        CATransaction.commit()
    }

    /// Where every row goes, and how visible it is.
    private func frames() -> [(NSView, NSRect, CGFloat)] {
        let width = bounds.width
        var result: [(NSView, NSRect, CGFloat)] = []
        // The first row sits under the window buttons, which live on the sidebar.
        var y: CGFloat = 43
        var rowIndex = 0
        let pagesAlpha: CGFloat = 1
        let lift: CGFloat = 0
        // A short window closes the rows up rather than run them past the Settings row.
        let headerCount = CGFloat(PageID.sections.filter { $0.0 != nil }.count)
        let roomPerRow = (bounds.height - 43 - 58 - headerCount * 33) / CGFloat(rows.count)
        let pitch = max(22, min(30, roomPerRow.rounded(.down)))
        for (sectionIndex, (title, pages)) in PageID.sections.enumerated() {
            let shut = title.map(collapsed.contains) ?? false
            if title != nil {
                y += pitch < 30 ? 6 : 10
                result.append((headers[sectionIndex], NSRect(x: 10, y: y + lift, width: width - 20, height: 22), pagesAlpha))
                y += 23
            }
            for _ in pages {
                // A folded section's rows tuck under its header.
                result.append((rows[rowIndex], NSRect(x: 10, y: (shut ? y - pitch : y) + lift, width: width - 20, height: pitch), shut ? 0 : pagesAlpha))
                if !shut { y += pitch }
                rowIndex += 1
            }
        }
        result.append((settingsRow, NSRect(x: 10, y: bounds.height - 42, width: width - 20, height: 30), 1))
        return result
    }

    private func toggle(section title: String) {
        if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
        UserDefaults.standard.set(Array(collapsed), forKey: "WispSidebarCollapsed")
        for (header, (name, _)) in zip(headers, PageID.sections) { header.collapsed = name.map(collapsed.contains) ?? false }
        let targets = frames()
        guard window != nil, !Theme.reduceMotion, !MainWindowController.background else {
            apply(targets)
            return placeHighlight(animated: false)
        }
        for (view, _, alpha) in targets where alpha > 0 { view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            for (view, frame, alpha) in targets {
                view.animator().frame = frame
                view.animator().alphaValue = alpha
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for (view, _, alpha) in targets where alpha == 0 { view.isHidden = true }
                self?.placeHighlight(animated: false)
            }
        }
        placeHighlight(animated: false)
    }

    private func apply(_ frames: [(NSView, NSRect, CGFloat)]) {
        for (view, frame, alpha) in frames {
            view.frame = frame
            view.alphaValue = alpha
            view.isHidden = alpha == 0
        }
    }

    func select(_ page: PageID) {
        selectedPage = page
        for row in rows { row.selected = row.page == page }
        settingsRow.selected = page == .settings
        placeHighlight(animated: highlight.opacity > 0)
    }

    private func placeHighlight(animated: Bool) {
        guard let page = selectedPage else { return }
        let target: NSView? = page == .settings ? settingsRow : rows.first { $0.page == page }
        guard let target, !target.isHidden else { highlight.opacity = 0; return }
        let from = highlight.presentation()?.frame ?? highlight.frame
        let to = target.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = to
        highlight.opacity = 1
        highlight.backgroundColor = (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.075)).cgColor
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
        placeRules()
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
        if let celsius = s.thermal?.cpuCelsius { values[.sensors] = Format.celsius(celsius) }
        // Storage shows the free space, as the Storage page leads with it.
        if let disk = s.disk, disk.volumeTotal > 0 { values[.disk] = Format.bytes(disk.volumeFree) }
        if let apps = rows.first(where: { $0.page == .apps })?.value { values[.apps] = apps }
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

extension Sidebar {
    /// How many apps are running, beside Apps.
    func update(table: ProcessTable) {
        rows.first { $0.page == .apps }?.value = "\(table.apps.count)"
    }
}

/// A section's name over its rows, with a chevron that folds the section shut.
final class SectionHeader: DrawnView {
    let title: String
    var collapsed = false { didSet { if collapsed != oldValue { needsDisplay = true; setAccessibilityExpanded(!collapsed) } } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(!title.isEmpty)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !title.isEmpty else { return }
        (title as NSString).draw(at: NSPoint(x: 10, y: (bounds.height - 14) / 2),
                                 withAttributes: [.font: Theme.sans(11, .semibold), .foregroundColor: Theme.sidebarHeader, .kern: 0.11])
        // The chevron points down while open; it is quiet until the pointer is over the header.
        let side: CGFloat = 12
        let chevron = IconTile.glyph(collapsed ? "chevron.right" : "chevron.down",
                                     tint: hovering ? Theme.inkSecondary : Theme.sidebarHeader, size: side, appearance: effectiveAppearance)
        chevron.draw(in: NSRect(x: bounds.width - 10 - side, y: (bounds.height - side) / 2, width: side, height: side),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

/// The sidebar's frosted surface: a pale ground with the page's blue, indigo and orange
/// carried softly under it. Gradient layers, drawn by the render server; nothing redraws.
final class SidebarSurface: NSView {
    private let base = CAGradientLayer()
    private let glows = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The glows are wider than the sidebar; without the clip they spill over the page.
        layer?.masksToBounds = true
        layer?.addSublayer(base)
        for glow in glows {
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(glow)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        base.colors = (dark ? [0x303137, 0x28292F] : [0xF6F7FA, 0xEDEEF3]).map { Theme.hex($0).cgColor }
        // Centre (fraction of width and height), size (fraction of width and height), colour.
        let spots: [(CGPoint, CGSize, UInt32, CGFloat)] = [
            (CGPoint(x: 0.95, y: 0.18), CGSize(width: 1.3, height: 0.42), dark ? 0x0A84FF : 0x007AFF, dark ? 0.24 : 0.11),
            (CGPoint(x: 0.9, y: 0.5), CGSize(width: 1.2, height: 0.38), dark ? 0x7D7AFF : 0x5856D6, dark ? 0.16 : 0.08),
            (CGPoint(x: 0.95, y: 0.84), CGSize(width: 1.3, height: 0.42), dark ? 0xFF9F0A : 0xFF9500, dark ? 0.12 : 0.09),
        ]
        for (glow, (centre, size, color, alpha)) in zip(glows, spots) {
            let width = bounds.width * size.width, height = bounds.height * size.height
            glow.frame = CGRect(x: bounds.width * centre.x - width / 2, y: bounds.height * centre.y - height / 2, width: width, height: height)
            glow.colors = [Theme.hex(color, alpha: alpha).cgColor, Theme.hex(color, alpha: alpha * 0.45).cgColor, Theme.hex(color, alpha: 0).cgColor]
            glow.locations = [0, 0.45, 1]
        }
        CATransaction.commit()
    }
}

final class SidebarWash: NSView {
    private static let color = A2.dynamic(.clear, NSColor(white: 0.11, alpha: 0.72))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.color.cgColor
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
        if hovering, !selected {
            Theme.ink.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        IconTile.glyph(symbol, tint: Theme.blue, size: 16, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 10.5, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        (title as NSString).draw(at: NSPoint(x: 36, y: (bounds.height - 16) / 2),
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
