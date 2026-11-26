import AppKit
import WispCore

/// The soft style that the menu bar items' dropdowns share: Wisp's icon with a title and
/// a status line, one soft section of white cards, and a footer with a hint and a link to
/// the matching page. Each item's dropdown subclasses this and fills the cards.
@MainActor
class SoftDropdown: DrawnView {
    /// Laid out at 400 points and shown at 11/13 of that (about 340): the view's bounds
    /// stay 400 wide while its frame shrinks, so every measurement below scales together,
    /// and the 13-point text lands on a whole 11 points.
    static let width: CGFloat = 400
    nonisolated static let scale: CGFloat = 11.0 / 13.0
    /// The panel's corner on screen.
    static var panelRadius: CGFloat { radius * scale }
    /// The panel's corner: the section's, plus the margin around it.
    static let radius: CGFloat = sectionRadius + sectionX
    static let headHeight: CGFloat = 64
    static let sectionX: CGFloat = 10
    static let sectionRadius: CGFloat = 18
    static let sectionTitle: CGFloat = 36
    static let inset: CGFloat = 7
    /// Below the last card: a little more than at the sides, as in the reference, so the
    /// card's shadow does not make it look as if it sits on the section's edge.
    static let bottomInset: CGFloat = 8.5
    /// The footer's text sits this far above the middle of its band, so the space over its
    /// capitals matches the space under its baseline.
    static let footerLift: CGFloat = 1
    static let cardGap: CGFloat = 7
    static let padX: CGFloat = 14
    static let emptyHeight: CGFloat = 104
    static let footerHeight: CGFloat = 46
    /// The cards' corner, concentric with the section's.
    static var cardRadius: CGFloat { sectionRadius - inset + 1 }

    unowned let delegate: AppDelegate
    let plate = Plate()
    let head = Head()
    private let page: PageID
    private lazy var moreButton = RoundButton(symbol: "ellipsis", label: "More", target: self, action: #selector(showMore(_:)))
    private lazy var openButton = RoundButton(symbol: "arrow.up.right", label: "Open " + page.title, target: self, action: #selector(openPage))
    private lazy var footerLink = LinkButton(title: page.title, target: self, action: #selector(openPage))
    private let emptyText = TextLine()
    private lazy var emptyButton = ActionButton(title: "", target: self, action: #selector(emptyPressed))
    /// The empty card's action, when the dropdown has nothing to show.
    var onEmpty: (() -> Void)?
    var onHeightChange: (() -> Void)?

    init(delegate: AppDelegate, title: String, page: PageID) {
        self.delegate = delegate
        self.page = page
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width * Self.scale, height: 300))
        wantsLayer = true
        head.title = title
        emptyText.alignment = .center
        emptyButton.secondary = true
        emptyButton.font = Look.strong
        for view in [plate, head, moreButton, openButton, footerLink, emptyText, emptyButton] as [NSView] { addSubview(view) }
        showEmpty(nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Each sample while the dropdown is open.
    func update(_ s: SystemSnapshot, history: HistoryStore) {}

    /// Each new process table while the dropdown is open.
    func update(_ table: ProcessTable) {}

    /// Called as the dropdown opens, before it shows.
    func prepare() {}

    func hideTooltip() {}

    /// Items above Settings and Quit in the ⋯ menu.
    func menuItems() -> [NSMenuItem] { [] }

    // MARK: Reordering

    /// Set by a dropdown whose cards can be dragged into another order. It gets the
    /// cards in their new order once one is dropped somewhere else.
    var onReorder: (([SoftCard]) -> Void)?
    /// After a drag, whether or not the order changed. Updates that came during it wait for this.
    func dragEnded() {}
    var isDragging: Bool { drag != nil }
    private var arranged: [SoftCard] = []
    private var cardsTop: CGFloat = 0
    private var drag: (card: SoftCard, grab: CGFloat, order: [SoftCard])?

    /// Where each card's top goes, stacked in this order.
    private func tops(_ order: [SoftCard]) -> [CGFloat] {
        var y = cardsTop
        return order.map { card in
            defer { y += card.frame.height + Self.cardGap }
            return y
        }
    }

    func beginDrag(_ card: SoftCard, event: NSEvent) {
        guard arranged.contains(where: { $0 === card }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag = (card, point.y - card.frame.minY, arranged)
        card.lifted = true
        NSCursor.closedHand.push()
    }

    /// The card follows the pointer; the others make room where it would land.
    func moveDrag(_ card: SoftCard, event: NSEvent) {
        guard let drag, drag.card === card else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ends = tops(drag.order)
        let last = (ends.last ?? cardsTop) + (drag.order.last?.frame.height ?? 0) - card.frame.height
        // A little past either end, then it stops.
        let y = min(max(point.y - drag.grab, cardsTop - 8), max(cardsTop, last) + 8)
        card.setFrameOrigin(NSPoint(x: card.frame.minX, y: y.rounded()))

        let others = drag.order.filter { $0 !== card }
        var best = 0, nearest = CGFloat.infinity
        for index in 0...others.count {
            var order = others
            order.insert(card, at: index)
            let distance = abs(tops(order)[index] - y)
            if distance < nearest { (best, nearest) = (index, distance) }
        }
        var order = others
        order.insert(card, at: best)
        guard !zip(order, drag.order).allSatisfy({ $0 === $1 }) else { return }
        self.drag?.order = order
        let places = tops(order)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            for (other, top) in zip(order, places) where other !== card {
                other.animator().setFrameOrigin(NSPoint(x: other.frame.minX, y: top))
            }
        }
    }

    func endDrag(_ card: SoftCard) {
        guard let drag, drag.card === card else { return }
        self.drag = nil
        NSCursor.pop()
        let place = tops(drag.order)[drag.order.firstIndex { $0 === card } ?? 0]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            card.animator().setFrameOrigin(NSPoint(x: card.frame.minX, y: place))
        }
        card.lifted = false
        let moved = !zip(drag.order, arranged).allSatisfy { $0 === $1 }
        arranged = drag.order
        if moved { onReorder?(drag.order) }
        dragEnded()
    }

    /// Moves a card one place up or down without a drag, for VoiceOver's actions.
    func move(_ card: SoftCard, by offset: Int) -> Bool {
        guard drag == nil, let index = arranged.firstIndex(where: { $0 === card }) else { return false }
        let target = index + offset
        guard arranged.indices.contains(target) else { return false }
        var order = arranged
        order.swapAt(index, target)
        arranged = order
        onReorder?(order)
        dragEnded()
        needsLayout = true
        return true
    }

    /// The empty card: a line saying why, and a button that does something about it.
    func showEmpty(_ message: String?, button: String = "") {
        emptyText.text = NSAttributedString(string: message ?? "", attributes: [.font: Look.body, .foregroundColor: Look.secondary])
        emptyButton.title = button
        emptyText.isHidden = message == nil
        emptyButton.isHidden = message == nil || button.isEmpty
    }

    /// Lays out the header, the cards in order under the section heading, and the footer,
    /// and sizes the view to fit. Every card's lines share one label column and one bar
    /// length, so the bars line up down the whole dropdown.
    func arrange(_ cards: [SoftCard]) {
        // A drag owns the cards' places until it ends; `dragEnded` arranges them again.
        guard drag == nil else { return }
        let width = Self.width
        head.frame = NSRect(x: 0, y: 0, width: width, height: Self.headHeight)
        let button: CGFloat = 30
        openButton.frame = NSRect(x: width - 16 - button, y: (Self.headHeight - button) / 2 + 1, width: button, height: button)
        moreButton.frame = openButton.frame.offsetBy(dx: -(button + 8), dy: 0)
        head.textRight = moreButton.frame.minX - 12

        let section = NSRect(x: Self.sectionX, y: Self.headHeight, width: width - Self.sectionX * 2, height: 0)
        let cardX = section.minX + Self.inset, cardWidth = section.width - Self.inset * 2
        var y = section.minY + Self.sectionTitle
        var plates: [NSRect] = []
        // Cards of readings share their columns, so their bars start and end together.
        // A list of apps keeps its own: its names and figures are wider, and sharing them
        // would squeeze every other card's bars. A card without details stretches its
        // bars to its own edge.
        let readings = cards.filter { !$0.listsApps }
        let column = SoftCard.column(labels: readings.map(\.labelWidth).max() ?? 0)
        let detailed = readings.filter { $0.detailNeed > 0 }
        let sharedDetail = detailed.map(\.detailNeed).max() ?? 0
        let sharedFigure = detailed.map(\.figureNeed).max() ?? 0
        // Fixed cards at the top (a summary) stay put; only the cards after them move.
        let fixed = cards.prefix { $0.fixed }
        let movableCards = Array(cards.dropFirst(fixed.count))
        let movable = onReorder != nil && movableCards.count > 1
        for card in cards {
            if card === movableCards.first {
                arranged = movableCards
                cardsTop = y
            }
            card.column = card.listsApps ? SoftCard.column(labels: card.labelWidth) : column
            card.shared = card.listsApps || card.detailNeed == 0 ? (0, 0) : (sharedFigure, sharedDetail)
            card.dragHost = movable && !card.fixed ? self : nil
            let rect = NSRect(x: cardX, y: y, width: cardWidth, height: card.height)
            card.frame = rect
            y = rect.maxY + Self.cardGap
        }
        if movableCards.isEmpty {
            arranged = []
            cardsTop = y
        }
        if !emptyText.isHidden {
            let rect = NSRect(x: cardX, y: y, width: cardWidth, height: Self.emptyHeight)
            plates.append(rect)
            emptyText.frame = NSRect(x: rect.minX + 16, y: rect.minY + 22, width: rect.width - 32, height: 18)
            let size = emptyButton.intrinsicContentSize
            emptyButton.frame = NSRect(x: (rect.midX - size.width / 2).rounded(), y: rect.minY + 54, width: size.width, height: size.height)
            y = rect.maxY + Self.cardGap
        }
        var sectionRect = section
        sectionRect.size.height = y - Self.cardGap + Self.bottomInset - section.minY
        let height = sectionRect.maxY + Self.footerHeight
        plate.section = sectionRect
        plate.cards = plates
        plate.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let link = footerLink.intrinsicContentSize
        footerLink.frame = NSRect(x: width - 18 - link.width, y: (sectionRect.maxY + (Self.footerHeight - link.height) / 2 - Self.footerLift).rounded(),
                                  width: link.width, height: link.height)
        plate.footerRight = footerLink.frame.minX - 12
        let shown = NSSize(width: (width * Self.scale).rounded(), height: (height * Self.scale).rounded())
        if frame.size != shown || bounds.size != NSSize(width: width, height: height) {
            setFrameSize(shown)
            setBoundsSize(NSSize(width: width, height: height))
            onHeightChange?()
        }
    }

    // MARK: Actions

    @objc private func openPage() { delegate.showPage(page) }
    @objc func openSettings() { delegate.showSettings() }
    @objc private func openWhatsNew() { delegate.showWhatsNew() }
    @objc private func emptyPressed() { onEmpty?() }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        let extra = menuItems()
        extra.forEach(menu.addItem)
        if !extra.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "What's New in Wisp", action: #selector(openWhatsNew), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }
}

// MARK: - Shared cards

extension SoftDropdown {
    /// "Last 4 minutes": what the recent history covers at the sampling interval.
    var recentSpan: String {
        "Last \(Int((Double(HistoryStore.recentSamples) * delegate.settings.interval / 60).rounded())) minutes"
    }

    /// A chart that fills the bottom of a card, as the app's cards draw them.
    static func makeChart(_ primary: NSColor, _ secondary: NSColor? = nil, names: (String, String) = ("", ""),
                          format: @escaping (Float) -> String) -> TimeChart {
        let chart = TimeChart()
        chart.edgeToEdge = true
        chart.primaryColor = primary
        if let secondary { chart.secondaryColor = secondary }
        chart.secondaryFill = 0.3
        chart.names = names
        chart.format = format
        chart.edgeClip = SoftCard.chartClip
        return chart
    }

    /// The apps doing the most of something, with their icons: the figure, their share
    /// of the whole (hovering shows how many processes), and a click opens one in Wisp.
    func showApps(_ card: SoftCard, title: String, table: ProcessTable, color: NSColor, value: (AppGroup) -> Double,
                  figure: (AppGroup) -> String, whole: Double? = nil) {
        let top = Array(table.apps.filter { value($0) > 0 }.sorted { value($0) > value($1) }.prefix(5))
        card.ids = top.map(\.id)
        card.isHidden = top.isEmpty
        let peak = max(top.first.map(value) ?? 1, .leastNonzeroMagnitude)
        let sum = whole ?? table.apps.map(value).reduce(0, +)
        card.onClick = { [weak self, weak card] index in
            guard let self, let card, card.ids.indices.contains(index) else { return }
            self.delegate.showWindow(selecting: card.ids[index])
        }
        card.show(mark: .glyph(PageID.apps.symbol, A2.labelTint(.apps)), title: title, meta: "\(table.apps.count) apps",
                  lines: top.map { app in
                      SoftCard.Line(label: app.name, fraction: value(app) / peak, color: color, figure: figure(app),
                                    detail: sum > 0 ? Format.percent(value(app) / sum) : "",
                                    hover: app.processCount == 1 ? "1 process" : "\(app.processCount) processes",
                                    icon: Icons.icon(for: app))
                  })
    }
}

// MARK: - Pieces

extension SoftDropdown {
    /// The colours and type of the soft style.
    enum Look {
        // Sampled off the reference at 2x: a cool grey panel over the blur, a warm
        // off-white section, white cards with a soft shadow, and ink in three strengths.
        static let panel = Theme.dynamic(0xE9ECF1, 0x1E1E22)
        /// The tint over the blur: strong enough that a dark window behind still reads
        /// as the reference's light panel.
        static let panelWash = A2.dynamic(Theme.hex(0xEBEEF3, alpha: 0.72), Theme.hex(0x1E1E22, alpha: 0.7))
        static let panelLine = A2.dynamic(NSColor(white: 0, alpha: 0.04), NSColor(white: 0, alpha: 0.2))
        static let panelRim = A2.dynamic(NSColor(white: 1, alpha: 0.4), NSColor(white: 1, alpha: 0.045))
        static let section = Theme.dynamic(0xFAF9F7, 0x27272B)
        static let sectionLine = A2.dynamic(NSColor(white: 0, alpha: 0.05), NSColor(white: 1, alpha: 0.05))
        static let sectionRim = A2.dynamic(NSColor(white: 1, alpha: 0.8), NSColor(white: 1, alpha: 0.03))
        static let card = Theme.dynamic(0xFFFFFF, 0x323236)
        static let cardLine = A2.dynamic(NSColor(white: 0, alpha: 0.095), NSColor(white: 1, alpha: 0.08))
        static let cardShadow = A2.dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 0, alpha: 0.3))
        /// Under a card picked up to move.
        static let liftShadow = A2.dynamic(NSColor(white: 0, alpha: 0.16), NSColor(white: 0, alpha: 0.5))
        static let primary = A2.dynamic(NSColor(white: 0, alpha: 0.97), NSColor(white: 1, alpha: 0.96))
        static let heading = A2.dynamic(NSColor(white: 0, alpha: 0.83), NSColor(white: 1, alpha: 0.85))
        static let secondary = A2.dynamic(NSColor(white: 0, alpha: 0.63), NSColor(white: 1, alpha: 0.6))
        // Measured as whole lines (height and width together): 13 points for everything
        // but the titles, semibold and about 14.5 and 15.5, all at AppKit's own spacing.
        // Shown at `scale` those are 11, 12 and 13 points; the titles are sized from what
        // they show at so every size on screen is whole.
        static let body = Theme.sans(13)
        static let strong = Theme.sans(13, .medium)
        static let sectionFont = Theme.sans(13, .semibold)
        static let title = Theme.sans(12 / SoftDropdown.scale, .semibold)
        static let appTitle = Theme.sans(13 / SoftDropdown.scale, .semibold)
        static let figure = Theme.digits(13, .medium)
        static let track = A2.dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.1))
        static let tag = A2.dynamic(NSColor(white: 0, alpha: 0.05), NSColor(white: 1, alpha: 0.08))
        static let buttonHover = Theme.dynamic(0xF4F4F7, 0x3A3A40)

        static func text(_ text: String, x: CGFloat, mid: CGFloat, width: CGFloat, font: NSFont, color: NSColor, right: Bool = false) {
            A2Dev.text(text, x: x, mid: mid, width: width, font: font, color: color, right: right)
        }

        static func width(_ text: String, _ font: NSFont) -> CGFloat { A2Dev.width(text, font) }

        /// The reference's strokes are thinner than AppKit draws them: without font
        /// smoothing, which thickens every stem by about a tenth of a point.
        static func thin() { NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false) }

        /// A rounded rectangle with continuous corners, as the window's own are.
        static func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
            NSBezierPath(cgPath: CGPath.continuous(rect, radius: radius))
        }
    }

    /// The panel itself, drawn with the same continuous corners as the blur's mask so
    /// the two meet exactly: the tint, a hairline outside and a light rim just inside.
    final class Face: BitmapView {
        var solid = false { didSet { needsDisplay = true } }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Below its corners the panel is the same all the way down. A continuous corner
        /// curves over about 1.3 times its radius.
        override var stretchCaps: (top: CGFloat, bottom: CGFloat)? {
            let cap = SoftDropdown.panelRadius * 1.5 + 2
            return (cap, cap)
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius = SoftDropdown.panelRadius
            (solid ? Look.panel : Look.panelWash).setFill()
            Look.rounded(bounds, radius: radius).fill()
            Look.panelLine.setStroke()
            Look.rounded(bounds.insetBy(dx: 0.25, dy: 0.25), radius: radius - 0.25).stroke(width: 0.5)
            Look.panelRim.setStroke()
            Look.rounded(bounds.insetBy(dx: 0.75, dy: 0.75), radius: radius - 0.75).stroke(width: 0.5)
        }
    }

    /// The panel's shadow, drawn in the room around it: a wide soft falloff and a short
    /// close one, with no line at the edge. The panel's own area is left clear so the
    /// blur behind it is untouched.
    final class Shadow: BitmapView {
        var margin: CGFloat = 28 { didSet { needsDisplay = true } }
        private static let far = A2.dynamic(NSColor(white: 0, alpha: 0.16), NSColor(white: 0, alpha: 0.45))
        private static let near = A2.dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 0, alpha: 0.3))

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Clear of the corners and of the far shadow's blur and drop, the sides fall off
        /// the same way on every row.
        override var stretchCaps: (top: CGFloat, bottom: CGFloat)? {
            let cap = margin + SoftDropdown.panelRadius * 1.5 + 22 * 2 + 9
            return (cap, cap)
        }

        override func draw(_ dirtyRect: NSRect) {
            let panel = bounds.insetBy(dx: margin, dy: margin)
            let shape = Look.rounded(panel, radius: SoftDropdown.panelRadius)
            // Flipped: a negative height falls downwards on screen.
            for (color, blur, drop) in [(Self.far, CGFloat(22), CGFloat(-9)), (Self.near, CGFloat(3), CGFloat(-1))] {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = color
                shadow.shadowBlurRadius = blur
                shadow.shadowOffset = NSSize(width: 0, height: drop)
                shadow.set()
                NSColor.black.setFill()
                shape.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            shape.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }

    /// Everything that sits behind the live views and only changes with the layout: the
    /// section with its heading and count, each card's plate and shadow, and the footer
    /// note. One bitmap, so the shadows cost nothing to composite.
    final class Plate: BitmapView {
        var section = NSRect.zero { didSet { if section != oldValue { needsDisplay = true } } }
        /// Card shapes the plate draws itself: only the empty card's. A SoftCard draws its own,
        /// so it can move when dragged.
        var cards: [NSRect] = [] { didSet { if cards != oldValue { needsDisplay = true } } }
        var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
        var count = "" { didSet { if count != oldValue { needsDisplay = true } } }
        var footer = "" { didSet { if footer != oldValue { needsDisplay = true } } }
        var footerRight: CGFloat = 0 { didSet { if footerRight != oldValue { needsDisplay = true } } }

        /// Between the heading and the section's bottom corners the plate is the section's
        /// sides on every row, unless it draws an empty card there.
        override var stretchCaps: (top: CGFloat, bottom: CGFloat)? {
            guard cards.isEmpty, section.height > 0 else { return nil }
            let corner = SoftDropdown.sectionRadius * 1.5 + 2
            return (section.minY + SoftDropdown.sectionTitle + corner, bounds.height - section.maxY + corner)
        }

        override func draw(_ dirtyRect: NSRect) {
            Look.thin()
            guard section.height > 0 else { return }
            let radius = SoftDropdown.sectionRadius
            Look.section.setFill()
            Look.rounded(section, radius: radius).fill()
            Look.sectionLine.setStroke()
            Look.rounded(section.insetBy(dx: 0.25, dy: 0.25), radius: radius - 0.25).stroke(width: 0.5)
            Look.sectionRim.setStroke()
            Look.rounded(section.insetBy(dx: 0.75, dy: 0.75), radius: radius - 0.75).stroke(width: 0.5)

            let mid = section.minY + SoftDropdown.sectionTitle / 2 + 1
            let left = section.minX + SoftDropdown.padX + 1
            Look.text(title, x: left, mid: mid, width: 160, font: Look.sectionFont, color: Look.heading)
            if !count.isEmpty {
                let width: CGFloat = 200
                Look.text(count, x: section.maxX - SoftDropdown.padX - 1 - width, mid: mid, width: width, font: Look.body, color: Look.secondary, right: true)
            }

            let cardRadius = SoftDropdown.cardRadius
            for rect in cards {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = Look.cardShadow
                shadow.shadowBlurRadius = 6
                // Flipped: a negative height falls downwards on screen.
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.set()
                Look.card.setFill()
                Look.rounded(rect, radius: cardRadius).fill()
                NSGraphicsContext.restoreGraphicsState()
                Look.cardLine.setStroke()
                Look.rounded(rect.insetBy(dx: 0.25, dy: 0.25), radius: cardRadius - 0.25).stroke(width: 0.5)
            }

            if !footer.isEmpty {
                let footerMid = section.maxY + SoftDropdown.footerHeight / 2 - SoftDropdown.footerLift
                let x = section.minX + 8
                Look.text(footer, x: x, mid: footerMid, width: max(0, footerRight - x), font: Look.body, color: Look.secondary)
            }
        }
    }

    /// Wisp's icon, the title and the status line with its dot.
    final class Head: BitmapView {
        struct Status: Equatable {
            var dot: NSColor
            /// Longest first; the first that fits is shown.
            var lines: [String]
        }

        var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
        var status = Status(dot: A2Dev.quiet, lines: [""]) { didSet { if status != oldValue { needsDisplay = true } } }
        var textRight: CGFloat = 300 { didSet { if textRight != oldValue { needsDisplay = true } } }

        override func draw(_ dirtyRect: NSRect) {
            Look.thin()
            // The icon's squircle fills about 80% of its canvas; size it so the squircle is 28 points.
            let squircle: CGFloat = 28, canvas = (squircle / 0.805).rounded()
            let iconMid = NSPoint(x: 16 + squircle / 2, y: bounds.height / 2 + 1)
            NSApp.applicationIconImage?.draw(in: NSRect(x: iconMid.x - canvas / 2, y: iconMid.y - canvas / 2, width: canvas, height: canvas),
                                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let left: CGFloat = 16 + squircle + 10
            let width = max(0, textRight - left)
            Look.text(title, x: left, mid: iconMid.y - 9, width: width, font: Look.appTitle, color: Look.primary)

            let dot: CGFloat = 7
            let lineMid = iconMid.y + 9.5
            status.dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: left + 0.5, y: lineMid - dot / 2, width: dot, height: dot)).fill()
            let textLeft = left + dot + 5
            let room = width - dot - 5
            let line = status.lines.first { Look.width($0, Look.body) <= room } ?? status.lines.last ?? ""
            Look.text(line, x: textLeft, mid: lineMid, width: room, font: Look.body, color: Look.secondary)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityValue() -> Any? { title + ", " + (status.lines.first ?? "") }
    }

    /// A white circle with a hairline and a symbol, for the header's actions.
    final class RoundButton: NSButton {
        private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
        private let symbolImage: NSImage?

        init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
            symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            super.init(frame: .zero)
            self.target = target
            self.action = action
            isBordered = false
            title = ""
            toolTip = label
            setAccessibilityLabel(label)
            // An image-only button's cell is what VoiceOver reads; without this it is
            // a nameless button with only a tooltip.
            cell?.setAccessibilityLabel(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func draw(_ dirtyRect: NSRect) {
            let circle = bounds.insetBy(dx: 1, dy: 1)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = Look.cardShadow
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            (isHighlighted || hovering ? Look.buttonHover : Look.card).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.restoreGraphicsState()
            Look.cardLine.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            guard let symbolImage else { return }
            let size = symbolImage.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                symbolImage.draw(in: rect)
                Look.primary.withAlphaComponent(0.85).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// A text link with an arrow, for the footer.
    final class LinkButton: NSButton {
        private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
        private static let font = Look.strong
        private let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

        init(title: String, target: AnyObject?, action: Selector?) {
            super.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
            isBordered = false
            setAccessibilityLabel(title)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize {
            NSSize(width: ceil(Look.width(title, Self.font)) + 6 + (arrow?.size.width ?? 0) + 2, height: 22)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func draw(_ dirtyRect: NSRect) {
            Look.thin()
            let color = isHighlighted || hovering ? Look.secondary : Look.heading
            let textWidth = ceil(Look.width(title, Self.font))
            Look.text(title, x: 0, mid: bounds.midY, width: textWidth + 1, font: Self.font, color: color)
            guard let arrow else { return }
            // Nudged right while hovered, as a link that leads somewhere.
            let x = textWidth + 6 + (hovering ? 2 : 0)
            let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                arrow.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: ((bounds.height - arrow.size.height) / 2).rounded(), width: arrow.size.width, height: arrow.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// One card of a soft dropdown, laid out as the reference's cards are: a mark, a title,
/// a quiet line that can show more on hover, and a tag on the first line; then optionally
/// a note, a line per reading (a label in a column, a slim bar, a figure and a detail
/// that changes on hover), and a chart along the bottom edge.
@MainActor
final class SoftCard: BitmapView {
    typealias Look = SoftDropdown.Look

    enum Mark: Equatable {
        /// A coding agent's mark (its app icon, or its glyph).
        case agent(String)
        /// A symbol on a quiet tile.
        case glyph(String, NSColor)
    }

    struct Line: Equatable {
        var label: String
        var fraction: Double
        var color: NSColor
        var figure: String
        var detail: String
        /// Shown in place of `detail` while the line is hovered.
        var hover: String?
        /// The hover text is a warning ("Runs out in 2h").
        var warns = false
        /// An icon before the label, such as an app's.
        var icon: NSImage?
        /// Where even use would have the bar by now, 0 to 1: a plan limit's pace mark.
        var pace: Double?
        /// Before the first reading: the line's shape in a quiet fill where its figure (and,
        /// without a label, its icon and name) will go.
        var ghost = false

        static func == (a: Line, b: Line) -> Bool {
            a.label == b.label && a.fraction == b.fraction && a.color == b.color && a.figure == b.figure && a.detail == b.detail
                && a.hover == b.hover && a.warns == b.warns && a.icon === b.icon && a.pace == b.pace && a.ghost == b.ghost
        }

        /// A line waiting for its first reading.
        static func waiting(_ label: String = "") -> Line {
            var line = Line(label: label, fraction: 0, color: .clear, figure: "", detail: "")
            line.ghost = true
            return line
        }
    }

    /// Clicking a line, when set; the line under the pointer is the argument.
    var onClick: ((Int) -> Void)?
    /// The dropdown, while this card can be dragged into another place.
    weak var dragHost: SoftDropdown?
    /// What the card stands for when its place is saved, such as an account's id.
    var dragID = ""
    private var pressedAt: NSPoint?
    private var dragging = false
    /// Picked up: a deeper shadow while it moves.
    var lifted = false {
        didSet {
            guard lifted != oldValue else { return }
            if lifted { hoverLine = nil }
            layer?.zPosition = lifted ? 1 : 0
            applyShadow(animated: true)
        }
    }
    /// What each line stands for, such as an app's id, for `onClick`.
    var ids: [String] = []
    private static let iconSize: CGFloat = 16
    private static let iconGap: CGFloat = 6

    private var mark = Mark.glyph("circle", A2.secondary)
    private var title = ""
    private var pill: String?
    private var note: String?
    private(set) var lines: [Line] = []
    /// The quiet text on the first line, and what it shows while hovered.
    private let meta = MarqueeLabel()
    /// A chart along the bottom edge, below any lines.
    var chart: TimeChart? {
        didSet {
            oldValue?.removeFromSuperview()
            if let chart { addSubview(chart) }
            needsLayout = true
        }
    }
    /// A drawn graphic along the bottom edge in place of a chart, such as a limit's pace.
    var graphic: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let graphic { addSubview(graphic) }
            needsLayout = true
        }
    }
    var chartHeight: CGFloat = 110
    /// Stays where it is, above the cards that can be dragged.
    var fixed = false

    /// The shape a chart along the bottom is cut to: the card's own corners, just inside
    /// its hairline.
    static func chartClip(_ rect: CGRect) -> CGPath {
        let reach = SoftDropdown.cardRadius * 3
        return CGPath.continuous(CGRect(x: rect.minX + 0.5, y: rect.minY - reach, width: rect.width - 1, height: rect.height + reach - 0.5),
                                 radius: SoftDropdown.cardRadius - 0.5)
    }

    private var hoverLine: Int? {
        didSet {
            guard hoverLine != oldValue else { return }
            crossfade()
            needsDisplay = true
            showMeta()
        }
    }
    /// The first line's quiet text as given, before a hover takes its place.
    private var metaText = ""
    private var metaHover: String?

    /// The hovered line's text, where it fits: in place of the line's detail, or else in
    /// the quiet spot on the first line, so the details never need room for it.
    private func hoverText(_ index: Int?) -> (inline: String?, aside: String?) {
        guard let index, lines.indices.contains(index), let hover = lines[index].hover else { return (nil, nil) }
        let room = widths.detail
        let fitted = PlanCard.fitted(hover, room: room, font: Look.body)
        return room > 0 && Look.width(fitted, Look.body) <= room + 0.5 ? (fitted, nil) : (nil, hover)
    }

    private func showMeta() {
        let aside = hoverText(hoverLine).aside
        if meta.text != aside ?? metaText { meta.crossfade() }
        meta.text = aside ?? metaText
        meta.hoverText = aside == nil ? metaHover : nil
    }

    static let padX: CGFloat = 12
    private static let titleMid: CGFloat = 23
    private static let firstLine: CGFloat = 53
    private static let pitch: CGFloat = 21.5
    private static let bottom: CGFloat = 17.5
    private static let barHeight: CGFloat = 6
    /// Where the bars start: set by the dropdown, the same in every card so they line up.
    var column: CGFloat = 66 { didSet { if column != oldValue { needsDisplay = true } } }
    var labelWidth: CGFloat {
        ceil(lines.map { Look.width($0.label, Look.body) + ($0.icon == nil ? 0 : Self.iconSize + Self.iconGap) }.max() ?? 0)
    }
    var figureWidth: CGFloat { ceil(lines.map { Look.width($0.figure, Look.figure) }.max() ?? 0) }

    /// Where the bars start for labels this wide. Long app names end in "…" rather than
    /// pushing every bar to the right.
    static func column(labels: CGFloat) -> CGFloat { min(150, max(66, labels + 16)) }

    /// The card lists apps, with their icons.
    var listsApps: Bool { lines.contains { $0.icon != nil } }
    /// The figure column this card's lines need.
    var figureNeed: CGFloat { max(figureWidth, ceil(Look.width("100%", Look.figure))) }
    /// The room this card's details need, none when no line has one. Hover text that
    /// would not fit there shows on the first line instead (see `hoverText`).
    var detailNeed: CGFloat {
        guard lines.contains(where: { !$0.detail.isEmpty }) else { return 0 }
        return min(110, ceil(lines.map { Look.width($0.detail, Look.body) }.max() ?? 0))
    }
    /// The figure and detail columns the dropdown gives every card with details.
    var shared: (figure: CGFloat, detail: CGFloat) = (0, 0) {
        didSet { if shared != oldValue { needsDisplay = true } }
    }

    /// The figure column, the detail column and the bar length that fills what is left,
    /// so a card never ends in empty space.
    private var widths: (bar: CGFloat, figure: CGFloat, detail: CGFloat) {
        let figure = max(figureNeed, shared.figure)
        let detail = detailNeed > 0 ? max(detailNeed, shared.detail) : 0
        let bar = bounds.width - Self.padX * 2 - column - 8 - figure - (detail > 0 ? 16 + detail : 0)
        return (max(52, bar.rounded(.down)), figure, detail)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        meta.font = Look.body
        meta.color = Look.secondary
        meta.smoothsFonts = false
        addSubview(meta)
    }

    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat {
        let count = lines.count + (note == nil ? 0 : 1)
        var height = count == 0 ? 46 : Self.firstLine + CGFloat(count - 1) * Self.pitch + Self.bottom
        if chart != nil || graphic != nil { height = (count == 0 ? 40 : height - 6) + chartHeight }
        return height
    }

    func show(mark: Mark, title: String, meta: String, metaHover: String? = nil, tag: String? = nil, note: String? = nil, lines: [Line]) {
        let changed = mark != self.mark || title != self.title || tag != self.pill || note != self.note || lines != self.lines
        self.mark = mark
        self.title = title
        self.pill = tag
        self.note = note
        self.lines = lines
        metaText = meta
        self.metaHover = metaHover
        showMeta()
        if changed {
            needsDisplay = true
            needsLayout = true
        }
    }

    private var tagWidth: CGFloat { pill.map { ceil(Look.width($0, Look.strong)) + 18 } ?? 0 }

    /// Where a card this wide draws a tag reading `text`, so a view can sit over it.
    static func tagRect(_ text: String, in bounds: NSRect) -> NSRect {
        let width = ceil(Look.width(text, Look.strong)) + 18
        return NSRect(x: bounds.width - padX - width, y: titleMid - 11, width: width, height: 22)
    }
    private var titleLeft: CGFloat { Self.padX + 20 + 9 }
    /// Where the first line's text ends: before the tag, if there is one.
    private var tail: CGFloat { bounds.width - Self.padX - (pill == nil ? 0 : tagWidth + 10) }
    private var titleWidth: CGFloat { min(ceil(Look.width(title, Look.title)), (tail - titleLeft) * 0.6) }

    override func layout() {
        super.layout()
        applyShadow(animated: false)
        let left = titleLeft + titleWidth + 12
        meta.frame = NSRect(x: left, y: Self.titleMid - 12, width: max(0, tail - left), height: 24)
        chart?.frame = NSRect(x: 0, y: bounds.height - chartHeight, width: bounds.width, height: chartHeight)
        graphic?.frame = NSRect(x: 0, y: bounds.height - chartHeight, width: bounds.width, height: chartHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadow(animated: false)
    }

    /// The shadow is the layer's, outside the bitmap, so the card can move without the
    /// plate under it drawing again. In points of the dropdown's scaled bounds: the plate
    /// used to draw it 6 pixels soft and 2 down.
    private func applyShadow(animated: Bool) {
        guard let layer else { return }
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (lifted ? Look.liftShadow : Look.cardShadow).cgColor
        }
        let radius: CGFloat = lifted ? 10 : 1.8
        let offset = CGSize(width: 0, height: lifted ? 6 : 1.4)
        if animated {
            for (key, from, to) in [("shadowColor", layer.shadowColor as Any?, color as Any?), ("shadowRadius", layer.shadowRadius as Any?, radius as Any?),
                                    ("shadowOffset", NSValue(size: layer.shadowOffset) as Any?, NSValue(size: offset) as Any?)] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: key)
            }
        }
        layer.shadowColor = color
        layer.shadowOpacity = 1
        layer.shadowRadius = radius
        layer.shadowOffset = offset
        layer.shadowPath = CGPath.continuous(bounds, radius: SoftDropdown.cardRadius)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Look.thin()
        let cardRadius = SoftDropdown.cardRadius
        Look.card.setFill()
        Look.rounded(bounds, radius: cardRadius).fill()
        Look.cardLine.setStroke()
        Look.rounded(bounds.insetBy(dx: 0.25, dy: 0.25), radius: cardRadius - 0.25).stroke(width: 0.5)
        let right = bounds.width - Self.padX
        let mid = Self.titleMid
        let markRect = NSRect(x: Self.padX, y: mid - 10, width: 20, height: 20)
        switch mark {
        case .agent(let provider):
            let look = AgentLook.mark(provider, size: 20, appearance: effectiveAppearance)
            if let icon = look.icon {
                icon.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                A2Dev.drawGlyphTile(look.glyph, tint: look.tint, in: markRect, appearance: effectiveAppearance)
            }
        case .glyph(let symbol, let tint):
            A2Dev.drawGlyphTile(symbol, tint: tint, in: markRect, appearance: effectiveAppearance)
        }
        if let pill {
            let rect = NSRect(x: right - tagWidth, y: mid - 11, width: tagWidth, height: 22)
            Look.tag.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
            Look.text(pill, x: rect.minX + 9, mid: mid, width: tagWidth, font: Look.strong, color: Look.heading)
        }
        Look.text(title, x: titleLeft, mid: mid, width: titleWidth + 1, font: Look.title, color: Look.primary)

        var y = Self.firstLine
        if let note {
            Look.text(note, x: Self.padX, mid: y, width: right - Self.padX, font: Look.body, color: A2.warn)
            y += Self.pitch
        }
        let column = Self.padX + self.column
        let (barWidth, figureColumn, detailColumn) = widths
        for (index, line) in lines.enumerated() {
            if line.ghost {
                drawGhost(line, index: index, mid: y, column: column, bar: barWidth, figure: figureColumn)
                y += Self.pitch
                continue
            }
            var labelLeft = Self.padX
            if let icon = line.icon {
                icon.draw(in: NSRect(x: labelLeft, y: (y - Self.iconSize / 2).rounded(), width: Self.iconSize, height: Self.iconSize),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                labelLeft += Self.iconSize + Self.iconGap
            }
            Look.text(line.label, x: labelLeft, mid: y, width: column - labelLeft - 8, font: Look.body, color: Look.secondary)
            let bar = NSRect(x: column, y: (y - Self.barHeight / 2).rounded(), width: barWidth, height: Self.barHeight)
            let radius = Self.barHeight / 2
            Look.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
            let fraction = CGFloat(min(1, max(0, line.fraction)))
            if fraction > 0 {
                line.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(Self.barHeight, bar.width * fraction), height: bar.height),
                             xRadius: radius, yRadius: radius).fill()
            }
            // Where even use would be by now: a bar past it runs out before the reset.
            if let pace = line.pace, pace > 0.01, pace < 0.99 {
                let x = (bar.minX + bar.width * CGFloat(pace)).rounded()
                Look.secondary.setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: bar.midY - 5, width: 1.5, height: 10), xRadius: 0.75, yRadius: 0.75).fill()
            }
            // Right-aligned in the card's figure column, so the details line up down the card.
            let figureLeft = bar.maxX + 8
            Look.text(line.figure, x: figureLeft, mid: y, width: figureColumn + 1, font: Look.figure, color: Look.primary, right: true)
            let inline = hoverLine == index ? hoverText(index).inline : nil
            let hovered = inline != nil
            let detail = inline ?? line.detail
            if !detail.isEmpty, detailColumn > 0 {
                let dot = figureLeft + figureColumn + 6
                Look.text("·", x: dot, mid: y, width: 8, font: Look.body, color: Look.secondary)
                let left = dot + 10
                let room = right - left
                Look.text(PlanCard.fitted(detail, room: room, font: Look.body), x: left, mid: y, width: room, font: Look.body,
                          color: line.warns && hovered ? A2.warn : Look.secondary)
            }
            y += Self.pitch
        }
    }

    /// A line before its first reading, in the same columns as the real one: the label (or
    /// an icon and a name of varying length), an empty track and a figure.
    private func drawGhost(_ line: Line, index: Int, mid y: CGFloat, column: CGFloat, bar: CGFloat, figure: CGFloat) {
        let fill = Look.track
        if line.label.isEmpty {
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: Self.padX, y: (y - Self.iconSize / 2).rounded(), width: Self.iconSize, height: Self.iconSize),
                         xRadius: 4, yRadius: 4).fill()
            let room = column - Self.padX - Self.iconSize - Self.iconGap - 12
            let width = max(24, room * [0.8, 0.55, 0.7, 0.45, 0.62][index % 5])
            NSBezierPath(roundedRect: NSRect(x: Self.padX + Self.iconSize + Self.iconGap, y: y - 4.5, width: width, height: 9),
                         xRadius: 4.5, yRadius: 4.5).fill()
        } else {
            Look.text(line.label, x: Self.padX, mid: y, width: column - Self.padX - 8, font: Look.body, color: Look.secondary)
        }
        let track = NSRect(x: column, y: (y - Self.barHeight / 2).rounded(), width: bar, height: Self.barHeight)
        fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: Self.barHeight / 2, yRadius: Self.barHeight / 2).fill()
        let width = min(figure, 34)
        NSBezierPath(roundedRect: NSRect(x: track.maxX + 8 + figure - width, y: y - 4.5, width: width, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { track(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { track(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverLine = nil }

    /// The dropdown is a panel that is rarely key; the first press should already pick a card up.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { dragHost != nil || onClick != nil }

    override func mouseDown(with event: NSEvent) {
        pressedAt = dragHost == nil ? nil : event.locationInWindow
        if onClick == nil, pressedAt == nil { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host = dragHost, let start = pressedAt else { return super.mouseDragged(with: event) }
        if !dragging {
            let moved = event.locationInWindow
            guard hypot(moved.x - start.x, moved.y - start.y) >= 3 else { return }
            dragging = true
            host.beginDrag(self, event: event)
        }
        host.moveDrag(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
        if dragging {
            dragging = false
            dragHost?.endDrag(self)
            return
        }
        guard let onClick else { return super.mouseUp(with: event) }
        track(convert(event.locationInWindow, from: nil))
        if let hoverLine { onClick(hoverLine) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverLine = nil }
    }

    private func track(_ point: NSPoint) {
        let first = Self.firstLine + (note == nil ? 0 : Self.pitch)
        let index = Int(((point.y - first + Self.pitch / 2) / Self.pitch).rounded(.down))
        hoverLine = point.y >= first - Self.pitch / 2 && lines.indices.contains(index) ? index : nil
    }

    // MARK: Accessibility

    /// A line in words, with what its hover, its warning colour and its pace mark show.
    private static func spoken(_ line: Line, named: Bool = true) -> String {
        guard !line.ghost else { return [named ? line.label : "", "waiting for the first reading"].filter { !$0.isEmpty }.joined(separator: ", ") }
        var words = [(named ? line.label + " " : "") + line.figure, line.detail]
        if let hover = line.hover, hover != line.detail { words.append(line.warns ? "warning: " + hover : hover) }
        if let pace = line.pace, pace > 0.01, pace < 0.99 { words.append("even pace would be " + Format.percent(pace)) }
        return words.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
    }

    // Clickable lines are buttons of their own; the AppKit calls arrive on the main thread.
    private final class LineElement: NSAccessibilityElement {
        weak var owner: SoftCard?
        var index = 0
        override func accessibilityPerformPress() -> Bool {
            MainActor.assumeIsolated {
                guard let owner, let onClick = owner.onClick, owner.lines.indices.contains(index) else { return false }
                onClick(index)
                return true
            }
        }
        override func accessibilityFrameInParentSpace() -> NSRect {
            MainActor.assumeIsolated {
                guard let owner else { return .zero }
                let first = SoftCard.firstLine + (owner.note == nil ? 0 : SoftCard.pitch)
                let top = first - SoftCard.pitch / 2 + CGFloat(index) * SoftCard.pitch
                return NSRect(x: 0, y: owner.bounds.height - top - SoftCard.pitch, width: owner.bounds.width, height: SoftCard.pitch)
            }
        }
    }
    private var lineElements: [LineElement] = []

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick == nil ? .staticText : .group }
    override func accessibilityLabel() -> String? { onClick == nil ? nil : title }
    override func accessibilityValue() -> Any? {
        var parts: [String] = onClick == nil ? [title] : []
        parts += [pill ?? "", meta.hoverText ?? meta.text, note ?? ""]
        if onClick == nil { parts += lines.map { Self.spoken($0) } }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    // A card that can be dragged into another place can be moved from VoiceOver too.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard dragHost != nil else { return nil }
        return [("Move Up", -1), ("Move Down", 1)].map { name, offset in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, let host = self.dragHost else { return false }
                return host.move(self, by: offset)
            }
        }
    }
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard onClick != nil else { return children }
        let shown = lines.indices.filter { !lines[$0].ghost }
        while lineElements.count < shown.count {
            let element = LineElement()
            element.owner = self
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            lineElements.append(element)
        }
        for (slot, index) in shown.enumerated() {
            let element = lineElements[slot]
            element.index = index
            element.setAccessibilityLabel(lines[index].label)
            element.setAccessibilityValue(Self.spoken(lines[index], named: false))
            children.append(element)
        }
        return children
    }
}

extension NSBezierPath {
    func stroke(width: CGFloat) {
        lineWidth = width
        stroke()
    }
}

extension CGPath {
    /// A rounded rectangle whose corners ease into the sides, like the system's
    /// continuous corners, rather than meeting them at a circle's tangent.
    static func continuous(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        // The curve starts further along each side than a circle would; 1.28 is close to
        // Core Animation's continuous curve at this size.
        let reach = min(r * 1.28, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: minX + reach, y: minY))
        path.addLine(to: CGPoint(x: maxX - reach, y: minY))
        path.addCurve(to: CGPoint(x: maxX, y: minY + reach), control1: CGPoint(x: maxX - reach + r * 0.83, y: minY),
                      control2: CGPoint(x: maxX, y: minY + reach - r * 0.83))
        path.addLine(to: CGPoint(x: maxX, y: maxY - reach))
        path.addCurve(to: CGPoint(x: maxX - reach, y: maxY), control1: CGPoint(x: maxX, y: maxY - reach + r * 0.83),
                      control2: CGPoint(x: maxX - reach + r * 0.83, y: maxY))
        path.addLine(to: CGPoint(x: minX + reach, y: maxY))
        path.addCurve(to: CGPoint(x: minX, y: maxY - reach), control1: CGPoint(x: minX + reach - r * 0.83, y: maxY),
                      control2: CGPoint(x: minX, y: maxY - reach + r * 0.83))
        path.addLine(to: CGPoint(x: minX, y: minY + reach))
        path.addCurve(to: CGPoint(x: minX + reach, y: minY), control1: CGPoint(x: minX, y: minY + reach - r * 0.83),
                      control2: CGPoint(x: minX + reach - r * 0.83, y: minY))
        path.closeSubpath()
        return path
    }
}
