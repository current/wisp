import AppKit
import WispCore

// Pieces the Projects, Containers and Login & Background pages share, on top of A2Developer:
//
//   ShareBar    a capsule split into coloured parts, one per thing, with hover
//   SplitKeys   the key under it: colour, label, bold value and a quiet note, in columns
//   SplitHero   a hero card: label, state pill, 34 pt figure, caption, then the bar and keys
//   ProjectGhostRows   grey placeholder rows in the shape of a table, while it is read
//   TableTips   the whole of each A2Table row's text on hover

enum DevParts {
    /// Colours for the parts of a split, near the page's tint first. Amber and red stay
    /// out: they mean a state on these pages. The last one is for "the rest".
    static func palette(_ page: PageID) -> [NSColor] {
        switch page {
        case .startup: return [A2Dev.tint(.startup), A2.cpu, A2.memoryApp, A2.cpuLight, A2.memoryCompressed]
        case .docker: return [Theme.dynamic(0x30B0C7, 0x40C8E0), A2.cpu, A2.memoryApp, A2.cpuLight, A2.memoryCompressed]
        default: return [A2.cpu, A2.memoryApp, A2.cpuLight, A2.memoryCompressed, Theme.teal]
        }
    }

    static let rest = A2.diskSystem
    /// Placeholder shapes while something is read.
    static let ghost = A2.dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.07))
}

/// A capsule split into coloured parts with 2 pt gaps. Hovering a part fades the others
/// and reports it, so the key and a tooltip can follow. With no parts it is a grey track.
final class ShareBar: BitmapView {
    struct Part: Equatable {
        var value: Double
        var color: NSColor
    }

    var parts: [Part] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onHover: ((Int?, NSRect) -> Void)?
    private let gap: CGFloat = 2

    /// Every part gets at least a sliver so small ones can still be hovered.
    func frames() -> [NSRect] {
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        guard total > 0 else { return parts.map { _ in .zero } }
        let shown = parts.filter { $0.value > 0 }.count
        let room = bounds.width - gap * CGFloat(max(0, shown - 1)) - 4 * CGFloat(shown)
        var x: CGFloat = 0
        return parts.map { part in
            guard part.value > 0 else { return .zero }
            let width = 4 + room * CGFloat(part.value / total)
            defer { x += width + gap }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(5, bounds.height / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        let frames = frames()
        if frames.allSatisfy({ $0.isEmpty }) {
            A2.track.setFill()
            bounds.fill()
        }
        for (index, (part, rect)) in zip(parts, frames).enumerated() where !rect.isEmpty {
            let faded = highlighted != nil && highlighted != index
            (faded ? part.color.withAlphaComponent(0.3) : part.color).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frames = frames()
        let hit = frames.firstIndex { !$0.isEmpty && $0.insetBy(dx: -gap / 2, dy: -6).contains(point) }
        highlighted = hit
        onHover?(hit, hit.map { frames[$0] } ?? .zero)
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        onHover?(nil, .zero)
    }

    /// What the bar splits ("Memory") and each part in words, in order, for VoiceOver;
    /// the colours and the hover tooltip are the only other place they show.
    var title = ""
    var spoken: [String] = []

    override func isAccessibilityElement() -> Bool { !parts.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { title.isEmpty ? "Split" : title + " split" }
    override func accessibilityValue() -> Any? {
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        return parts.indices.map { index in
            let share = total > 0 ? Format.percent(max(0, parts[index].value) / total) : ""
            let name = index < spoken.count ? spoken[index] : "Part \(index + 1)"
            return [name, share].filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "; ")
    }
}

/// The key under a split: a colour square and a label, then the value in bold and a
/// quieter note after it, in equal columns that wrap. `ghost` draws that many grey
/// placeholders in the same places, for while the numbers are read.
final class SplitKeys: BitmapView {
    struct Key: Equatable {
        var label: String
        var value: String
        var note: String
        var color: NSColor
    }

    var keys: [Key] = [] { didSet { if keys != oldValue { needsDisplay = true } } }
    var ghost = 0 { didSet { if ghost != oldValue { needsDisplay = true } } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var maxColumns = 4
    var onHover: ((Int?) -> Void)?
    static let keyHeight: CGFloat = 34
    static let rowGap: CGFloat = 10

    private static let labelFont = Theme.sans(11)
    private static let valueFont = Theme.digits(12.5, .semibold)
    private static let noteFont = Theme.sans(11)

    private var count: Int { keys.isEmpty ? ghost : keys.count }

    /// Up to four columns, fewer when a column would be narrower than 170 pt, and evened
    /// out so six keys sit in two rows of three rather than four and two.
    func columns(_ width: CGFloat) -> Int {
        let fit = max(1, min(maxColumns, Int((width + 12) / (170 + 12))))
        guard count > fit else { return fit }
        let rows = (count + fit - 1) / fit
        return (count + rows - 1) / rows
    }

    func naturalHeight(width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns(width) - 1) / columns(width)
        return CGFloat(rows) * Self.keyHeight + CGFloat(rows - 1) * Self.rowGap
    }

    private func frame(_ index: Int) -> NSRect {
        let columns = columns(bounds.width)
        let width = (bounds.width - 12 * CGFloat(columns - 1)) / CGFloat(columns)
        return NSRect(x: CGFloat(index % columns) * (width + 12), y: CGFloat(index / columns) * (Self.keyHeight + Self.rowGap),
                      width: width, height: Self.keyHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        if keys.isEmpty {
            for index in 0..<ghost {
                let rect = frame(index)
                DevParts.ghost.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY + 4, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 13, y: rect.minY + 3, width: [64, 48, 72, 56][index % 4], height: 9),
                             xRadius: 4.5, yRadius: 4.5).fill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 13, y: rect.minY + 19, width: [44, 58, 38, 50][index % 4], height: 11),
                             xRadius: 5.5, yRadius: 5.5).fill()
            }
            return
        }
        for (index, key) in keys.enumerated() {
            let rect = frame(index)
            let faded = highlighted != nil && highlighted != index
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            if faded { context?.setAlpha(0.4) }
            key.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY + 4, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
            A2Dev.text(key.label, x: rect.minX + 13, mid: rect.minY + 7.5, width: rect.width - 13, font: Self.labelFont, color: A2.secondary)
            let used = A2Dev.measuredText(key.value, x: rect.minX + 13, mid: rect.minY + 25, width: rect.width - 13, font: Self.valueFont,
                                          color: A2.primary)
            A2Dev.text(key.note, x: rect.minX + 13 + used + 6, mid: rect.minY + 25.5, width: rect.width - 19 - used, font: Self.noteFont,
                       color: A2.tertiary)
            context?.restoreGState()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = keys.indices.first { frame($0).contains(point) }
        if hit != highlighted {
            highlighted = hit
            onHover?(hit)
        }
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
        onHover?(nil)
    }

    override func isAccessibilityElement() -> Bool { !keys.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { keys.map { "\($0.label) \($0.value) \($0.note)" }.joined(separator: "; ") }
}

/// A hero card in the Storage card's shape: label and state pill, a 34 pt figure, a
/// caption, then a split bar and its key. Before the first reading the bar and key are
/// grey placeholders; with nothing to split, `hint` says what would show here.
final class SplitHero: CardView {
    struct Slice: Equatable {
        var label: String
        var value: Double
        var shown: String
        var note: String
        var detail: String
    }

    let label: A2CardLabel
    let pill = Pill()
    let legend = A2TitleRow()
    let figure = A2.figure()
    let caption = TextLine()
    let bar = ShareBar()
    let keys = SplitKeys()
    let hint = TextLine()
    private let tooltip = Tooltip()
    private let colors: [NSColor]
    private let labelWidth: CGFloat
    private(set) var slices: [Slice] = []
    /// What the bar measures, for the tooltip ("Memory").
    var measure = ""

    static let barTop: CGFloat = 106
    static let keysTop: CGFloat = 132

    init(_ name: String, symbol: String, page: PageID) {
        label = A2CardLabel(name, symbol: symbol, tint: A2Dev.tint(page))
        label.showsChevron = false
        labelWidth = 20 + A2Dev.width(name, A2.labelFont)
        colors = DevParts.palette(page)
        super.init()
        pill.isHidden = true
        hint.isHidden = true
        keys.ghost = 4
        for view in [legend, label, pill, figure, caption, bar, keys, hint] as [NSView] { addSubview(view) }
        bar.onHover = { [weak self] index, rect in self?.hover(index, rect) }
        keys.onHover = { [weak self] index in
            guard let self else { return }
            self.bar.highlighted = index
            if let index, self.bar.frames().indices.contains(index) {
                self.hover(index, self.bar.frames()[index])
            } else {
                self.tooltip.hide()
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    func color(_ index: Int, of count: Int) -> NSColor {
        index < colors.count ? colors[index] : DevParts.rest
    }

    /// The parts, largest first; past `limit` they fold into one grey "the rest".
    func show(_ all: [Slice], limit: Int = 5, rest: (Double, [Slice]) -> Slice) {
        var shown = Array(all.prefix(limit))
        if all.count > limit {
            let folded = Array(all.dropFirst(limit))
            shown.append(rest(folded.reduce(0) { $0 + $1.value }, folded))
        }
        slices = shown
        bar.parts = shown.enumerated().map { .init(value: $0.element.value, color: color($0.offset, of: shown.count)) }
        keys.keys = shown.enumerated().map { .init(label: $0.element.label, value: $0.element.shown, note: $0.element.note,
                                                   color: color($0.offset, of: shown.count)) }
        bar.title = measure
        bar.spoken = shown.map { [$0.label + " " + $0.shown, $0.detail].filter { !$0.isEmpty }.joined(separator: ", ") }
        hint.isHidden = !shown.isEmpty
        keys.isHidden = shown.isEmpty
        needsLayout = true
    }

    /// Back to grey placeholders, while the first reading is taken.
    func showGhost(_ text: String) {
        slices = []
        bar.parts = []
        keys.keys = []
        keys.ghost = 4
        keys.isHidden = false
        hint.isHidden = true
        caption.text = A2.plain(text)
        figure.show("–")
        pill.isHidden = true
    }

    func showEmpty(_ text: String) {
        slices = []
        bar.parts = []
        keys.keys = []
        keys.isHidden = true
        hint.isHidden = false
        hint.text = NSAttributedString(string: text, attributes: [.font: A2.subFont, .foregroundColor: A2.tertiary])
        needsLayout = true
    }

    func setPill(_ text: String?, tone: Pill.Tone = .good) {
        pill.isHidden = text == nil
        pill.text = text ?? ""
        pill.tone = tone
        needsLayout = true
    }

    func height(width: CGFloat) -> CGFloat {
        let inner = width - A2.padSide * 2
        let below = keys.isHidden ? 16 : keys.naturalHeight(width: inner)
        return Self.keysTop + below + 16
    }

    private func hover(_ index: Int?, _ rect: NSRect) {
        guard let index, slices.indices.contains(index) else {
            keys.highlighted = nil
            return tooltip.hide()
        }
        keys.highlighted = index
        let total = slices.reduce(0) { $0 + $1.value }
        let slice = slices[index]
        tooltip.title = slice.label
        tooltip.detail = total > 0 ? Format.percent(slice.value / total) : ""
        tooltip.lines = [Tooltip.Line(color: color(index, of: slices.count), name: measure, value: slice.shown)]
        if !slice.detail.isEmpty { tooltip.lines.append(Tooltip.Line(color: nil, name: slice.detail, value: "")) }
        tooltip.show(in: self, above: bar.convert(rect, to: self))
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        label.frame = NSRect(x: A2.padSide, y: A2.padTop, width: labelWidth + 4, height: 15)
        pill.frame = NSRect(x: A2.padSide + labelWidth + 10, y: 12.5, width: pill.naturalWidth, height: 18)
        legend.frame = NSRect(x: A2.padSide, y: A2.padTop - 0.5, width: inner, height: 16)
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        caption.frame = NSRect(x: A2.padSide, y: A2StatCard.subTop, width: inner, height: 14)
        bar.frame = NSRect(x: A2.padSide, y: Self.barTop, width: inner, height: 12)
        keys.frame = NSRect(x: A2.padSide, y: Self.keysTop, width: inner, height: keys.naturalHeight(width: inner))
        hint.frame = NSRect(x: A2.padSide, y: Self.keysTop - 2, width: inner, height: 16)
    }
}

/// Grey rows in a table's shape: an icon square, a name, and a few short bars on the
/// right where the figures will be. Shown while a table's rows are read.
final class ProjectGhostRows: BitmapView {
    var count = 6 { didSet { needsDisplay = true } }
    var rowHeight: CGFloat = 40 { didSet { needsDisplay = true } }
    var iconSize: CGFloat = 26
    /// Bars on the right, as (width, distance of its right edge from the right edge).
    var columns: [(CGFloat, CGFloat)] = [(64, 0), (54, 96), (70, 190), (90, 320)]

    private static let names: [CGFloat] = [170, 132, 210, 150, 118, 190, 140, 176]

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<count {
            let top = CGFloat(index) * rowHeight
            let mid = top + rowHeight / 2
            if index > 0 {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            // Fainter further down, so the placeholder reads as a list still arriving.
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            defer { context?.restoreGState() }
            context?.setAlpha(1 - CGFloat(index) / CGFloat(max(count, 1)) * 0.6)
            DevParts.ghost.setFill()
            let icon = NSRect(x: 0, y: (mid - iconSize / 2).rounded(), width: iconSize, height: iconSize)
            NSBezierPath(roundedRect: icon, xRadius: (iconSize * 0.27).rounded(), yRadius: (iconSize * 0.27).rounded()).fill()
            let name = Self.names[index % Self.names.count]
            NSBezierPath(roundedRect: NSRect(x: iconSize + 11, y: mid - 5, width: name, height: 10), xRadius: 5, yRadius: 5).fill()
            for (width, right) in columns where bounds.width - right - width > iconSize + 11 + name + 20 {
                NSBezierPath(roundedRect: NSRect(x: bounds.width - right - width, y: mid - 4.5, width: width, height: 9),
                             xRadius: 4.5, yRadius: 4.5).fill()
            }
        }
    }
}

/// The whole text of each row of an A2Table on hover, for names and statuses its
/// columns cut short. The rows' places follow the table's own rule: at least
/// `rowHeight` tall, sharing any extra height evenly.
final class TableTips: NSObject, NSViewToolTipOwner {
    private var texts: [NSView.ToolTipTag: String] = [:]
    private var installed: (NSRect, [String])?

    @MainActor
    func install(on table: A2Table, texts list: [String]) {
        if let installed, installed.0 == table.bounds, installed.1 == list { return }
        installed = (table.bounds, list)
        table.removeAllToolTips()
        texts.removeAll()
        guard !list.isEmpty else { return }
        let height = max(table.rowHeight, (table.bounds.height - table.headerHeight) / CGFloat(list.count)).rounded(.down)
        for (index, text) in list.enumerated() where !text.isEmpty {
            let rect = NSRect(x: 0, y: table.headerHeight + CGFloat(index) * height, width: table.bounds.width, height: height)
            texts[table.addToolTip(rect, owner: self, userData: nil)] = text
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        texts[tag] ?? ""
    }
}
