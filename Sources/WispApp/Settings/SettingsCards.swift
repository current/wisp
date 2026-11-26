import AppKit
import WispCore

// The parts a settings section is built from: cards with a tinted glyph tile and a
// one-line summary, rows that end in a control, and a page that sets the cards in
// two columns when the window has the room, one when it does not.

/// A view in a settings card whose height follows the card's width.
@MainActor
protocol SettingsSizing: NSView {
    func height(for width: CGFloat) -> CGFloat
}

/// What sits at the start of a list row: a symbol on a tile in a colour, or an image.
enum SettingsMark {
    case symbol(String, NSColor)
    case image(NSImage)
}

enum SettingsRow {
    /// A title, an optional line under it, and an optional control on the right.
    case control(String, String?, NSView?)
    /// A title with its mark, a control, and a switch at the end (menu bar items).
    case pair(String, SettingsMark, NSView, NSView)
    /// Any view, at a fixed height.
    case custom(NSView, CGFloat)
    /// Any view, as tall as it asks for at the card's width.
    case flexible(SettingsSizing)
    /// A `.control` row that belongs to the row above it, its title in line with that row's.
    case nested(String, String?, NSView?)
    /// A list row: its mark, a title, a quieter line and a control. `tip` shows on hover.
    case item(SettingsMark, String, String?, NSView?, tip: String?)
    /// What an empty list says and what to do about it, in the space a row would take.
    case empty(SettingsMark, String, String?, NSView?)
    /// Rows still being read: faint rows in the shape of the real ones, and what is happening.
    case loading(String, String?)
}

/// What a card's header shows on the right.
enum SettingsTrailing {
    case text(String)
    case pill(String, Pill.Tone)
    case view(NSView)
}

struct SettingsGroup {
    var title: String?
    var rows: [SettingsRow]
    var footer: String?
    var symbol: String?
    /// The tile's colour; the section's colour when nil.
    var tint: NSColor?
    var summary: String?
    var trailing: SettingsTrailing?
    /// Across both columns.
    var wide: Bool
    /// False for a group whose one row draws its own cards (the dashboard builder).
    var chrome: Bool
    /// A pill at the end of the footer: the way on from the hint.
    var action: (title: String, run: () -> Void)?

    init(_ title: String?, symbol: String? = nil, tint: NSColor? = nil, summary: String? = nil, trailing: SettingsTrailing? = nil,
         wide: Bool = false, chrome: Bool = true, _ rows: [SettingsRow], footer: String? = nil, action: (title: String, run: () -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.summary = summary
        self.trailing = trailing
        self.wide = wide
        self.chrome = chrome
        self.rows = rows
        self.footer = footer
        self.action = action
    }
}

/// The scrolling page of a settings section: cards on the window's ground, 22 pt from
/// its edges like every other page. From 860 pt of room the cards go in two columns,
/// each card into the shorter one; a wide card starts under both.
@MainActor
final class SettingsPageView: NSView {
    var groups: [SettingsGroup] = []
    var width: CGFloat = 560
    var tint: NSColor = Theme.accent
    private var built: [NSView] = []

    static let margin: CGFloat = 22
    static let gap: CGFloat = 12
    static let twoColumns: CGFloat = 860

    override var isFlipped: Bool { true }

    func relayout() {
        built.forEach { $0.removeFromSuperview() }
        built = []
        let margin = Self.margin, gap = Self.gap
        let inner = max(280, width - margin * 2)
        let columns = inner >= Self.twoColumns ? 2 : 1
        let column = columns == 2 ? ((inner - gap) / 2).rounded(.down) : inner
        var tops = [CGFloat](repeating: 0, count: columns)
        for group in groups {
            let wide = group.wide || columns == 1
            let index = wide ? 0 : (tops[1] < tops[0] ? 1 : 0)
            let top = wide ? (tops.max() ?? 0) : tops[index]
            let x = wide ? margin : margin + CGFloat(index) * (column + gap)
            let cardWidth = wide ? inner : (index == 1 ? inner - column - gap : column)
            let card: NSView = group.chrome ? SettingsCard(group, width: cardWidth, tint: tint) : Self.bare(group, width: cardWidth)
            card.frame.origin = NSPoint(x: x, y: top)
            add(card)
            let bottom = top + card.frame.height + gap
            if wide { tops = tops.map { _ in bottom } } else { tops[index] = bottom }
        }
        let used = (tops.max() ?? 0) - gap + margin
        frame = NSRect(x: 0, y: 0, width: width, height: max(used, superview?.bounds.height ?? 0))
    }

    /// A group with no card of its own: its rows one under another.
    private static func bare(_ group: SettingsGroup, width: CGFloat) -> NSView {
        let holder = FlippedView()
        var y: CGFloat = 0
        for row in group.rows {
            let view = RowView(row, width: width)
            view.frame.origin = NSPoint(x: 0, y: y)
            holder.addSubview(view)
            y += view.frame.height
        }
        holder.frame.size = NSSize(width: width, height: y)
        return holder
    }

    private func add(_ view: NSView) {
        addSubview(view)
        built.append(view)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One group as a card: the header, the rows with a hairline between them, and the
/// footer's hint with its way on.
@MainActor
final class SettingsCard: CardView {
    init(_ group: SettingsGroup, width: CGFloat, tint: NSColor) {
        super.init()
        radius = A2.radius
        var y: CGFloat = 0
        if let title = group.title {
            let header = SettingsCardHeader(title: title, symbol: group.symbol ?? "gearshape", tint: group.tint ?? tint,
                                            summary: group.summary, trailing: group.trailing)
            header.frame = NSRect(x: 0, y: 0, width: width, height: SettingsCardHeader.height)
            addSubview(header)
            y = SettingsCardHeader.height
        }
        for (index, row) in group.rows.enumerated() {
            if index > 0 || group.title != nil { addRule(y: y, width: width) }
            let view = RowView(row, width: width)
            view.frame.origin = NSPoint(x: 0, y: y)
            addSubview(view)
            y += view.frame.height
        }
        if group.footer != nil || group.action != nil {
            addRule(y: y, width: width)
            let footer = SettingsFooter(group.footer ?? "", action: group.action, width: width)
            footer.frame.origin = NSPoint(x: 0, y: y)
            addSubview(footer)
            y += footer.frame.height
        } else if group.title != nil, group.rows.isEmpty {
            y += 6
        }
        frame.size = NSSize(width: width, height: y)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func addRule(y: CGFloat, width: CGFloat) {
        let rule = SettingsRule()
        rule.frame = NSRect(x: RowView.inset, y: y - 0.5, width: width - RowView.inset * 2, height: 0.5)
        addSubview(rule)
    }
}

final class SettingsRule: DrawnView {
    override func draw(_ dirtyRect: NSRect) {
        A2.hairline.setFill()
        bounds.fill()
    }
}

/// A card's header: a 28 pt tile in the card's colour, the name, a quieter line under
/// it, and a count, a state pill or a control on the right.
final class SettingsCardHeader: DrawnView {
    static let height: CGFloat = 60
    private static let tile: CGFloat = 28
    private static let titleFont = Theme.sans(13.5, .semibold)
    private static let summaryFont = Theme.sans(11.5)

    private let title: String
    private let symbol: String
    private let tint: NSColor
    private let summary: String?
    private let trailingText: String?
    private var accessory: NSView?

    init(title: String, symbol: String, tint: NSColor, summary: String?, trailing: SettingsTrailing?) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.summary = summary
        var text: String?
        switch trailing {
        case .text(let value): text = value
        case .pill(let value, let tone):
            let pill = Pill()
            pill.text = value
            pill.tone = tone
            pill.dot = true
            accessory = pill
        case .view(let view): accessory = view
        case nil: break
        }
        trailingText = text
        super.init(frame: .zero)
        if let accessory { addSubview(accessory) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title, summary].compactMap { $0 }.joined(separator: ". "))
        if let text { setAccessibilityValue(text) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var accessorySize: NSSize {
        guard let accessory else { return .zero }
        if let pill = accessory as? Pill { return NSSize(width: pill.naturalWidth, height: 20) }
        return accessory.frame.size.width > 0 ? accessory.frame.size : accessory.fittingSize
    }

    private var trailingWidth: CGFloat {
        if accessory != nil { return accessorySize.width }
        guard let trailingText else { return 0 }
        return ceil((trailingText as NSString).size(withAttributes: [.font: A2.legendFont]).width)
    }

    private var textRoom: CGFloat {
        let x = RowView.inset + Self.tile + 12
        let trailing = trailingWidth
        return bounds.width - x - RowView.inset - (trailing > 0 ? trailing + 12 : 0)
    }

    override func layout() {
        super.layout()
        if let accessory {
            let size = accessorySize
            accessory.frame = NSRect(x: bounds.width - RowView.inset - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                                     width: size.width, height: size.height)
        }
        if let summary {
            let fits = ceil((summary as NSString).size(withAttributes: [.font: Self.summaryFont]).width) <= textRoom
            toolTip = fits ? nil : summary
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = (bounds.height / 2).rounded()
        let tile = Self.tile
        IconTile.image(symbol, tint: tint, size: tile, appearance: effectiveAppearance)
            .draw(in: NSRect(x: RowView.inset, y: mid - tile / 2, width: tile, height: tile), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let x = RowView.inset + tile + 12
        let room = max(40, textRoom)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let titleLine = ceil(Self.titleFont.ascender - Self.titleFont.descender)
        let summaryLine = ceil(Self.summaryFont.ascender - Self.summaryFont.descender)
        let top = summary == nil ? mid - titleLine / 2 : mid - (titleLine + 2 + summaryLine) / 2
        (title as NSString).draw(with: NSRect(x: x, y: top, width: room, height: titleLine), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: Self.titleFont, .foregroundColor: A2.primary, .paragraphStyle: truncating, .kern: -0.08])
        if let summary {
            (summary as NSString).draw(with: NSRect(x: x, y: top + titleLine + 2, width: room, height: summaryLine),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: Self.summaryFont, .foregroundColor: A2.secondary, .paragraphStyle: truncating])
        }
        if accessory == nil, let trailingText {
            let attributes: [NSAttributedString.Key: Any] = [.font: A2.legendFont, .foregroundColor: A2.secondary]
            let size = (trailingText as NSString).size(withAttributes: attributes)
            (trailingText as NSString).draw(at: NSPoint(x: bounds.width - RowView.inset - ceil(size.width), y: mid - size.height / 2), withAttributes: attributes)
        }
    }
}

/// The foot of a card: a quiet hint, and a pill that leads on from it.
final class SettingsFooter: DrawnView {
    private static let font = Theme.sans(11.5)
    private let text: String
    private let field: NSTextField

    init(_ text: String, action: (title: String, run: () -> Void)?, width: CGFloat) {
        self.text = text
        field = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        var right = width - RowView.inset
        var pillHeight: CGFloat = 0
        if let action {
            let pill = A2PillButton()
            pill.title = action.title
            pill.onPress = action.run
            let pillWidth = pill.naturalWidth
            pill.frame = NSRect(x: right - pillWidth, y: 0, width: pillWidth, height: 26)
            addSubview(pill)
            right -= pillWidth + 16
            pillHeight = 26
        }
        let glyph: CGFloat = 14
        let textX = RowView.inset + glyph + 8
        let room = max(60, right - textX)
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: A2.secondary])
        field.isSelectable = false
        field.preferredMaxLayoutWidth = room
        let textHeight = text.isEmpty ? 0 : ceil(field.sizeThatFits(NSSize(width: room, height: 400)).height)
        let height = max(44, max(textHeight, pillHeight) + 24)
        frame.size = NSSize(width: width, height: height)
        field.frame = NSRect(x: textX, y: ((height - textHeight) / 2).rounded(), width: room, height: textHeight)
        if !text.isEmpty { addSubview(field) }
        for view in subviews where view is A2PillButton { view.frame.origin.y = ((height - 26) / 2).rounded() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        IconTile.glyph("info.circle", tint: A2.tertiary, size: 14, appearance: effectiveAppearance)
            .draw(in: NSRect(x: RowView.inset, y: field.frame.minY + (lineHeight - 14) / 2, width: 14, height: 14), from: .zero,
                  operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// One row: its mark, title and explanation on the left, the control on the right.
/// 16 pt in from the card's edges, 11 above and below the text, at least 52 tall.
/// Rows that do something light up under the pointer.
@MainActor
final class RowView: DrawnView {
    static let inset: CGFloat = 16
    static let markSize: CGFloat = 26
    private static let gap: CGFloat = 16
    private static let minHeight: CGFloat = 52
    private static let titleFont = Theme.sans(13, .medium)
    private static let detailFont = Theme.sans(11.5)

    private var mark: SettingsMark?
    private var markRect = NSRect.zero
    private var hoverable = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(_ row: SettingsRow, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.minHeight))
        let inset = Self.inset
        switch row {
        case .control(let title, let detail, let control):
            layoutControl(title, detail, control, width: width, textInset: inset)
            hoverable = control != nil
        case .nested(let title, let detail, let control):
            layoutControl(title, detail, control, width: width, textInset: inset + Self.markSize + 12)
            hoverable = control != nil
        case .item(let mark, let title, let detail, let control, let tip):
            self.mark = mark
            layoutControl(title, detail, control, width: width, textInset: inset + Self.markSize + 12)
            markRect = NSRect(x: inset, y: ((frame.height - Self.markSize) / 2).rounded(), width: Self.markSize, height: Self.markSize)
            toolTip = tip
            hoverable = true
        case .pair(let title, let mark, let first, let second):
            self.mark = mark
            hoverable = true
            let height = Self.minHeight
            markRect = NSRect(x: inset, y: (height - Self.markSize) / 2, width: Self.markSize, height: Self.markSize)
            let secondSize = second.frame.size.width > 0 ? second.frame.size : second.fittingSize
            second.frame = NSRect(x: width - inset - secondSize.width, y: ((height - secondSize.height) / 2).rounded(),
                                  width: secondSize.width, height: secondSize.height)
            let firstSize = first.frame.size
            first.frame = NSRect(x: second.frame.minX - Self.gap - firstSize.width, y: ((height - firstSize.height) / 2).rounded(),
                                 width: firstSize.width, height: firstSize.height)
            let titleX = inset + Self.markSize + 12
            let titleField = Self.label(title, font: Self.titleFont, color: A2.primary, width: max(40, first.frame.minX - Self.gap - titleX), wraps: false)
            titleField.frame.origin = NSPoint(x: titleX, y: ((height - titleField.frame.height) / 2).rounded())
            addSubview(titleField)
            addSubview(first)
            addSubview(second)
            Self.name(first, title + " look")
            Self.name(second, "Show " + title)
        case .custom(let view, let height):
            frame.size.height = height
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            addSubview(view)
        case .flexible(let view):
            let height = view.height(for: width)
            frame.size.height = height
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            addSubview(view)
        case .empty(let mark, let title, let detail, let control):
            layoutEmpty(mark, title, detail, control, width: width)
        case .loading(let title, let detail):
            ghosts = 2
            let room = width - inset * 2
            let titleField = Self.label(title, font: Theme.sans(12.5, .semibold), color: A2.primary, width: room, alignment: .center)
            var y = CGFloat(ghosts) * Self.minHeight + 6
            titleField.frame.origin = NSPoint(x: inset, y: y)
            addSubview(titleField)
            y += titleField.frame.height + 2
            if let detail {
                let field = Self.label(detail, font: Self.detailFont, color: A2.secondary, width: room, alignment: .center)
                field.frame.origin = NSPoint(x: inset, y: y)
                addSubview(field)
                y += field.frame.height
            }
            frame.size.height = y + 18
        }
    }

    private var ghosts = 0

    /// A tile, a name, a quieter line and a meter, all in the faint fill of an empty track.
    private func drawGhosts() {
        A2.meterTrack.setFill()
        let inset = Self.inset
        for index in 0..<ghosts {
            let top = CGFloat(index) * Self.minHeight
            let mid = top + Self.minHeight / 2
            NSBezierPath(roundedRect: NSRect(x: inset, y: mid - Self.markSize / 2, width: Self.markSize, height: Self.markSize), xRadius: 7, yRadius: 7).fill()
            let x = inset + Self.markSize + 12
            let wide: CGFloat = index == 0 ? 0.34 : 0.26
            NSBezierPath(roundedRect: NSRect(x: x, y: mid - 10, width: (bounds.width * wide).rounded(), height: 8), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: x, y: mid + 3, width: (bounds.width * (wide + 0.12)).rounded(), height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - inset - 132, y: mid - 3, width: 80, height: 6), xRadius: 3, yRadius: 3).fill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - inset - 32, y: mid - 5, width: 32, height: 10), xRadius: 5, yRadius: 5).fill()
            A2.hairline.setFill()
            NSRect(x: inset, y: top + Self.minHeight - 0.5, width: bounds.width - inset * 2, height: 0.5).fill()
            A2.meterTrack.setFill()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layoutControl(_ title: String, _ detail: String?, _ control: NSView?, width: CGFloat, textInset: CGFloat) {
        let inset = Self.inset
        var controlWidth: CGFloat = 0
        if let control {
            let size = control.frame.size.width > 0 ? control.frame.size : control.fittingSize
            controlWidth = size.width
            addSubview(control)
            control.frame.size = size
        }
        let textWidth = width - textInset - inset - (controlWidth > 0 ? controlWidth + Self.gap : 0)
        var fields: [NSTextField] = []
        if !title.isEmpty { fields.append(Self.label(title, font: Self.titleFont, color: A2.primary, width: textWidth)) }
        if let detail, !detail.isEmpty { fields.append(Self.label(detail, font: Self.detailFont, color: A2.secondary, width: textWidth)) }
        let textHeight = fields.map(\.frame.height).reduce(0, +) + (fields.count > 1 ? 2 : 0)
        let height = max(Self.minHeight, textHeight + 24)
        frame.size.height = height
        var y = ((height - textHeight) / 2).rounded()
        for field in fields {
            field.frame.origin = NSPoint(x: textInset, y: y)
            addSubview(field)
            y += field.frame.height + 2
        }
        if let control {
            control.frame.origin = NSPoint(x: width - inset - control.frame.width, y: ((height - control.frame.height) / 2).rounded())
            Self.name(control, title, detail: detail)
        }
    }

    /// A switch or pop-up says nothing of its own; VoiceOver names it after its row,
    /// with the row's line under the title as help. Buttons keep their own titles.
    /// A container of controls (a pop-up beside a pill, a field in its capsule) names
    /// the ones inside it.
    static func name(_ control: NSView, _ title: String, detail: String? = nil) {
        guard !title.isEmpty else { return }
        guard control.isAccessibilityElement() else {
            for view in control.subviews { name(view, title, detail: detail) }
            return
        }
        guard (control.accessibilityLabel() ?? "").isEmpty else { return }
        control.setAccessibilityLabel(title)
        if let detail, !detail.isEmpty, (control.accessibilityHelp() ?? "").isEmpty { control.setAccessibilityHelp(detail) }
    }

    /// A round tile in a wash of its colour, the line, what to do, and the button,
    /// centred where the list will be.
    private func layoutEmpty(_ mark: SettingsMark, _ title: String, _ detail: String?, _ control: NSView?, width: CGFloat) {
        self.mark = mark
        let room = min(380, width - Self.inset * 2)
        var y: CGFloat = 20
        markRect = NSRect(x: ((width - 36) / 2).rounded(), y: y, width: 36, height: 36)
        y += 36 + 10
        let titleField = Self.label(title, font: Theme.sans(13, .semibold), color: A2.primary, width: room, alignment: .center)
        titleField.frame.origin = NSPoint(x: ((width - room) / 2).rounded(), y: y)
        addSubview(titleField)
        y += titleField.frame.height + 2
        if let detail {
            let field = Self.label(detail, font: Self.detailFont, color: A2.secondary, width: room, alignment: .center)
            field.frame.origin = NSPoint(x: ((width - room) / 2).rounded(), y: y)
            addSubview(field)
            y += field.frame.height
        }
        if let control {
            let size = control.frame.size
            control.frame.origin = NSPoint(x: ((width - size.width) / 2).rounded(), y: y + 12)
            addSubview(control)
            y += 12 + size.height
        }
        frame.size.height = y + 20
    }

    override func draw(_ dirtyRect: NSRect) {
        if ghosts > 0 { drawGhosts() }
        if hovering {
            A2.rowHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 10, yRadius: 10).fill()
        }
        guard let mark else { return }
        switch mark {
        case .symbol(let symbol, let tint):
            if markRect.width > Self.markSize {
                tint.withAlphaComponent(A2.drawingDark ? 0.16 : 0.12).setFill()
                NSBezierPath(ovalIn: markRect).fill()
                IconTile.glyph(symbol, tint: tint, size: 18, appearance: effectiveAppearance)
                    .draw(in: markRect.insetBy(dx: 9, dy: 9), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                IconTile.image(symbol, tint: tint, size: markRect.width, appearance: effectiveAppearance)
                    .draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .image(let image):
            image.draw(in: markRect.insetBy(dx: -1, dy: -1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hoverable else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Tracked in by 0.006 em, as the mockup's text is. A title that may not wrap ends
    /// in an ellipsis and shows in full on hover.
    static func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat, alignment: NSTextAlignment = .left, wraps: Bool = true) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        if !wraps { paragraph.lineBreakMode = .byTruncatingTail }
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: -0.006 * font.pointSize,
                                                                                  .paragraphStyle: paragraph])
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        if !wraps {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            if ceil(field.attributedStringValue.size().width) > width { field.toolTip = text }
        }
        let size = field.sizeThatFits(NSSize(width: width, height: 400))
        field.frame.size = NSSize(width: width, height: ceil(wraps ? size.height : font.ascender - font.descender + 2))
        return field
    }
}

/// A figure line for a row's right side: "CPU 0.3% · Memory 112 MB", the values bold
/// in tabular digits, redrawn when a reading changes.
final class SettingsFacts: DrawnView {
    var facts: [A2.Fact] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let text = A2.facts(facts)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.width - ceil(size.width), y: ((bounds.height - size.height) / 2).rounded()))
    }

    var naturalWidth: CGFloat { ceil(A2.facts(facts).size().width) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { A2.facts(facts).string }
}

/// A command to paste into a terminal: monospaced on a quiet well, cut in the middle
/// when it does not fit, the whole of it on hover, and a Copy pill that says Copied.
final class SettingsCommand: DrawnView, SettingsSizing {
    private let command: String
    private let title: String
    private let detail: String
    private let copy = A2PillButton()
    private static let font = Theme.mono(11.5, .regular)

    init(title: String, detail: String, command: String) {
        self.title = title
        self.detail = detail
        self.command = command
        super.init(frame: .zero)
        copy.title = "Copy"
        copy.onPress = { [weak self] in self?.copyCommand() }
        addSubview(copy)
        toolTip = command
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title + ". " + command)
        setAccessibilityHelp(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { 104 }

    private var well: NSRect { NSRect(x: RowView.inset, y: 56, width: bounds.width - RowView.inset * 2, height: 34) }

    override func layout() {
        super.layout()
        let width = max(copy.naturalWidth, 72)
        copy.frame = NSRect(x: well.maxX - 4 - width, y: well.midY - 13, width: width, height: 26)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copy.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.copy.title = "Copy" }
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleFont = Theme.sans(13, .medium)
        (title as NSString).draw(at: NSPoint(x: RowView.inset, y: 14), withAttributes: [.font: titleFont, .foregroundColor: A2.primary])
        (detail as NSString).draw(at: NSPoint(x: RowView.inset, y: 32), withAttributes: [.font: A2.subFont, .foregroundColor: A2.secondary])
        let well = self.well
        Theme.fill.setFill()
        NSBezierPath(roundedRect: well, xRadius: 10, yRadius: 10).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let line = ceil(Self.font.ascender - Self.font.descender)
        let room = copy.frame.minX - 12 - (well.minX + 12)
        ("$ " + command as NSString).draw(with: NSRect(x: well.minX + 12, y: well.midY - line / 2, width: max(20, room), height: line),
                                          options: [.usesLineFragmentOrigin],
                                          attributes: [.font: Self.font, .foregroundColor: A2.primary, .paragraphStyle: paragraph])
    }
}

/// When something happened, at the end of a row: the clock time today, the date before.
final class SettingsTime: DrawnView {
    private let text: String

    init(_ date: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d"
        text = formatter.string(from: date)
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.digits(12, .medium), .foregroundColor: A2.secondary]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.width - ceil(size.width), y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// A row's meter and its bold figure, as on the Coding Agents cards. Amber from 70%,
/// red from 90%, and the figure says it either way.
final class SettingsMeter: DrawnView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let figure = Format.percent(fraction)
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.digits(13, .semibold), .foregroundColor: A2.primary]
        let size = (figure as NSString).size(withAttributes: attributes)
        let figureWidth: CGFloat = 40
        (figure as NSString).draw(at: NSPoint(x: bounds.width - ceil(size.width), y: (bounds.height - size.height) / 2), withAttributes: attributes)
        let color = fraction >= 0.9 ? A2.bad : fraction >= 0.7 ? A2.warn : A2.cpu
        A2Dev.drawMeter(NSRect(x: 0, y: (bounds.height - 6) / 2, width: bounds.width - figureWidth - 12, height: 6), fraction: fraction, colors: (color, color))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    // The amber and red say how close the limit is; the words say it too.
    override func accessibilityValue() -> Any? {
        Format.percent(fraction) + (fraction >= 1 ? ", used up" : fraction >= 0.9 ? ", near limit" : fraction >= 0.7 ? ", getting close" : "")
    }
}

/// The top of About: the app icon, its name and version with a state pill, and on the
/// right what Wisp costs to run right now, as a figure with its unit.
final class AboutHero: DrawnView, SettingsSizing {
    /// A newer version's number, when GitHub has one.
    var release: String? { didSet { syncPill() } }
    var checking = true { didSet { syncPill() } }
    /// Wisp's own CPU, in cores, and memory.
    var use: (cpu: Double, memory: UInt64)? {
        didSet {
            guard let use else { return }
            figure.show(String(format: use.cpu < 0.1 ? "%.1f" : "%.0f", use.cpu * 100), unit: "%")
            sub.text = A2.facts([A2.Fact(label: "of one core and", value: Format.memory(use.memory))])
            needsDisplay = true
        }
    }

    private let pill = Pill()
    private let figure = A2.figure()
    private let sub = TextLine()
    private let label = A2CardLabel("Running now", symbol: "gauge.with.needle", tint: SettingsPage.Section.about.tint)
    private static let blurb = "A system monitor that stays out of the way: about 0.2% of one core and 18 MB with only the menu bar showing."
    private static let iconSize: CGFloat = 76

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.showsChevron = false
        for view in [pill, figure, sub, label] as [NSView] { addSubview(view) }
        figure.show("–", unit: "%")
        sub.text = A2.plain("Measuring…")
        syncPill()
        // The name, version and blurb are drawn; the pill and the figure stay children.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Wisp, version " + Wisp.version)
        setAccessibilityValue(Self.blurb)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { 132 }

    private func syncPill() {
        if let release {
            pill.text = "\(release) is out"
            pill.tone = .warn
        } else if checking {
            pill.text = "Up to date"
            pill.tone = .good
        } else {
            pill.text = "Not checking"
            pill.tone = .neutral
        }
        pill.dot = true
        needsLayout = true
    }

    private var split: CGFloat { bounds.width >= 640 ? bounds.width - 240 : bounds.width }

    override func layout() {
        super.layout()
        let x = RowView.inset + Self.iconSize + 18
        let nameWidth = ceil(("Wisp" as NSString).size(withAttributes: [.font: Theme.sans(22, .semibold)]).width)
        pill.frame = NSRect(x: x + nameWidth + 10, y: 30, width: pill.naturalWidth, height: 20)
        let showsUse = split < bounds.width
        for view in [figure, sub, label] as [NSView] { view.isHidden = !showsUse }
        guard showsUse else { return }
        let left = split + 8
        let inner = bounds.width - left - A2.padSide
        label.frame = NSRect(x: left, y: A2.padTop + 8, width: inner, height: 15)
        figure.frame = A2.figureFrame(x: left, baseline: 78, width: inner)
        sub.frame = NSRect(x: left, y: 90, width: inner, height: 14)
        toolTip = "Measured like any other app, this window included. With only the menu bar showing, Wisp uses far less."
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = Self.iconSize
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: NSRect(x: RowView.inset - 4, y: ((bounds.height - size) / 2).rounded(), width: size, height: size),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let x = RowView.inset + size + 18
        let room = split - x - 24
        ("Wisp" as NSString).draw(at: NSPoint(x: x, y: 26), withAttributes: [.font: Theme.sans(22, .semibold), .foregroundColor: A2.primary])
        let version = A2.facts([A2.Fact(label: "Version", value: Wisp.version)])
        version.draw(at: NSPoint(x: x, y: 58))
        let blurb = NSAttributedString(string: Self.blurb, attributes: [.font: Theme.sans(12.5), .foregroundColor: A2.secondary])
        blurb.draw(with: NSRect(x: x, y: 80, width: max(80, room), height: 40), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if split < bounds.width {
            A2.hairline.setFill()
            NSRect(x: split - 8, y: 20, width: 0.5, height: bounds.height - 40).fill()
        }
    }
}

/// The window's look as three small windows to pick from: light, dark, and one split
/// down the middle for following macOS. The chosen one has a ring in the accent colour.
final class AppearancePicker: DrawnView, SettingsSizing {
    var selected: Int { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private let titles = ["Light", "Dark", "Match the system"]
    private static let thumb = NSSize(width: 112, height: 70)
    private static let gap: CGFloat = 20

    init(selected: Int) {
        self.selected = selected
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Appearance")
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { 16 + Self.thumb.height + 8 + 16 + 14 }

    private func frame(of index: Int) -> NSRect {
        NSRect(x: RowView.inset + CGFloat(index) * (Self.thumb.width + Self.gap), y: 16, width: Self.thumb.width, height: Self.thumb.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in titles.indices {
            let rect = frame(of: index)
            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            shape.addClip()
            if index == 2 {
                drawWindow(in: rect, dark: false)
                let half = NSBezierPath()
                half.move(to: NSPoint(x: rect.midX + 14, y: rect.minY))
                half.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                half.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                half.line(to: NSPoint(x: rect.midX - 14, y: rect.maxY))
                half.close()
                half.addClip()
                drawWindow(in: rect, dark: true)
            } else {
                drawWindow(in: rect, dark: index == 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            let on = index == selected
            let ring = NSBezierPath(roundedRect: on ? rect.insetBy(dx: -3, dy: -3) : rect.insetBy(dx: 0.25, dy: 0.25),
                                    xRadius: on ? 12 : 9, yRadius: on ? 12 : 9)
            ring.lineWidth = on ? 2.5 : 0.5
            (on ? Theme.accent : Theme.cardBorderHover).setStroke()
            ring.stroke()
            let font = on ? Theme.sans(12, .semibold) : Theme.sans(12)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: on ? A2.primary : A2.secondary]
            let size = (titles[index] as NSString).size(withAttributes: attributes)
            (titles[index] as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 8), withAttributes: attributes)
        }
    }

    /// A window in miniature: the ground, a sidebar with a selected row, and three cards.
    private func drawWindow(in rect: NSRect, dark: Bool) {
        let ground = dark ? NSColor(white: 0.115, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        let card = dark ? NSColor(white: 0.16, alpha: 1) : .white
        let sidebar = dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        let ink = dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.13)
        ground.setFill()
        rect.fill()
        sidebar.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 30, height: rect.height).fill()
        ink.setFill()
        for row in 0..<4 { NSRect(x: rect.minX + 6, y: rect.minY + 14 + CGFloat(row) * 9, width: 18, height: 3).fill() }
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 4, y: rect.minY + 12.5 + 9, width: 22, height: 6), xRadius: 2, yRadius: 2).fill()
        card.setFill()
        let x = rect.minX + 36, w = rect.width - 42
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 8, width: w, height: 26), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 38, width: (w - 4) / 2, height: 24), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: x + (w + 4) / 2, y: rect.minY + 38, width: (w - 4) / 2, height: 24), xRadius: 4, yRadius: 4).fill()
        Theme.accent.withAlphaComponent(0.8).setFill()
        let chart = NSBezierPath()
        chart.move(to: NSPoint(x: x, y: rect.minY + 34))
        for (step, value) in [0.5, 0.35, 0.6, 0.3, 0.45, 0.2, 0.4].enumerated() {
            chart.line(to: NSPoint(x: x + w * CGFloat(step) / 6, y: rect.minY + 12 + 18 * value))
        }
        chart.line(to: NSPoint(x: x + w, y: rect.minY + 34))
        chart.close()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 8, width: w, height: 26), xRadius: 4, yRadius: 4).addClip()
        Theme.accent.withAlphaComponent(dark ? 0.45 : 0.3).setFill()
        chart.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = titles.indices.first(where: { frame(of: $0).insetBy(dx: -4, dy: -4).contains(point) }), index != selected else { return }
        selected = index
        onPick?(index)
    }

    override func accessibilityValue() -> Any? { titles[selected] }

    // Each window is a radio button so VoiceOver can pick one, as a click does.
    private final class Choice: NSAccessibilityElement {
        weak var owner: AppearancePicker?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            guard let owner else { return false }
            if owner.selected != index {
                owner.selected = index
                owner.onPick?(index)
            }
            return true
        }
        override func accessibilityValue() -> Any? { owner?.selected == index ? 1 : 0 }
        override func accessibilityFrameInParentSpace() -> NSRect {
            guard let owner else { return .zero }
            let rect = owner.frame(of: index)
            return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    private lazy var choices: [Choice] = titles.indices.map { index in
        let choice = Choice()
        choice.owner = self
        choice.index = index
        choice.setAccessibilityRole(.radioButton)
        choice.setAccessibilityLabel(titles[index])
        choice.setAccessibilityParent(self)
        return choice
    }

    override func accessibilityChildren() -> [Any]? { choices }
}
