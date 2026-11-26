import AppKit
import WispCore

// Pieces for the Neural Engine, Sound and Bluetooth pages, on top of the A2 views:
//
//   HourColumns   today as 24 columns, one per hour, with a hover readout
//   SkeletonRows  the shape of a list that has nothing to show yet, drawn in placeholders
//   ChartNote     two centred lines laid over a chart that has nothing to plot

/// Today from midnight as 24 columns. A recorded hour fills its track from the floor;
/// an hour with no readings keeps an empty outline, and hours still to come show only a
/// dot on the baseline. Hovering a column hands its index to `onHover`.
final class HourColumns: BitmapView {
    /// One value per hour from midnight; nil where nothing was recorded.
    var values: [Double?] = [] { didSet { if values != oldValue { needsDisplay = true } } }
    /// The hour in progress; the columns after it have not happened yet.
    var current = 0 { didSet { if current != oldValue { needsDisplay = true } } }
    var ceiling: Double = 1 { didSet { if ceiling != oldValue { needsDisplay = true } } }
    var color = A2.neural
    var end: NSColor?
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var onHover: ((Int?) -> Void)?
    private(set) var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true; onHover?(hovered) } } }

    static let axisHeight: CGFloat = 20
    static let scaleWidth: CGFloat = 58
    private static let labelFont = Theme.digits(10)

    private var plot: NSRect {
        NSRect(x: 0, y: 8, width: max(0, bounds.width - Self.scaleWidth), height: max(0, bounds.height - 8 - Self.axisHeight))
    }

    private var slot: CGFloat { plot.width / 24 }

    override func draw(_ dirtyRect: NSRect) {
        let plot = self.plot
        guard plot.width > 48, plot.height > 10 else { return }
        // The scale: a dashed line at the ceiling and at half of it, labelled on the right.
        for (fraction, label) in [(1.0, true), (0.5, false)] {
            let y = (plot.maxY - plot.height * fraction).rounded() + 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: bounds.width - Self.scaleWidth + 4, y: y))
            line.lineWidth = 1
            line.setLineDash([2, 3], count: 2, phase: 0)
            A2.grid.setStroke()
            line.stroke()
            if label {
                let text = format(ceiling * fraction)
                A2.draw(text, at: bounds.width - A2.width(text, Self.labelFont), mid: y, font: Self.labelFont, color: A2.gridLabel)
            }
        }
        let slot = self.slot
        let width = max(3, (slot * 0.62).rounded())
        let radius = min(4, width / 2)
        for index in 0..<24 {
            let x = (plot.minX + CGFloat(index) * slot + (slot - width) / 2).rounded()
            let column = NSRect(x: x, y: plot.minY, width: width, height: plot.height)
            if index == hovered {
                A2.rowHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: plot.minX + CGFloat(index) * slot + 1, y: plot.minY - 4, width: slot - 2, height: plot.height + 8),
                             xRadius: 6, yRadius: 6).fill()
            }
            if index > current {
                A2.track.setFill()
                NSBezierPath(ovalIn: NSRect(x: column.midX - 1.5, y: plot.maxY - 3, width: 3, height: 3)).fill()
                continue
            }
            let value = index < values.count ? values[index] : nil
            guard let value else {
                // Wisp was not reading the chip then: an outline, so a gap does not read as zero.
                let outline = NSBezierPath(roundedRect: column.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                outline.lineWidth = 1
                outline.setLineDash([2, 2], count: 2, phase: 0)
                A2.grid.setStroke()
                outline.stroke()
                continue
            }
            A2.meterTrack.setFill()
            NSBezierPath(roundedRect: column, xRadius: radius, yRadius: radius).fill()
            guard value > 0 else { continue }
            let height = max(3, plot.height * CGFloat(min(1, value / max(ceiling, .leastNonzeroMagnitude))))
            let filled = NSBezierPath(roundedRect: NSRect(x: x, y: plot.maxY - height, width: width, height: height), xRadius: radius, yRadius: radius)
            if let end, let gradient = NSGradient(starting: end, ending: color) {
                gradient.draw(in: filled, angle: 90)
            } else {
                color.setFill()
                filled.fill()
            }
        }
        // Hour labels every six hours, and "Now" under the hour in progress when it has room.
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        var marks: [(Int, String, NSColor)] = stride(from: 0, to: 24, by: 6).map { hour in
            (hour, formatter.string(from: calendar.date(byAdding: .hour, value: hour, to: midnight) ?? midnight), A2.gridLabel)
        }
        if current < 24 {
            marks.removeAll { abs($0.0 - current) < 2 }
            marks.append((current, "Now", A2.secondary))
        }
        let labelY = plot.maxY + Self.axisHeight / 2 + 2
        for (hour, text, color) in marks {
            let center = plot.minX + (CGFloat(hour) + 0.5) * slot
            let textWidth = A2.width(text, Self.labelFont)
            let x = min(max(0, center - textWidth / 2), plot.maxX - textWidth)
            A2.draw(text, at: x, mid: labelY, font: Self.labelFont, color: color)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.x - plot.minX) / max(1, slot))
        hovered = point.x >= plot.minX && point.x < plot.maxX && index <= current ? index : nil
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Today by hour" }
    override func accessibilityValue() -> Any? {
        values.prefix(current + 1).enumerated().map { "\($0.offset):00 \($0.element.map(format) ?? "not recorded")" }.joined(separator: ", ")
    }
}

/// Rows in the shape of a list that cannot be filled yet: a glyph square, a name and a
/// detail as rounded bars, and the right-hand columns as shorter bars. Each row is a
/// little fainter than the one above, so the list trails off instead of ending.
final class SkeletonRows: BitmapView {
    var count = 4 { didSet { if count != oldValue { needsDisplay = true } } }
    var rowHeight: CGFloat = 52 { didSet { if rowHeight != oldValue { needsDisplay = true } } }
    /// Widths of the bars on the right, from the right edge, as in the real list's columns.
    var cells: [CGFloat] = [] { didSet { if cells != oldValue { needsDisplay = true } } }
    /// A symbol in each row's glyph square, so the shape says what will be listed.
    var symbols: [String] = [] { didSet { if symbols != oldValue { needsDisplay = true } } }
    private static let nameWidths: [CGFloat] = [0.32, 0.22, 0.27, 0.18, 0.25]

    override func draw(_ dirtyRect: NSRect) {
        let ink = A2.track
        for index in 0..<count {
            let top = CGFloat(index) * rowHeight
            guard top + rowHeight <= bounds.height + 1 else { break }
            let alpha = max(0.35, 1 - CGFloat(index) * 0.18)
            let mid = top + rowHeight / 2
            if index > 0 {
                A2.hairline.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
            }
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            let tile = NSRect(x: 0, y: (mid - 13).rounded(), width: 26, height: 26)
            if index < symbols.count {
                A2.glyphTile(symbols[index], in: tile, tint: nil, appearance: effectiveAppearance)
            } else {
                ink.setFill()
                NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            }
            var right = bounds.width
            for (cell, width) in cells.reversed().enumerated() {
                let bar = width * (cell == 0 ? 0.6 : 0.8)
                ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: right - bar, y: mid - 4, width: bar, height: 8), xRadius: 4, yRadius: 4).fill()
                right -= width + A2Row.spacing
            }
            let room = max(0, right - 37 - 20)
            let name = room * Self.nameWidths[index % Self.nameWidths.count] * 2
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 37, y: mid - 9, width: min(room, name), height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 37, y: mid + 4, width: min(room, name * 0.6), height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// Two centred lines over a chart with nothing to plot: what the quiet means, then a
/// quieter line with the last thing that did happen.
final class ChartNote: DrawnView {
    private let title = TextLine()
    private let detail = TextLine()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.alignment = .center
        detail.alignment = .center
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, detail line: String) {
        title.text = NSAttributedString(string: text, attributes: [.font: Theme.sans(12.5, .medium), .foregroundColor: A2.secondary])
        detail.text = NSAttributedString(string: line, attributes: [.font: Theme.sans(11.5), .foregroundColor: A2.tertiary])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = (bounds.height - 38) / 2
        title.frame = NSRect(x: 0, y: top, width: bounds.width, height: 18)
        detail.frame = NSRect(x: 0, y: top + 21, width: bounds.width, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// When something was in use over a span of time, as filled stretches of a thin track:
/// one flag per reading, oldest on the left. Hovering shows the reading's time.
final class UseStrip: BitmapView {
    var flags: [Bool] = [] { didSet { if flags != oldValue { needsDisplay = true } } }
    var color = A2.warn

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 8) / 2, width: bounds.width, height: 8)
        A2.meterTrack.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        guard flags.count > 1, flags.contains(true) else { return }
        let dx = track.width / CGFloat(flags.count - 1)
        color.setFill()
        var index = 0
        while index < flags.count {
            guard flags[index] else { index += 1; continue }
            let first = index
            while index < flags.count, flags[index] { index += 1 }
            let from = max(track.minX, track.minX + (CGFloat(first) - 0.5) * dx)
            let to = min(track.maxX, track.minX + (CGFloat(index - 1) + 0.5) * dx)
            NSBezierPath(roundedRect: NSRect(x: from, y: track.minY, width: max(4, to - from), height: track.height), xRadius: 4, yRadius: 4).fill()
        }
    }

    /// What the strip records, for VoiceOver ("Microphone use").
    var title = ""

    override func isAccessibilityElement() -> Bool { !title.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { Self.spoken(flags, on: "In use", off: "Not used") }

    /// Filled stretches in words: the share of readings and how many stretches they make.
    static func spoken(_ flags: [Bool], on: String, off: String) -> String {
        guard !flags.isEmpty else { return "No readings yet" }
        let count = flags.filter { $0 }.count
        guard count > 0 else { return off + " in this span" }
        let stretches = zip([false] + flags, flags).filter { !$0 && $1 }.count
        let share = Int((Double(count) / Double(flags.count) * 100).rounded())
        return "\(on) \(share)% of the time, in \(stretches == 1 ? "1 stretch" : "\(stretches) stretches")"
    }
}
