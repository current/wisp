import AppKit
import WispCore

// The A2 card style from the approved Overview mockup, for every page to build on.
// A card is a `CardView` (radius 18, hairline, no shadow) with 14 pt of padding at
// the top and 16 at the sides. Inside it:
//
//   A2CardLabel      icon, name in the page's colour, chevron when the card opens a page
//   A2.figure()      a BigNumber set to 34 pt semibold with a 15 pt unit; place it with A2.figureFrame
//   A2.facts(_:)     the sub line under a figure: quiet labels with bold values
//   A2Spark          line and soft fill, edge to edge on the card's bottom edge
//   A2ActivityChart  two series with one dotted grid and a single scale label
//   A2TitleRow       a plain card title with a legend on the right
//   A2CapacityBar    a capsule split into parts with 2 pt gaps
//   A2Keys           colour square, label and bold value, in columns
//   A2AppList        the busiest apps: icon, name, meter, CPU and memory
//   A2TipRow         a tinted round symbol, a title and detail, and an A2PillButton
//
// Charts and lists draw into their own bitmap (BitmapView) and redraw only when their
// values change. Nothing here clips with a layer or casts a shadow.

/// Colours, type and spacing for A2 cards. Every colour has a dark value.
enum A2 {
    static let padTop: CGFloat = 14
    static let padSide: CGFloat = 16
    static let radius: CGFloat = 18

    static let primary = Theme.dynamic(0x1D1D1F, 0xF5F5F7)
    static let secondary = dynamic(Theme.hex(0x3C3C43, alpha: 0.62), Theme.hex(0xEBEBF5, alpha: 0.6))
    static let tertiary = dynamic(Theme.hex(0x3C3C43, alpha: 0.36), Theme.hex(0xEBEBF5, alpha: 0.36))
    static let chevron = dynamic(Theme.hex(0x3C3C43, alpha: 0.3), Theme.hex(0xEBEBF5, alpha: 0.3))
    /// Rules between rows of a list.
    static let hairline = dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.06))
    /// The free part of a capacity bar.
    static let track = dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.12))
    static let meterTrack = dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.08))
    static let grid = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.07))
    static let gridLabel = dynamic(Theme.hex(0x3C3C43, alpha: 0.5), Theme.hex(0xEBEBF5, alpha: 0.42))
    static let rowHover = dynamic(NSColor(white: 0, alpha: 0.035), NSColor(white: 1, alpha: 0.04))
    static let pill = dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.1))
    static let pillPressed = dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.16))
    static let pillText = dynamic(Theme.hex(0x007AFF), Theme.hex(0xF5F5F7))
    static let good = Theme.dynamic(0x248A3D, 0x30D158)
    static let warn = Theme.dynamic(0xC93400, 0xFF9F0A)
    static let bad = Theme.dynamic(0xD70015, 0xFF453A)

    /// Chart and bar colours.
    static let cpu = Theme.dynamic(0x007AFF, 0x0A84FF)
    static let cpuLight = Theme.dynamic(0x5AC8FA, 0x64D2FF)
    static let gpu = Theme.dynamic(0xFF2D55, 0xFF375F)
    static let power = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let down = Theme.dynamic(0x34C759, 0x30D158)
    static let up = Theme.dynamic(0x32ADE6, 0x64D2FF)
    static let memoryApp = Theme.dynamic(0x5856D6, 0x7D7AFF)
    static let memoryWired = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let memoryCompressed = Theme.dynamic(0xA9A7F0, 0x4D4AB8)
    static let diskApps = Theme.dynamic(0x007AFF, 0x0A84FF)
    static let diskDeveloper = Theme.dynamic(0x5856D6, 0x7D7AFF)
    static let diskDocuments = Theme.dynamic(0xFF9500, 0xFF9F0A)
    static let diskSystem = Theme.dynamic(0xAEAEB2, 0x8E8E93)

    /// A page's colour for text and icons in a card label: a shade darker than its
    /// chart colour in light mode so 12 pt text keeps its contrast, lighter in dark.
    static func labelTint(_ page: PageID) -> NSColor {
        switch page {
        case .cpu: return Theme.dynamic(0x007AFF, 0x3D9BFF)
        case .memory: return Theme.dynamic(0x5856D6, 0x9D9BFF)
        case .gpu: return Theme.dynamic(0xE0284F, 0xFF5C7A)
        case .energy: return Theme.dynamic(0xD97A00, 0xFFB340)
        case .disk: return Theme.dynamic(0x0A8FC7, 0x64D2FF)
        case .network: return Theme.dynamic(0x248A3D, 0x30D158)
        default: return page.tint
        }
    }

    static let labelFont = Theme.sans(12, .semibold)
    static let titleFont = Theme.sans(13, .semibold)
    static let legendFont = Theme.sans(11, .medium)
    static let subFont = Theme.sans(11.5)
    static let subBold = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    static let figureFont = Theme.figure(34, .semibold)
    static let unitFont = Theme.sans(15, .medium)

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// True while drawing for a dark appearance.
    static var drawingDark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// A 34 pt figure with a quieter 15 pt unit, as on the top cards.
    @MainActor
    static func figure() -> BigNumber {
        let figure = BigNumber()
        figure.font = figureFont
        figure.unitFont = unitFont
        figure.color = primary
        figure.unitColor = secondary
        figure.kern = -1.36
        figure.unitGap = 3
        return figure
    }

    /// The frame that puts a figure's baseline at `baseline`, 70 pt below the card's top in the mockup.
    static func figureFrame(x: CGFloat, baseline: CGFloat, width: CGFloat) -> NSRect {
        let height: CGFloat = 42
        let y = baseline - (height + figureFont.ascender + figureFont.descender) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// One fact in a sub line: "User 11%", with the value bold in the primary colour.
    struct Fact {
        var label: String
        var value: String
        var color: NSColor? = nil
    }

    /// "User 11% · System 2% · Load 2.2" with each value bold.
    static func facts(_ facts: [Fact]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, fact) in facts.enumerated() {
            if index > 0 { text.append(plain(" · ")) }
            if !fact.label.isEmpty { text.append(plain(fact.label + " ")) }
            text.append(NSAttributedString(string: fact.value, attributes: [.font: subBold, .foregroundColor: fact.color ?? primary]))
        }
        return text
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: subFont, .foregroundColor: secondary])
    }

    /// A rectangle with its two bottom corners rounded, for charts that sit on a card's
    /// bottom edge. The radius is a little larger than the card's so the fill stays
    /// inside the card's continuous corner without a layer mask.
    static func bottomRounded(_ rect: CGRect, radius: CGFloat = A2.radius + 3) -> CGPath {
        let r = min(radius, rect.height, rect.width / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// Fills `path` with `color` fading from `alpha` at `from` to clear at `to` (y values).
    static func fade(_ path: CGPath, color: NSColor, alpha: CGFloat, from: CGFloat, to: CGFloat, in context: CGContext) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let colors = [resolved.withAlphaComponent(alpha).cgColor, resolved.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
        context.restoreGState()
    }

    /// Series compare equal when every sample matches, NaN gaps included.
    static func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }

    /// The polyline of one run of samples, split at NaN gaps.
    static func runs(_ values: [Float], x: (Int) -> CGFloat, y: (Float) -> CGFloat) -> [[CGPoint]] {
        var runs: [[CGPoint]] = [], current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            if value.isNaN {
                if current.count > 1 { runs.append(current) }
                current = []
            } else {
                current.append(CGPoint(x: x(index), y: y(value)))
            }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }
}

/// A card's label: a 14 pt icon and the name in the page's colour, and a chevron on
/// the right when the card opens a page. 15 pt tall.
final class A2CardLabel: DrawnView {
    let name: String
    let symbol: String
    let tint: NSColor
    var showsChevron = true { didSet { needsDisplay = true } }

    init(_ name: String, symbol: String, tint: NSColor) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.height / 2
        IconTile.glyph(symbol, tint: tint, size: 14, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 0, y: mid - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let font = A2.labelFont
        (name as NSString).draw(at: NSPoint(x: 20, y: mid - (font.ascender - font.descender) / 2),
                                withAttributes: [.font: font, .foregroundColor: tint])
        if showsChevron {
            // The mockup's chevron: a 1.5 pt stroke on a 16 pt grid, drawn at 12 pt.
            let x = bounds.width - 12, scale: CGFloat = 12 / 16
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: x + 6 * scale, y: mid - 4.5 * scale))
            chevron.line(to: NSPoint(x: x + 10.5 * scale, y: mid))
            chevron.line(to: NSPoint(x: x + 6 * scale, y: mid + 4.5 * scale))
            chevron.lineWidth = 1.5 * scale
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            A2.chevron.setStroke()
            chevron.stroke()
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { name }
}

/// A card title in the primary colour with a legend on the right: an optional dot and
/// a short text per item, 12 pt apart. 16 pt tall.
final class A2TitleRow: DrawnView {
    struct Item: Equatable {
        var text: String
        var dot: NSColor? = nil
        var faint = false
    }

    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.height / 2
        let font = A2.titleFont
        (title as NSString).draw(at: NSPoint(x: 0, y: mid - (font.ascender - font.descender) / 2),
                                 withAttributes: [.font: font, .foregroundColor: A2.primary])
        let legend = A2.legendFont
        var x = bounds.width
        for item in items.reversed() {
            let attributes: [NSAttributedString.Key: Any] = [.font: legend, .foregroundColor: item.faint ? A2.tertiary : A2.secondary]
            let width = ceil((item.text as NSString).size(withAttributes: attributes).width)
            x -= width
            (item.text as NSString).draw(at: NSPoint(x: x, y: mid - (legend.ascender - legend.descender) / 2), withAttributes: attributes)
            if let dot = item.dot {
                x -= 13
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: mid - 4, width: 8, height: 8)).fill()
            }
            x -= 12
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { ([title] + items.map(\.text)).joined(separator: ", ") }
}

/// Recent samples as a line with a soft fill under it, edge to edge and with no axis.
/// It sits on the card's bottom edge and rounds its own bottom corners to match the
/// card. `mirrored` hangs the line from the top edge instead (network upload).
final class A2Spark: BitmapView {
    var values: [Float] = [] { didSet { if !A2.same(values, oldValue) { needsDisplay = true } } }
    var ceiling: Float = 1 { didSet { if ceiling != oldValue { needsDisplay = true } } }
    var color: NSColor = A2.cpu { didSet { needsDisplay = true } }
    var mirrored = false { didSet { needsDisplay = true } }
    var roundsBottom = true
    var lineWidth: CGFloat = 1.6

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1, bounds.height > 4, let context = NSGraphicsContext.current?.cgContext else { return }
        // The mockup's 56 pt chart keeps 6 pt above the highest line and 2 pt under the lowest.
        let far = bounds.height * 6 / 56, near = bounds.height * 2 / 56
        let span = bounds.height - far - near
        let dx = bounds.width / CGFloat(values.count - 1)
        let top = max(ceiling, .leastNonzeroMagnitude)
        let y: (Float) -> CGFloat = { [mirrored, bounds] value in
            let fraction = CGFloat(min(1, max(0, value / top)))
            return mirrored ? near + fraction * span : bounds.height - near - fraction * span
        }
        let runs = A2.runs(values, x: { CGFloat($0) * dx }, y: y)
        guard !runs.isEmpty else { return }
        context.saveGState()
        if roundsBottom {
            context.addPath(A2.bottomRounded(bounds))
            context.clip()
        }
        let base: CGFloat = mirrored ? 0 : bounds.height
        let alpha: CGFloat = A2.drawingDark ? 0.38 : 0.24
        for run in runs {
            let area = CGMutablePath()
            area.move(to: CGPoint(x: run[0].x, y: base))
            area.addLines(between: run)
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: base))
            area.closeSubpath()
            let peak = mirrored ? run.map(\.y).max() ?? base : run.map(\.y).min() ?? base
            A2.fade(area, color: color, alpha: alpha, from: peak, to: base, in: context)
        }
        context.setStrokeColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        for run in runs {
            context.addLines(between: run)
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// Two series as lines with a light fill, a dotted line at half and at the top of the
/// scale, and one label for the top ("30%"). It sits on the card's bottom edge.
final class A2ActivityChart: BitmapView {
    var first: [Float] = [] { didSet { if !A2.same(first, oldValue) { needsDisplay = true } } }
    var second: [Float] = [] { didSet { if !A2.same(second, oldValue) { needsDisplay = true } } }
    var firstColor = A2.cpu
    var secondColor = A2.gpu
    var ceiling: Float = 1 { didSet { if ceiling != oldValue { needsDisplay = true } } }
    var format: (Float) -> String = { String(format: "%.0f%%", $0 * 100) }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 30, let context = NSGraphicsContext.current?.cgContext else { return }
        let top = max(ceiling, .leastNonzeroMagnitude)
        // The mockup's 176 pt chart: the top of the scale 25 pt down, zero 1 pt above the edge.
        let high: CGFloat = 25, low = bounds.height - 1
        let y: (Float) -> CGFloat = { value in low - CGFloat(min(1, max(0, value / top))) * (low - high) }
        context.saveGState()
        context.addPath(A2.bottomRounded(bounds))
        context.clip()
        context.setStrokeColor((A2.grid.usingColorSpace(.sRGB) ?? A2.grid).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [2, 4])
        for value in [top / 2, top] {
            let lineY = floor(y(value)) + 0.5
            context.move(to: CGPoint(x: 0, y: lineY))
            context.addLine(to: CGPoint(x: bounds.width, y: lineY))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        let alpha: CGFloat = A2.drawingDark ? 0.32 : 0.2
        for (values, color) in [(first, firstColor), (second, secondColor)] where values.count > 1 {
            let dx = bounds.width / CGFloat(values.count - 1)
            let runs = A2.runs(values, x: { CGFloat($0) * dx }, y: y)
            for run in runs {
                let area = CGMutablePath()
                area.move(to: CGPoint(x: run[0].x, y: bounds.height))
                area.addLines(between: run)
                area.addLine(to: CGPoint(x: run[run.count - 1].x, y: bounds.height))
                area.closeSubpath()
                A2.fade(area, color: color, alpha: alpha, from: run.map(\.y).min() ?? low, to: bounds.height, in: context)
            }
            context.setStrokeColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
            context.setLineWidth(1.8)
            context.setLineJoin(.round)
            for run in runs {
                context.addLines(between: run)
                context.strokePath()
            }
        }
        context.restoreGState()
        let label = format(top) as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: A2.gridLabel]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.width - 14 - size.width, y: y(top) - 4 - font.ascender), withAttributes: attributes)
    }
}

/// A capsule split into coloured parts with 2 pt gaps between them, 8 pt tall.
/// The last part is usually the free space in `A2.track`.
final class A2CapacityBar: BitmapView {
    struct Part: Equatable {
        var amount: Double
        var color: NSColor
    }

    var parts: [Part] = [] { didSet { if parts != oldValue { needsDisplay = true } } }
    let gap: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let shown = parts.filter { $0.amount > 0 }
        let total = shown.reduce(0) { $0 + $1.amount }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        guard total > 0 else {
            A2.track.setFill()
            bounds.fill()
            return NSGraphicsContext.restoreGraphicsState()
        }
        let room = bounds.width - gap * CGFloat(shown.count - 1)
        var x: CGFloat = 0
        for part in shown {
            let width = max(1, room * CGFloat(part.amount / total))
            part.color.setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The key under a capacity bar: a 7 pt colour square and a label, the value in bold
/// under it. In equal columns, or spread across the width with the first on the left
/// and the last on the right.
final class A2Keys: BitmapView {
    struct Key: Equatable {
        var label: String
        var value: String
        var color: NSColor?
    }

    enum Arrangement: Equatable { case spread, columns(Int) }

    var keys: [Key] = [] {
        didSet {
            guard keys != oldValue else { return }
            needsDisplay = true
            // A new number of keys changes the height the card holds for them.
            if keys.count != oldValue.count { superview?.needsLayout = true }
        }
    }
    var arrangement = Arrangement.columns(2) { didSet { needsDisplay = true } }
    var rowGap: CGFloat = 6

    private static let labelFont = Theme.sans(10.5)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    private static let labelLine = ceil((labelFont.ascender - labelFont.descender) * 2) / 2
    private static let valueLine = ceil((valueFont.ascender - valueFont.descender) * 2) / 2
    static let keyHeight = labelLine + 3 + valueLine

    var rows: Int {
        switch arrangement {
        case .spread: return keys.isEmpty ? 0 : 1
        case .columns(let count): return (keys.count + count - 1) / max(1, count)
        }
    }

    var naturalHeight: CGFloat { rows == 0 ? 0 : CGFloat(rows) * Self.keyHeight + CGFloat(rows - 1) * rowGap }

    private func width(_ key: Key) -> CGFloat {
        let indent: CGFloat = key.color == nil ? 0 : 13
        let label = (key.label as NSString).size(withAttributes: [.font: Self.labelFont]).width
        let value = (key.value as NSString).size(withAttributes: [.font: Self.valueFont]).width
        return ceil(max(label, value)) + indent
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !keys.isEmpty else { return }
        var origins: [NSPoint] = []
        switch arrangement {
        case .spread:
            let widths = keys.map(width)
            let space = keys.count > 1 ? (bounds.width - widths.reduce(0, +)) / CGFloat(keys.count - 1) : 0
            var x: CGFloat = 0
            for width in widths {
                origins.append(NSPoint(x: x, y: 0))
                x += width + space
            }
        case .columns(let count):
            let column = (bounds.width - 8 * CGFloat(count - 1)) / CGFloat(count)
            for index in keys.indices {
                origins.append(NSPoint(x: CGFloat(index % count) * (column + 8), y: CGFloat(index / count) * (Self.keyHeight + rowGap)))
            }
        }
        for (key, origin) in zip(keys, origins) {
            var x = origin.x
            if let color = key.color {
                color.setFill()
                let baseline = origin.y + Self.labelFont.ascender
                NSBezierPath(roundedRect: NSRect(x: x, y: baseline - 7, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
                x += 13
            }
            (key.label as NSString).draw(at: NSPoint(x: x, y: origin.y), withAttributes: [.font: Self.labelFont, .foregroundColor: A2.secondary])
            (key.value as NSString).draw(at: NSPoint(x: x, y: origin.y + Self.labelLine + 3),
                                         withAttributes: [.font: Self.valueFont, .foregroundColor: A2.primary])
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { keys.map { "\($0.label) \($0.value)" }.joined(separator: ", ") }
}

/// The busiest apps with a title row and "CPU" and "Memory" column titles. Each row:
/// a 22 pt icon, the name and a quiet process count, a 96 pt meter, then CPU and
/// memory right-aligned. The rows share the height evenly.
final class A2AppList: BitmapView {
    struct Row: Equatable {
        var id: String
        var icon: NSImage?
        var name: String
        var detail: String
        var fraction: Double
        var cpu: String
        var memory: String
    }

    var title = "Busiest apps" { didSet { needsDisplay = true } }
    var rows: [Row] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    /// Rows the height is shared between, so a short list keeps its row height.
    var slots = 5
    var onSelect: ((String) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    static let headerHeight: CGFloat = 16
    private static let headerGap: CGFloat = 6
    private static let meterWidth: CGFloat = 96
    private static let cpuWidth: CGFloat = 54
    private static let memoryWidth: CGFloat = 62
    private static let spacing: CGFloat = 11
    private static let nameFont = Theme.sans(13, .medium)
    private static let detailFont = Theme.sans(11)
    private static let cpuFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    private static let memoryFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)

    private var rowHeight: CGFloat { (bounds.height - Self.headerHeight - Self.headerGap) / CGFloat(max(1, max(slots, rows.count))) }
    private func rowTop(_ index: Int) -> CGFloat { Self.headerHeight + Self.headerGap + CGFloat(index) * rowHeight }

    override func draw(_ dirtyRect: NSRect) {
        let memoryRight = bounds.width
        let cpuRight = memoryRight - Self.memoryWidth - Self.spacing
        let meterX = cpuRight - Self.cpuWidth - Self.spacing - Self.meterWidth
        let nameX: CGFloat = 22 + Self.spacing
        let nameRight = meterX - Self.spacing

        let titleFont = A2.titleFont, legend = A2.legendFont
        let mid = Self.headerHeight / 2
        (title as NSString).draw(at: NSPoint(x: 0, y: mid - (titleFont.ascender - titleFont.descender) / 2),
                                 withAttributes: [.font: titleFont, .foregroundColor: A2.primary])
        for (text, right) in [("CPU", cpuRight), ("Memory", memoryRight)] {
            let attributes: [NSAttributedString.Key: Any] = [.font: legend, .foregroundColor: A2.secondary]
            let width = (text as NSString).size(withAttributes: attributes).width
            (text as NSString).draw(at: NSPoint(x: right - width, y: mid - (legend.ascender - legend.descender) / 2), withAttributes: attributes)
        }

        let height = rowHeight
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        for (index, row) in rows.enumerated() {
            let top = rowTop(index)
            let center = top + height / 2
            if index == hovered {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: -6, y: top + 2, width: bounds.width + 12, height: height - 4), xRadius: 8, yRadius: 8).fill()
            } else if index > 0, index - 1 != hovered {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            row.icon?.draw(in: NSRect(x: 0, y: center - 11, width: 22, height: 22), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)

            let nameAttributes: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: A2.primary, .paragraphStyle: truncating]
            let nameWidth = ceil((row.name as NSString).size(withAttributes: nameAttributes).width)
            let room = max(0, nameRight - nameX)
            let nameY = center - (Self.nameFont.ascender - Self.nameFont.descender) / 2
            (row.name as NSString).draw(with: NSRect(x: nameX, y: nameY, width: room, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: nameAttributes)
            let detailX = nameX + nameWidth + 6
            if detailX + 24 < nameRight {
                // Same baseline as the name.
                let detailY = nameY + Self.nameFont.ascender - Self.detailFont.ascender
                (row.detail as NSString).draw(with: NSRect(x: detailX, y: detailY, width: nameRight - detailX, height: 16),
                                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                              attributes: [.font: Self.detailFont, .foregroundColor: A2.tertiary, .paragraphStyle: truncating])
            }

            let meter = NSRect(x: meterX, y: center - 2.5, width: Self.meterWidth, height: 5)
            A2.meterTrack.setFill()
            NSBezierPath(roundedRect: meter, xRadius: 2.5, yRadius: 2.5).fill()
            let filled = NSRect(x: meter.minX, y: meter.minY, width: max(2, meter.width * CGFloat(min(1, max(0, row.fraction)))), height: 5)
            NSGradient(starting: A2.cpu, ending: A2.cpuLight)?.draw(in: NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5), angle: 0)

            for (text, right, font, color) in [(row.cpu, cpuRight, Self.cpuFont, A2.primary), (row.memory, memoryRight, Self.memoryFont, A2.secondary)] {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let width = (text as NSString).size(withAttributes: attributes).width
                (text as NSString).draw(at: NSPoint(x: right - width, y: center - (font.ascender - font.descender) / 2), withAttributes: attributes)
            }
        }
    }

    private func row(at point: NSPoint) -> Int? {
        guard point.y >= rowTop(0) else { return nil }
        let index = Int((point.y - rowTop(0)) / rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) { onSelect?(rows[index].id) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { rows.map { "\($0.name) \($0.cpu) \($0.memory)" }.joined(separator: "; ") }
}

/// A small action on a list row: a grey capsule, 26 pt tall, with a 12 pt semibold label.
final class A2PillButton: DrawnView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = Theme.sans(12, .semibold)

    var naturalWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 24 }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        (pressed ? A2.pillPressed : A2.pill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: A2.pillText]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// A suggestion: a 32 pt round symbol in a wash of its colour (or an app's icon), a
/// bold title over a quieter detail, and a pill button on the right. A hairline
/// above every row but the first.
final class A2TipRow: DrawnView {
    private let button = A2PillButton()
    private var symbol = ""
    private var tint = A2.cpu
    private var image: NSImage?
    private var title = ""
    private var detail = ""
    private var action: (() -> Void)?
    var showsRule = false { didSet { needsDisplay = true } }

    private static let titleFont = Theme.sans(13, .semibold)
    private static let detailFont = Theme.sans(11.5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(button)
        button.onPress = { [weak self] in self?.action?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, tint: NSColor, image: NSImage? = nil, title: String, detail: String, button label: String?, action: (() -> Void)?) {
        self.symbol = symbol
        self.tint = tint
        self.image = image
        self.title = title
        self.detail = detail
        self.action = action
        button.title = label ?? ""
        button.isHidden = label == nil
        needsLayout = true
        needsDisplay = true
    }

    private var textRight: CGFloat { button.isHidden ? bounds.width : button.frame.minX - 12 }

    override func layout() {
        super.layout()
        let width = button.naturalWidth
        button.frame = NSRect(x: bounds.width - width, y: ((bounds.height - 26) / 2).rounded(), width: width, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsRule {
            A2.hairline.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        }
        let center = bounds.height / 2
        let circle = NSRect(x: 0, y: center - 16, width: 32, height: 32)
        if let image {
            image.draw(in: circle.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            tint.withAlphaComponent(A2.drawingDark ? 0.14 : 0.12).setFill()
            NSBezierPath(ovalIn: circle).fill()
            IconTile.glyph(symbol, tint: tint, size: 16, appearance: effectiveAppearance)
                .draw(in: NSRect(x: 8, y: center - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let titleLine = Self.titleFont.ascender - Self.titleFont.descender
        let detailLine = Self.detailFont.ascender - Self.detailFont.descender
        // In the mockup the detail sits in a 16 pt line box, lower than its own font needs.
        let detailGap: CGFloat = 5.5
        let top = center - (titleLine + detailGap + detailLine) / 2
        let room = max(0, textRight - 44)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(with: NSRect(x: 44, y: top, width: room, height: ceil(titleLine)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Self.titleFont, .foregroundColor: A2.primary, .paragraphStyle: truncating])
        (detail as NSString).draw(with: NSRect(x: 44, y: top + titleLine + detailGap, width: room, height: ceil(detailLine)),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: Self.detailFont, .foregroundColor: A2.secondary, .paragraphStyle: truncating])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { title + ". " + detail }
}

/// A top card: the label, a figure with its sub line, and a body under them that runs
/// to the card's edges. `.spark` is one A2Spark on the bottom edge, `.capacity` an
/// A2CapacityBar and A2Keys held to the bottom, `.pair` two sparks (`spark` above,
/// `lowerSpark` hanging under it) for download and upload.
final class A2StatCard: CardView {
    enum Body { case spark, capacity, pair }

    let body: Body
    let label: A2CardLabel
    let figure = A2.figure()
    let sub = TextLine()
    let spark = A2Spark()
    let lowerSpark = A2Spark()
    let bar = A2CapacityBar()
    let keys = A2Keys()

    /// In the mockup's 172 pt card the sub line ends at 95 and the spark starts at 116.
    static let subTop: CGFloat = 81
    static let sparkTop: CGFloat = 116

    init(_ name: String, page: PageID, symbol: String? = nil, body: Body) {
        self.body = body
        label = A2CardLabel(name, symbol: symbol ?? page.symbol, tint: A2.labelTint(page))
        super.init()
        for view in [label, figure, sub] as [NSView] { addSubview(view) }
        switch body {
        case .spark: addSubview(spark)
        case .capacity: addSubview(bar); addSubview(keys)
        case .pair:
            addSubview(spark)
            addSubview(lowerSpark)
            spark.roundsBottom = false
            lowerSpark.mirrored = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inner = bounds.width - A2.padSide * 2
        let height = bounds.height
        label.frame = NSRect(x: A2.padSide, y: A2.padTop, width: inner, height: 15)
        figure.frame = A2.figureFrame(x: A2.padSide, baseline: 70, width: inner)
        sub.frame = NSRect(x: A2.padSide, y: Self.subTop, width: inner, height: 14)
        switch body {
        case .spark:
            spark.frame = NSRect(x: 0, y: Self.sparkTop, width: bounds.width, height: height - Self.sparkTop)
        case .capacity:
            // Held to the bottom edge, as in the mockup's Storage card, and never over the sub line.
            let keysHeight = keys.naturalHeight
            let barY = max(sub.frame.maxY + 13, height - A2.padTop - keysHeight - 12 - 8)
            bar.frame = NSRect(x: A2.padSide, y: barY.rounded(), width: inner, height: 8)
            keys.frame = NSRect(x: A2.padSide, y: bar.frame.maxY + 12, width: inner, height: keysHeight)
        case .pair:
            let lowerHeight = (height * 66 / 236).rounded()
            let top = sub.frame.maxY - 9
            spark.frame = NSRect(x: 0, y: top, width: bounds.width, height: height - lowerHeight - top)
            lowerSpark.frame = NSRect(x: 0, y: height - lowerHeight, width: bounds.width, height: lowerHeight)
        }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
