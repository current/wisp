import AppKit
import WispCore

// Pieces the dashboard draws in the soft dropdowns' style: its header chip, the apps
// tabs, the footer hint, a message inside a card, the core map as a card's graphic, and
// the line under the title that sums up the blocks shown. Everything here is laid out
// in the dropdowns' 400-point space and shown at their scale.

typealias SoftLook = SoftDropdown.Look

/// The chip on the section's heading naming this Mac's chip and memory, as a soft tag.
@MainActor
final class MachineChip: BitmapView {
    private static let font = SoftLook.strong
    private let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

    let text: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer).replacingOccurrences(of: "Apple ", with: "")
        // Installed memory; read once, so the header needs no memory sampling.
        let memory = Format.memory(ProcessInfo.processInfo.physicalMemory)
        let chip = name.isEmpty ? "This Mac" : name
        return memory.isEmpty ? chip : "\(chip) · \(memory)"
    }()

    var naturalWidth: CGFloat { ceil(SoftLook.width(text, Self.font)) + 9 + (symbol?.size.width ?? 0) + 6 + 10 }

    override func draw(_ dirtyRect: NSRect) {
        SoftLook.thin()
        SoftLook.tag.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var x: CGFloat = 9
        if let symbol {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                SoftLook.secondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: ((bounds.height - symbol.size.height) / 2).rounded(), width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += symbol.size.width + 6
        }
        SoftLook.text(text, x: x, mid: bounds.midY, width: bounds.width - x, font: Self.font, color: SoftLook.heading)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// Tabs on a card's first line, as soft tags: the chosen one is a white chip on a quiet
/// track, the others quiet text.
@MainActor
final class SoftTabs: BitmapView {
    let items: [String]
    private(set) var selected = 0
    var onChange: ((Int) -> Void)?
    private static let font = SoftLook.strong
    private static let pad: CGFloat = 11
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ items: [String]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Sort apps by")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var widths: [CGFloat] { items.map { ceil(SoftLook.width($0, Self.font)) + Self.pad * 2 } }
    var naturalWidth: CGFloat { widths.reduce(0, +) + 4 }

    func select(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selected else { return }
        selected = index
        if animated { crossfade() }
        needsDisplay = true
    }

    private func index(at x: CGFloat) -> Int? {
        var left: CGFloat = 2
        for (index, width) in widths.enumerated() {
            if x >= left, x < left + width { return index }
            left += width
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        SoftLook.thin()
        SoftLook.tag.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var left: CGFloat = 2
        for (index, (item, width)) in zip(items, widths).enumerated() {
            let rect = NSRect(x: left, y: 2, width: width, height: bounds.height - 4)
            if index == selected {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = SoftLook.cardShadow
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.set()
                SoftLook.card.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let color = index == selected ? SoftLook.primary : hovered == index ? SoftLook.heading : SoftLook.secondary
            SoftLook.text(item, x: rect.minX + Self.pad, mid: rect.midY, width: width - Self.pad * 2 + 1, font: Self.font, color: color)
            left += width
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil).x), index != selected else { return }
        select(index, animated: true)
        onChange?(index)
    }

    override func accessibilityPerformPress() -> Bool {
        let next = (selected + 1) % items.count
        select(next, animated: true)
        onChange?(next)
        return true
    }

    // Each tab is its own radio button, as Segmented's are, so VoiceOver can say which
    // one is chosen and pick any of them directly.
    private final class Tab: NSAccessibilityElement {
        weak var owner: SoftTabs?
        var index = 0
        // AppKit asks for these on the main thread.
        override func accessibilityPerformPress() -> Bool {
            MainActor.assumeIsolated {
                guard let owner else { return false }
                if index != owner.selected {
                    owner.select(index, animated: true)
                    owner.onChange?(index)
                }
                return true
            }
        }
        override func accessibilityValue() -> Any? { MainActor.assumeIsolated { owner?.selected == index ? 1 : 0 } }
        override func accessibilityFrameInParentSpace() -> NSRect {
            MainActor.assumeIsolated {
                guard let owner else { return .zero }
                let left = 2 + owner.widths.prefix(index).reduce(0, +)
                let width = index < owner.widths.count ? owner.widths[index] : 0
                return NSRect(x: left, y: 2, width: width, height: owner.bounds.height - 4)
            }
        }
    }

    private lazy var tabs: [Tab] = items.enumerated().map { index, item in
        let tab = Tab()
        tab.owner = self
        tab.index = index
        tab.setAccessibilityRole(.radioButton)
        tab.setAccessibilityLabel(item)
        tab.setAccessibilityParent(self)
        return tab
    }

    override func accessibilityValue() -> Any? { items.indices.contains(selected) ? items[selected] : nil }
    override func accessibilityChildren() -> [Any]? { tabs }
}

/// One line of quiet text, drawn as the soft dropdowns draw theirs.
@MainActor
final class SoftText: BitmapView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true; setAccessibilityValue(text) } } }
    var color: NSColor = SoftLook.secondary { didSet { needsDisplay = true } }
    var centered = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        SoftLook.thin()
        let width = min(bounds.width, ceil(SoftLook.width(text, SoftLook.body)) + 1)
        let fitted = PlanCard.fitted(text, room: bounds.width, font: SoftLook.body)
        SoftLook.text(fitted, x: centered ? ((bounds.width - width) / 2).rounded() : 0, mid: bounds.midY, width: bounds.width,
                      font: SoftLook.body, color: color)
    }

    override func isAccessibilityElement() -> Bool { !text.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}

/// What a card says when it has nothing to list yet: a line, and a button that does
/// something about it, under the card's title where the lines would go.
@MainActor
final class CardMessage: DrawnView {
    let label = SoftText()
    let button: ActionButton
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        button = ActionButton(title: "", target: nil, action: nil)
        super.init(frame: frame)
        button.target = self
        button.action = #selector(pressed)
        button.secondary = true
        button.font = SoftLook.strong
        label.centered = true
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, button title: String = "") {
        label.text = text
        button.title = title
        button.isHidden = title.isEmpty
        needsLayout = true
    }

    /// Its height under a card's title.
    var height: CGFloat { button.isHidden ? 34 : 74 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: 20)
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: 32, width: size.width, height: size.height)
    }

    @objc private func pressed() { onPress?() }
}

/// The core map along the bottom of the Cores card: every core over the last minute,
/// performance cores on top, with the heat key under it. The map keeps its own point
/// sizes so its small labels stay legible when the dashboard is shown smaller.
@MainActor
final class CoreMapGraphic: DrawnView {
    let heatmap = Heatmap()
    private let key = HeatKey()
    static let keyHeight: CGFloat = 14
    private let scale = SoftDropdown.scale

    override init(frame: NSRect) {
        super.init(frame: frame)
        heatmap.rowPitch = 11
        heatmap.labelWidth = 26
        heatmap.valueWidth = 30
        heatmap.columns = HistoryStore.recentCoreSamples
        addSubview(heatmap)
        addSubview(key)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The height the map needs for `rows` cores, in the card's space.
    func height(rows: Int) -> CGFloat {
        (CGFloat(max(rows, 1)) * heatmap.rowPitch - heatmap.cellGap + 10 + Self.keyHeight) / scale + 4 + SoftCard.padX
    }

    override func layout() {
        super.layout()
        let inset = SoftCard.padX
        let mapHeight = bounds.height - inset - 4 - (10 + Self.keyHeight) / scale
        let map = NSRect(x: inset, y: 4, width: bounds.width - inset * 2, height: max(1, mapHeight))
        heatmap.frame = map
        heatmap.bounds = NSRect(origin: .zero, size: NSSize(width: map.width * scale, height: map.height * scale))
        let keyRect = NSRect(x: bounds.width - inset - 130 / scale, y: map.maxY + 10 / scale, width: 130 / scale, height: Self.keyHeight / scale)
        key.frame = keyRect
        key.bounds = NSRect(origin: .zero, size: NSSize(width: 130, height: Self.keyHeight))
    }
}

/// A finding of the "Why is it slow?" check: its mark, a sentence that may take two
/// lines and its detail. The whole line is the button when the finding has an action.
@MainActor
final class FindingLine: BitmapView {
    static let height: CGFloat = 54
    enum Mark { case icon(NSImage), glyph(String, NSColor) }
    var onPress: (() -> Void)? { didSet { setAccessibilityRole(onPress == nil ? .staticText : .button) } }
    private var mark = Mark.glyph("circle", A2.secondary)
    private var title = ""
    private var detail = ""
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    func set(mark: Mark, title: String, detail: String) {
        self.mark = mark
        self.title = title
        self.detail = detail
        // The detail can end in an ellipsis; the whole of it shows on hover.
        toolTip = detail.isEmpty ? nil : detail
        setAccessibilityLabel(title)
        setAccessibilityValue(detail)
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        SoftLook.thin()
        if hovering, onPress != nil {
            SoftLook.tag.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        let left = SoftCard.padX
        let markRect = NSRect(x: left, y: 9, width: 20, height: 20)
        switch mark {
        case .icon(let image):
            image.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .glyph(let symbol, let tint):
            A2Dev.drawGlyphTile(symbol, tint: tint, in: markRect, appearance: effectiveAppearance)
        }
        let textLeft = left + 20 + 9
        let width = bounds.width - textLeft - SoftCard.padX
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: SoftLook.strong, .foregroundColor: SoftLook.primary, .paragraphStyle: paragraph]
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let measured = (title as NSString).boundingRect(with: NSSize(width: width, height: 40), options: options, attributes: attributes)
        let titleHeight = min(34, ceil(measured.height))
        let detailHeight: CGFloat = detail.isEmpty ? 0 : 17
        var y = ((bounds.height - titleHeight - detailHeight) / 2).rounded()
        (title as NSString).draw(with: NSRect(x: textLeft, y: y, width: width, height: titleHeight), options: options, attributes: attributes)
        y += titleHeight + 1
        if !detail.isEmpty {
            SoftLook.text(PlanCard.fitted(detail, room: width, font: SoftLook.body), x: textLeft, mid: y + 8, width: width,
                          font: SoftLook.body, color: SoftLook.secondary)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onPress != nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

/// A button over a card's tag, the same size so the card leaves room for it: a white
/// capsule with a hairline, as the header's round buttons are.
@MainActor
final class TagButton: DrawnView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true; setAccessibilityLabel(title) } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        SoftLook.thin()
        let shape = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = shape.height / 2
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = SoftLook.cardShadow
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (isEnabled && (hovering || pressed) ? SoftLook.buttonHover : SoftLook.card).setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        SoftLook.cardLine.setStroke()
        NSBezierPath(roundedRect: shape.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius).stroke(width: 0.5)
        SoftLook.text(title, x: 9, mid: bounds.midY, width: bounds.width - 9, font: SoftLook.strong,
                      color: isEnabled ? SoftLook.primary : SoftLook.secondary)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
    override var acceptsFirstResponder: Bool { KeyPress.reachable && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func keyDown(with event: NSEvent) {
        if KeyPress.presses(event) { onPress?() } else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { KeyPress.capsule(bounds) }
}

/// The panel behind the builder's live copy of the dashboard, which has no window of its
/// own to draw one. Its corners follow the builder's stage under it.
@MainActor
final class DashboardFace: BitmapView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.panelRadius
        SoftLook.panel.setFill()
        SoftLook.rounded(bounds, radius: radius).fill()
        SoftLook.panelRim.setStroke()
        SoftLook.rounded(bounds.insetBy(dx: 0.75, dy: 0.75), radius: radius - 0.75).stroke(width: 0.5)
    }
}

// MARK: - Status

/// The line under the dashboard's title: the headline of each block shown, in their
/// order, with a dot for the most pressing state among them.
@MainActor
enum DashboardStatus {
    static func make(_ layout: [DashboardBlock], _ s: SystemSnapshot?, table: ProcessTable?, agents: Int?, plans: [PlanUsage],
                     hidden: Set<String>) -> SoftDropdown.Head.Status {
        guard !layout.isEmpty else { return .init(dot: A2Dev.quiet, lines: ["No blocks yet"]) }
        var phrases: [String] = []
        var level = 0
        func add(_ phrase: String) { if !phrases.contains(phrase) { phrases.append(phrase) } }
        func raise(_ to: Int) { level = max(level, to) }
        let now = Date()
        for block in layout {
            switch block {
            case .cpu, .cores:
                guard let c = s?.cpu else { continue }
                add("CPU \(Format.percent(c.total))")
                raise(c.total >= 0.85 ? 2 : c.total >= 0.6 ? 1 : 0)
            case .memory, .meters:
                guard let m = s?.memory, m.total > 0 else { continue }
                add("Memory \(Format.percent(m.usedFraction))")
                raise(m.pressure == .critical ? 2 : m.pressure == .warning ? 1 : 0)
            case .gpu:
                guard let busy = s?.gpu?.utilization else { continue }
                add("GPU \(Format.percent(busy))")
            case .power:
                if let p = s?.power, let cpu = p.cpu { add(Format.watts(cpu + (p.gpu ?? 0) + (p.ane ?? 0))) }
                if let b = s?.battery, Strain.battery(b) { raise(1) }
            case .network:
                guard let n = s?.network else { continue }
                add("Down \(Format.rate(n.receivedBytesPerSecond))")
            case .disk:
                guard let d = s?.disk, d.volumeTotal > 0 else { continue }
                add("\(Format.bytes(d.volumeFree)) free")
                if Strain.disk(d) { raise(2) }
            case .sensors:
                guard let t = s?.thermal else { continue }
                if let cpu = t.cpuCelsius { add("Temperature \(Format.celsius(cpu))") }
                raise(t.pressure == .nominal ? 0 : t.pressure == .fair ? 1 : 2)
            case .usage:
                let shown = plans.filter { !hidden.contains($0.id) }
                guard let pick = PlanOutlook.closest(shown, now: now) else { continue }
                add("\(pick.usage.label ?? pick.usage.provider) \(Format.percent(pick.window.used))")
                let dot = PlanOutlook.dot(pick, now: now)
                raise(dot == A2.bad ? 2 : dot == A2Dev.idle ? 1 : 0)
            case .apps:
                guard let table, !table.apps.isEmpty else { continue }
                add("\(table.apps.count) apps open")
            case .agents:
                guard let agents else { continue }
                add(agents == 1 ? "1 agent running" : "\(agents) agents running")
            case .why:
                continue
            }
        }
        guard !phrases.isEmpty else {
            let reads = layout.contains { !$0.demand.isEmpty }
            return .init(dot: A2Dev.quiet, lines: [reads ? "Waiting for the first reading" : "Reads nothing until you ask"])
        }
        let dot = level == 2 ? A2.bad : level == 1 ? A2Dev.idle : A2Dev.live
        // Longest first; the head shows the first that fits.
        let lines = (1...phrases.count).reversed().map { phrases.prefix($0).joined(separator: " · ") }
        return .init(dot: dot, lines: lines)
    }
}
