import AppKit
import WispCore

/// A capsule button on Liquid Glass. The glass is the system's; the label is ours,
/// so the button reads the same whether or not Wisp is the active app (system glass
/// controls go flat in inactive windows, and a monitor is mostly looked at from
/// another app). Before macOS 26 it is a plain capsule.
@MainActor
final class GlassPill: NSView {
    enum Kind { case plain, primary, destructive }

    var onPress: (() -> Void)?
    private let kind: Kind
    private let label = TextLine()
    private let glyph = NSImageView()
    private let surface: NSView
    private let title: String
    private let symbol: String?

    init(_ title: String, symbol: String? = nil, kind: Kind = .plain) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        // The main action is solid: tinted glass turns grey whenever Wisp is not the active app.
        if #available(macOS 26.0, *), !Theme.solidPanels, kind != .primary {
            let glass = NSGlassEffectView()
            glass.style = .regular
            surface = glass
        } else {
            let card = CardView()
            card.fill = kind == .primary ? Theme.accent : Theme.card
            card.stroke = kind == .primary ? .clear : Theme.cardBorder
            surface = card
        }
        super.init(frame: .zero)
        addSubview(surface)
        let color: NSColor = kind == .primary ? .white : kind == .destructive ? Theme.bad : Theme.ink
        label.text = NSAttributedString(string: title, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: color])
        label.alignment = .center
        if let symbol {
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? symbol : nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            glyph.contentTintColor = color
        }
        addSubview(glyph)
        addSubview(label)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? symbol : title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        surface.frame = bounds
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        } else if let card = surface as? CardView {
            card.radius = bounds.height / 2
        }
        let textWidth = title.isEmpty ? 0 : label.naturalWidth
        let iconWidth: CGFloat = symbol == nil ? 0 : 16
        let gap: CGFloat = textWidth > 0 && iconWidth > 0 ? 6 : 0
        let x = (bounds.width - textWidth - iconWidth - gap) / 2
        glyph.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: iconWidth, height: 16)
        label.frame = NSRect(x: x + iconWidth + gap, y: (bounds.height - 18) / 2, width: textWidth + 2, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { press(true) }

    override func mouseUp(with event: NSEvent) {
        press(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    /// A small squeeze while held, the way glass controls give under a finger.
    private func press(_ down: Bool) {
        guard let layer, !Theme.reduceMotion else { return }
        // Scale the contents about the centre; the view's own layer geometry stays AppKit's.
        let w = bounds.width / 2, h = bounds.height / 2
        var target = CATransform3DMakeTranslation(w, h, 0)
        if down { target = CATransform3DScale(target, 0.95, 0.95, 1) }
        target = CATransform3DTranslate(target, -w, -h, 0)
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        animation.toValue = target
        animation.duration = down ? 0.09 : 0.24
        animation.timingFunction = Motion.ease
        layer.sublayerTransform = target
        layer.add(animation, forKey: "press")
    }
}

/// A figure card in the Tahoe inspector: a coloured symbol and name, the figure,
/// and for the big ones a thin bar with a line under it. The small ones sit four
/// to a strip without a card of their own.
final class FigureTile: CardView {
    let figure = BigNumber()
    let meter = SplitBar()
    let note = TextLine()
    private let label = TextLine()
    private let tint: NSColor
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; note.isHidden = !showsMeter; needsLayout = true } }
    private let big: Bool

    init(_ name: String, symbol: String, tint: NSColor, big: Bool) {
        self.big = big
        self.tint = tint
        super.init()
        radius = 14
        if big {
            label.text = Theme.header(name, symbol: symbol, tint: tint)
        } else {
            let text = NSMutableAttributedString(attachment: {
                let attachment = NSTextAttachment()
                attachment.image = IconTile.glyph(symbol, tint: tint, size: 12, appearance: NSApp.effectiveAppearance)
                attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
                return attachment
            }())
            text.append(NSAttributedString(string: " " + name, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary]))
            label.text = text
            fill = .clear
            stroke = .clear
        }
        figure.font = Theme.figure(big ? 30 : 14)
        figure.unitFont = Theme.sans(big ? 15 : 12, .medium)
        meter.isHidden = true
        note.isHidden = true
        for view in [label, figure, meter, note] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The bar's share, 0 to 1, in the tile's colour.
    func setMeter(_ fraction: Double) { meter.parts = [(fraction, tint)] }

    override func layout() {
        super.layout()
        if big {
            let width = bounds.width - 28
            label.frame = NSRect(x: 14, y: 13, width: width, height: 20)
            figure.frame = NSRect(x: 14, y: 36, width: width, height: 38)
            if showsMeter {
                meter.frame = NSRect(x: 14, y: bounds.height - 36, width: width, height: 6)
                note.frame = NSRect(x: 14, y: bounds.height - 25, width: width, height: 15)
            }
        } else {
            let width = bounds.width - 20
            label.frame = NSRect(x: 10, y: 11, width: width, height: 15)
            figure.frame = NSRect(x: 10, y: 28, width: width, height: 22)
        }
    }
}

/// A white card split into equal columns by hairlines.
final class ColumnsCard: CardView {
    var columns = 4 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()
        stroke.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let width = bounds.width / CGFloat(columns)
        Theme.rule.setFill()
        for index in 1..<columns { NSRect(x: (CGFloat(index) * width).rounded(), y: 10, width: 0.5, height: bounds.height - 20).fill() }
    }

    override func layout() {
        super.layout()
        let width = bounds.width / CGFloat(columns)
        for (index, view) in subviews.enumerated() {
            view.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).integral
        }
    }
}

/// "Inside Google Chrome": the app's processes by what they do, as one stacked
/// bar and a row per part.
final class InsideCard: CardView {
    let title = TextLine()
    let headline = TextLine()
    let toggle = Segmented(["Memory", "CPU"])
    private let bar = StackBar()
    private var rows: [PartRow] = []
    private let footnote = TextLine()
    var parts: [AppBreakdown.Part] = []
    var appName = ""
    var isBrowser = false

    static let colors: [AppBreakdown.Kind: NSColor] = [
        .tabs: Theme.indigo, .gpu: Theme.pink, .main: Theme.orange, .extensions: Theme.green, .network: Theme.teal,
        .media: Theme.purple, .other: Theme.dynamic(0xD1D1D6, 0x48484A),
    ]
    static let symbols: [AppBreakdown.Kind: String] = [
        .tabs: "square.on.square", .gpu: "cube", .main: "macwindow", .extensions: "puzzlepiece.extension",
        .network: "globe", .media: "waveform", .other: "ellipsis.circle",
    ]

    override init() {
        super.init()
        radius = 14
        for view in [title, headline, toggle, bar, footnote] as [NSView] { addSubview(view) }
        toggle.onChange = { [weak self] _ in self?.refresh() }
        footnote.text = Theme.caption("Browsers do not say which tab each process draws, so tabs count together", size: 9)
    }

    required init?(coder: NSCoder) { fatalError() }

    var wantedHeight: CGFloat { 112 + CGFloat(parts.count) * 40 + (isBrowser ? 26 : 0) }

    func refresh() {
        let byCPU = toggle.selected == 1
        let total = parts.reduce(0.0) { $0 + (byCPU ? $1.cpu : Double($1.memory)) }
        let sorted = parts.sorted { byCPU ? $0.cpu > $1.cpu : $0.memory > $1.memory }
        title.text = NSAttributedString(string: "Inside \(appName)", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        if let top = sorted.first, total > 0 {
            let share = (byCPU ? top.cpu : Double(top.memory)) / total
            let what = byCPU ? "its CPU" : "its memory"
            func line(_ name: String) -> NSAttributedString {
                let text = NSMutableAttributedString(string: "\(name) use", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink])
                if top.processes == 1 && top.name != "Tabs" && top.name != "Extensions" { text.mutableString.append("s") }
                text.append(NSAttributedString(string: " \(Format.percent(share))", attributes: [.font: Theme.figure(15, .semibold), .foregroundColor: Self.colors[top.kind] ?? Theme.ink]))
                text.append(NSAttributedString(string: " of \(what)", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.ink]))
                return text
            }
            // A process named like com.apple.Virtualization.VirtualMachine shortens to its last part.
            let short = top.name.split(separator: ".").last.map(String.init) ?? top.name
            headline.variants = short == top.name ? [line(top.name)] : [line(top.name), line(short)]
        } else {
            headline.variants = [NSAttributedString(string: "Nothing measured yet", attributes: [.font: Theme.sans(15, .medium), .foregroundColor: Theme.inkSecondary])]
        }
        bar.segments = sorted.map { ((byCPU ? $0.cpu : Double($0.memory)) / max(total, 1e-9), Self.colors[$0.kind] ?? Theme.inkTertiary) }
        while rows.count < sorted.count {
            let row = PartRow()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= sorted.count
            guard index < sorted.count else { continue }
            let part = sorted[index]
            let value = byCPU ? part.cpu : Double(part.memory)
            row.set(name: part.name,
                    note: part.processes > 1 ? "\(part.processes) processes · \(byCPU ? Format.percent(part.cpu / Double(part.processes)) : Format.memory(part.memory / UInt64(part.processes))) each" : "",
                    share: total > 0 ? Format.percent(value / total) : "–",
                    value: byCPU ? Format.percent(part.cpu) : Format.memory(part.memory),
                    symbol: Self.symbols[part.kind] ?? "circle", tint: Self.colors[part.kind] ?? Theme.inkTertiary)
        }
        footnote.isHidden = !isBrowser
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 36
        title.frame = NSRect(x: 18, y: 18, width: width - 140, height: 18)
        let toggleWidth = toggle.naturalWidth
        toggle.frame = NSRect(x: 18 + width - toggleWidth, y: 14, width: toggleWidth, height: 26)
        headline.frame = NSRect(x: 18, y: 50, width: width, height: 22)
        bar.frame = NSRect(x: 18, y: 82, width: width, height: 10)
        var y: CGFloat = 104
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: 18, y: y, width: width, height: 40)
            y += 40
        }
        footnote.frame = NSRect(x: 18, y: y + 6, width: width, height: 14)
    }
}

/// Segments side by side with a small gap, each in its own colour.
final class StackBar: DrawnView {
    var segments: [(Double, NSColor)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 3
        let shown = segments.filter { $0.0 > 0.004 }
        let room = bounds.width - gap * CGFloat(max(0, shown.count - 1))
        var x: CGFloat = 0
        if shown.isEmpty {
            Theme.track.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            return
        }
        for (fraction, color) in shown {
            let width = max(3, room * CGFloat(fraction))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: bounds.height), xRadius: 3, yRadius: 3).fill()
            x += width + gap
        }
    }
}

final class PartRow: DrawnView, SelfAuditing {
    private var name = "", note = "", share = "", value = "", symbol = "circle"
    private var tint = Theme.accent

    func set(name: String, note: String, share: String, value: String, symbol: String, tint: NSColor) {
        guard (name, note, share, value, symbol) != (self.name, self.note, self.share, self.value, self.symbol) else { return }
        (self.name, self.note, self.share, self.value, self.symbol, self.tint) = (name, note, share, value, symbol, tint)
        needsDisplay = true
    }

    var showsRule = true

    private static let nameFont = Theme.sans(13)
    private var nameRoom: CGFloat { bounds.width - 18 - 84 - 44 }

    /// A reverse-DNS process name (com.apple.Virtualization.VirtualMachine) that does not
    /// fit shows only its last part.
    private func shownName(room: CGFloat) -> String {
        guard (name as NSString).size(withAttributes: [.font: Self.nameFont]).width > room,
              name.contains("."), let last = name.split(separator: ".").last else { return name }
        return String(last)
    }

    var auditFaults: [String] {
        let shown = shownName(room: nameRoom)
        let width = ceil((shown as NSString).size(withAttributes: [.font: Self.nameFont]).width)
        return width > nameRoom + 1 ? ["\(shown) needs \(Int(width)) pt, has \(Int(nameRoom))"] : []
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.height / 2 - 4, width: 8, height: 8)).fill()
        if showsRule {
            Theme.rule.setFill()
            NSRect(x: 18, y: bounds.height - 0.5, width: bounds.width - 18, height: 0.5).fill()
        }
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: Theme.figure(13, .semibold), .foregroundColor: Theme.ink]
        let shareAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Theme.inkSecondary]
        let valueWidth = ceil((value as NSString).size(withAttributes: valueAttributes).width)
        (value as NSString).draw(at: NSPoint(x: bounds.width - valueWidth, y: (bounds.height - 16) / 2), withAttributes: valueAttributes)
        let shareWidth = ceil((share as NSString).size(withAttributes: shareAttributes).width)
        (share as NSString).draw(at: NSPoint(x: bounds.width - 84 - shareWidth, y: (bounds.height - 15) / 2), withAttributes: shareAttributes)
        let room = bounds.width - 18 - 84 - 44
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let nameY: CGFloat = note.isEmpty ? (bounds.height - 17) / 2 : 4
        (shownName(room: room) as NSString).draw(with: NSRect(x: 18, y: nameY, width: room, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.sans(13), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
        if !note.isEmpty {
            (note as NSString).draw(with: NSRect(x: 18, y: 21, width: room, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary, .paragraphStyle: paragraph])
        }
    }
}

/// The drawer that slides in from the right when an app or process is selected:
/// what it uses now, what is inside it, its last hour and where it comes from.
@MainActor
final class AppDrawer: NSView {
    var onClose: (() -> Void)?
    private unowned let delegate: AppDelegate
    private(set) var selection: Selection?

    private let body = CardView()
    private let header = Content()
    private let icon = NSImageView()
    private let name = TextLine()
    private let kind = TextLine()
    private let close = GlassPill("", symbol: "xmark")
    private let rule = CardView()
    private let scroll = NSScrollView()
    private let content = Content()

    private let memory = FigureTile("Memory", symbol: "memorychip", tint: PageID.memory.tint, big: true)
    private let cpu = FigureTile("CPU", symbol: "cpu", tint: PageID.cpu.tint, big: true)
    private let power = FigureTile("Power", symbol: "bolt.fill", tint: PageID.energy.tint, big: false)
    private let gpu = FigureTile("GPU", symbol: "cube.fill", tint: PageID.gpu.tint, big: false)
    private let disk = FigureTile("Disk", symbol: "internaldrive", tint: PageID.disk.tint, big: false)
    private let network = FigureTile("Network", symbol: "globe", tint: PageID.network.tint, big: false)
    private let strip = ColumnsCard()
    private let inside = InsideCard()
    private let historyCard = CardView()
    private let historyTitle = TextLine()
    private let historyToggle = Segmented(["CPU", "Memory"])
    private let chart = TimeChart()
    private let factsCard = CardView()
    private let storageSection = AppStorageSection()
    private var factRows: [FactRow] = []
    private let commandCard = CardView()
    private let commandTitle = TextLine()
    private let commandLine = NSTextField(wrappingLabelWithString: "")

    private let footer = Content()
    private var buttons: [GlassPill] = []

    private let gpuClients = GPUClients()
    private let work = DispatchQueue(label: "app.wisp.drawer", qos: .utility)
    private var busy = false
    private var argumentCache: [Int32: [String]] = [:]
    private var gpuShares: [Int32: Double] = [:]
    private var detailsToken = 0

    final class Content: NSView {
        override var isFlipped: Bool { true }
    }

    /// Brings the cards in from the top, for a newly opened app.
    func revealContent() {
        layoutSubtreeIfNeeded()
        Motion.cascade(content.subviews, in: scroll.documentVisibleRect, offset: 8)
    }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init(frame: .zero)
        storageSection.onClean = { [weak self] in self?.delegate.openCleanUp { $0.show(.junk) } }
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        body.radius = 20
        body.fill = Theme.ground
        // No masksToBounds: clipping a layer tree to rounded corners makes Core Animation
        // render it inside the app, about 190 MB of buffers. Nothing here reaches the corners.
        addSubview(body)

        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, name, kind, close] as [NSView] { header.addSubview(view) }
        close.toolTip = "Close (Esc)"
        close.onPress = { [weak self] in self?.onClose?() }
        rule.fill = Theme.rule
        rule.stroke = .clear
        rule.radius = 0
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // No title bar to keep clear of; insets would start the page scrolled.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autohidesScrollers = true
        for view in [header, rule, scroll, footer] as [NSView] { body.addSubview(view) }
        for view in [memory, cpu, strip, inside, historyCard, factsCard, commandCard] as [NSView] { content.addSubview(view) }
        for view in [power, gpu, disk, network] as [NSView] { strip.addSubview(view) }
        memory.showsMeter = true
        cpu.showsMeter = true

        historyTitle.text = NSAttributedString(string: "Last Hour", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink])
        historyCard.radius = 14
        for view in [historyTitle, historyToggle, chart] as [NSView] { historyCard.addSubview(view) }
        historyToggle.onChange = { [weak self] _ in self?.fillChart() }
        chart.step = 60
        factsCard.radius = 14
        commandCard.radius = 14
        commandTitle.text = Theme.caption("Command")
        commandLine.font = Theme.mono(10.5, .regular)
        commandLine.textColor = Theme.inkSecondary
        commandLine.isSelectable = true
        commandCard.addSubview(commandTitle)
        commandCard.addSubview(commandLine)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func layout() {
        super.layout()
        body.frame = bounds
        // An explicit path: without one the shadow is worked out from every layer
        // inside the drawer each time a figure moves, which renders it in-process.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 20, cornerHeight: 20, transform: nil)
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: 84)
        icon.frame = NSRect(x: 22, y: 20, width: 44, height: 44)
        name.frame = NSRect(x: 78, y: 23, width: width - 140, height: 20)
        kind.frame = NSRect(x: 78, y: 46, width: width - 140, height: 14)
        close.frame = NSRect(x: width - 20 - 32, y: 26, width: 32, height: 32)
        rule.frame = NSRect(x: 0, y: 84, width: width, height: 1)
        rule.isHidden = true
        let footerHeight: CGFloat = buttons.isEmpty ? 0 : 68
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        layoutFooter()
        // The content runs under the footer; the buttons float over it on their glass.
        scroll.frame = NSRect(x: 0, y: 85, width: width, height: bounds.height - 85)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: footerHeight, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: footerHeight, right: 0)
        arrangeContent()
    }

    private func arrangeContent() {
        let width = scroll.contentSize.width
        let inner = width - 32
        guard inner > 100 else { return }
        var y: CGFloat = 16
        let half = (inner - 10) / 2
        memory.frame = NSRect(x: 16, y: y, width: half, height: 116)
        cpu.frame = NSRect(x: 16 + half + 10, y: y, width: half, height: 116)
        y += 126
        strip.radius = 14
        strip.frame = NSRect(x: 16, y: y, width: inner, height: 58)
        y += 68
        if !inside.isHidden {
            inside.frame = NSRect(x: 16, y: y, width: inner, height: inside.wantedHeight)
            y = inside.frame.maxY + 10
        }
        historyCard.frame = NSRect(x: 16, y: y, width: inner, height: 150)
        historyTitle.frame = NSRect(x: 18, y: 18, width: 120, height: 18)
        let toggleWidth = historyToggle.naturalWidth
        historyToggle.frame = NSRect(x: inner - 18 - toggleWidth, y: 14, width: toggleWidth, height: 26)
        chart.frame = NSRect(x: 18, y: 50, width: inner - 36, height: 88)
        y = historyCard.frame.maxY + 10
        y = AppNetworkSection.attach(to: content).arrange(top: y, width: inner)
        y = storageSection.place(in: content, selection: selection, at: y, width: inner)
        let facts = factRows.filter { !$0.isHidden }
        factsCard.isHidden = facts.isEmpty
        if !facts.isEmpty {
            factsCard.frame = NSRect(x: 16, y: y, width: inner, height: CGFloat(facts.count) * 24 + 20)
            for (index, row) in facts.enumerated() { row.frame = NSRect(x: 18, y: 10 + CGFloat(index) * 24, width: inner - 36, height: 24) }
            y = factsCard.frame.maxY + 10
        }
        commandCard.isHidden = commandLine.stringValue.isEmpty
        if !commandCard.isHidden {
            let height = min(140, ceil(commandLine.sizeThatFits(NSSize(width: inner - 36, height: 1000)).height))
            commandCard.frame = NSRect(x: 16, y: y, width: inner, height: height + 50)
            commandTitle.frame = NSRect(x: 18, y: 16, width: inner - 36, height: 14)
            commandLine.frame = NSRect(x: 18, y: 36, width: inner - 36, height: height)
            y = commandCard.frame.maxY + 10
        }
        let height = max(y + 6, scroll.contentSize.height)
        if content.frame.size != NSSize(width: width, height: height) {
            content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    private func layoutFooter() {
        guard !buttons.isEmpty else { return }
        let width = footer.bounds.width - 32
        // The first button is an icon; the rest share the width, the last one widest.
        let iconWidth: CGFloat = 52
        let rest = buttons.count - 1
        let share = rest > 0 ? (width - iconWidth - CGFloat(rest) * 10) / CGFloat(rest) : 0
        var x: CGFloat = 16
        for (index, button) in buttons.enumerated() {
            let w = index == 0 ? iconWidth : share
            button.frame = NSRect(x: x, y: (footer.bounds.height - 40) / 2 - 2, width: w, height: 40)
            x += w + 10
        }
    }

    // MARK: Showing

    func show(_ selection: Selection) {
        let changed = selection != self.selection
        self.selection = selection
        if changed {
            setFacts([])
            commandLine.stringValue = ""
            inside.parts = []
            buildButtons()
            gpuShares = [:]
            if case .app(let id) = selection, let app = delegate.table.app(id) { loadAppFacts(app) }
            if case .process(let pid) = selection { loadDetails(pid: pid) }
        }
        update(table: delegate.table)
        needsLayout = true
    }

    func update(table: ProcessTable) {
        guard let selection else { return }
        let machine = delegate.settings.cpuOfMachine
        let total = Double(delegate.system.memory?.total ?? ProcessInfo.processInfo.physicalMemory)
        var pids: [Int32] = []
        switch selection {
        case .app(let id):
            guard let app = table.app(id) else {
                kind.text = Theme.caption("Not running", size: 9.5)
                return
            }
            pids = app.pids
            icon.image = Icons.icon(for: app)
            setTitle(app.name, (app.kind == .app ? "App" : app.kind == .system ? "Part of macOS" : "Command-line tool") + " · \(app.processCount) processes")
            fill(memory: app.memory, total: total, cpu: app.cpu, cores: table.coreCount, machine: machine,
                 watts: app.watts, disk: app.diskPerSecond, net: table.networkMeasured ? app.networkPerSecond : nil)
            inside.isHidden = app.processCount < 2
            inside.appName = app.name
            refreshInside(app, table: table)
        case .process(let pid):
            guard let row = table.processes.first(where: { $0.pid == pid }) else {
                kind.text = Theme.caption("Exited", size: 9.5)
                return
            }
            pids = [pid]
            let group = table.app(row.groupID)
            icon.image = group.map { Icons.icon(for: $0) }
            setTitle(row.name, "Process \(row.pid)" + (group.map { " in \($0.name)" } ?? ""))
            fill(memory: row.memory, total: total, cpu: row.cpu, cores: table.coreCount, machine: machine, watts: row.watts,
                 disk: row.diskReadPerSecond + row.diskWritePerSecond,
                 net: table.networkMeasured ? row.networkInPerSecond + row.networkOutPerSecond : nil)
            inside.isHidden = true
        }
        let share = pids.reduce(0.0) { $0 + (gpuShares[$1] ?? 0) }
        gpu.figure.show(gpuShares.isEmpty ? "–" : String(format: "%.0f", share * 100), unit: gpuShares.isEmpty ? "" : "%")
        sampleGPU()
        fillChart()
        AppNetworkSection.attach(to: content).update(selection: selection, pids: pids, table: table, delegate: delegate)
    }

    private func setTitle(_ title: String, _ detail: String) {
        name.text = NSAttributedString(string: title, attributes: [.font: Theme.sans(17, .bold), .foregroundColor: Theme.ink])
        kind.text = Theme.caption(detail, size: 9.5)
    }

    private func fill(memory bytes: UInt64, total: Double, cpu load: Double, cores: Int, machine: Bool,
                      watts: Double, disk rate: Double, net: Double?) {
        let (memValue, memUnit) = DashboardView.split(Format.memory(bytes))
        memory.figure.show(memValue, unit: memUnit)
        memory.setMeter(Double(bytes) / max(total, 1))
        memory.note.text = NSAttributedString(string: "\(Format.percent(Double(bytes) / max(total, 1))) of \(Format.memory(total))",
                                              attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.inkSecondary])
        cpu.figure.show(Style.appCPU(load, machine: machine, coreCount: cores).replacingOccurrences(of: "%", with: ""), unit: "%")
        cpu.setMeter(load / Double(max(cores, 1)))
        cpu.note.text = NSAttributedString(string: String(format: "%.1f of %d cores", load, cores),
                                           attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.inkSecondary])
        let (w, wu) = watts > 0.005 ? DashboardView.split(Format.watts(watts)) : ("–", "")
        power.figure.show(w, unit: wu)
        let (d, du) = rate > 0 ? DashboardView.split(Format.rate(rate)) : ("–", "")
        disk.figure.show(d, unit: du)
        if let net {
            let (n, nu) = net > 0 ? DashboardView.split(Format.rate(net)) : ("–", "")
            network.figure.show(n, unit: nu)
        } else {
            network.figure.show("Off")
        }
    }

    /// The breakdown and GPU shares are worked out off the main thread; helpers'
    /// command lines are read once per process.
    private func refreshInside(_ app: AppGroup, table: ProcessTable) {
        guard !busy, app.processCount > 1 else { return }
        busy = true
        let cache = argumentCache
        work.async { [weak self] in
            var found = cache
            let breakdown = AppBreakdown.make(app, table: table) { pid in
                if let args = found[pid] { return args }
                let args = ProcessDetails.arguments(pid: pid) ?? []
                found[pid] = args
                return args
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.argumentCache = found.filter { table.processes.lazy.map(\.pid).contains($0.key) }
                guard case .app(let id) = self.selection, id == app.id else { return }
                let grew = breakdown.parts.count != self.inside.parts.count || breakdown.isBrowser != self.inside.isBrowser
                self.inside.parts = breakdown.parts
                self.inside.isBrowser = breakdown.isBrowser
                self.inside.refresh()
                if grew { self.needsLayout = true }
            }
        }
    }

    private var gpuBusy = false

    private func sampleGPU() {
        guard !gpuBusy else { return }
        gpuBusy = true
        let clients = gpuClients
        work.async { [weak self] in
            let shares = clients.sample()
            DispatchQueue.main.async {
                self?.gpuBusy = false
                self?.gpuShares = shares
            }
        }
    }

    private func fillChart() {
        let history = delegate.monitor.history
        var id: String?
        switch selection {
        case .app(let appID): id = appID
        case .process(let pid): id = delegate.table.processes.first { $0.pid == pid }?.groupID
        case nil: break
        }
        guard let id else { return }
        if historyToggle.selected == 0 {
            chart.primaryColor = PageID.cpu.tint
            chart.names = ("CPU", "")
            chart.format = { [weak self] value in
                Style.appCPU(Double(value), machine: self?.delegate.settings.cpuOfMachine ?? false, coreCount: self?.delegate.table.coreCount ?? 1)
            }
            chart.primary = history.app(id, .cpu, minutes: 60)
        } else {
            chart.primaryColor = PageID.memory.tint
            chart.names = ("Memory", "")
            chart.format = { Format.memory(Double($0)) }
            chart.primary = history.app(id, .memory, minutes: 60)
        }
    }

    // MARK: Facts

    private func setFacts(_ rows: [(String, String)]) {
        while factRows.count < rows.count {
            let row = FactRow()
            factsCard.addSubview(row)
            factRows.append(row)
        }
        for (index, row) in factRows.enumerated() {
            row.isHidden = index >= rows.count
            if index < rows.count { row.set(rows[index]) }
        }
        needsLayout = true
    }

    private func loadAppFacts(_ app: AppGroup) {
        var rows: [(String, String)] = []
        if let path = app.bundlePath { rows.append(("Location", path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
        if let bundleID = app.bundleIdentifier { rows.append(("Bundle ID", bundleID)) }
        setFacts(rows)
        guard let main = app.pids.min() else { return }
        detailsToken += 1
        let token = detailsToken
        DispatchQueue.global(qos: .userInitiated).async {
            let signature = ProcessDetails.signature(pid: main)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detailsToken == token, let signature else { return }
                self.setFacts(rows + Self.signatureRows(signature))
            }
        }
    }

    private func loadDetails(pid: Int32) {
        detailsToken += 1
        let token = detailsToken
        let row = delegate.table.processes.first { $0.pid == pid }
        let parent = row.flatMap { r in delegate.table.processes.first { $0.pid == r.ppid } }
        DispatchQueue.global(qos: .userInitiated).async {
            let details = ProcessDetails.read(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detailsToken == token else { return }
                var rows: [(String, String)] = []
                if let parent { rows.append(("Parent", "\(parent.name) (\(parent.pid))")) }
                if let user = details.user { rows.append(("User", user)) }
                if let start = row?.startDate { rows.append(("Started", start.formatted(date: .abbreviated, time: .shortened))) }
                if let row, row.readable { rows.append(("CPU time", Format.duration(row.cpuTime))) }
                if let path = row?.path { rows.append(("Executable", path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
                if let cwd = details.workingDirectory { rows.append(("Folder", cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) }
                if let signature = details.signature { rows += Self.signatureRows(signature) }
                self.commandLine.stringValue = details.arguments.joined(separator: " ")
                self.setFacts(rows)
            }
        }
    }

    private static func signatureRows(_ s: ProcessDetails.Signature) -> [(String, String)] {
        var rows = [("Signed by", s.authority + (s.valid ? "" : ", not valid"))]
        if let team = s.teamID { rows.append(("Team ID", team)) }
        rows.append(("Sandbox", s.sandboxed ? "Yes" : "No"))
        rows.append(("Hardened", s.hardenedRuntime ? "Yes" : "No"))
        return rows
    }

    // MARK: Actions

    private func buildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        var canQuit = true
        if case .app(let id) = selection, let app = delegate.table.app(id) { canQuit = app.kind != .system }
        let finder = GlassPill("", symbol: "folder")
        finder.toolTip = "Show in Finder"
        finder.onPress = { [weak self] in self?.reveal() }
        buttons.append(finder)
        if case .app(let id) = selection, let app = delegate.table.app(id), let path = app.bundlePath,
           InstalledApps.isUninstallable(path: path, bundleID: app.bundleIdentifier) {
            let uninstall = GlassPill("Uninstall…")
            uninstall.onPress = { [weak self] in self?.delegate.openCleanUp { $0.showUninstall(of: path) } }
            buttons.append(uninstall)
        }
        if canQuit {
            let force = GlassPill("Force Quit…", kind: .destructive)
            force.onPress = { [weak self] in self?.forceQuit() }
            let quit = GlassPill("Quit", symbol: "power", kind: .primary)
            quit.onPress = { [weak self] in self?.quit() }
            buttons += [force, quit]
        }
        buttons.forEach(footer.addSubview)
    }

    private func quit() {
        switch selection {
        case .app(let id):
            guard let app = delegate.table.app(id) else { return }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "")
            if running.isEmpty { for pid in app.pids { kill(pid, SIGTERM) } } else { running.forEach { $0.terminate() } }
        case .process(let pid): kill(pid, SIGTERM)
        case nil: break
        }
    }

    private func forceQuit() {
        guard let window else { return }
        var pids: [Int32] = []
        var label = ""
        switch selection {
        case .app(let id):
            guard let app = delegate.table.app(id) else { return }
            pids = app.pids
            label = app.name
        case .process(let pid):
            pids = [pid]
            label = delegate.table.processes.first { $0.pid == pid }?.name ?? "process \(pid)"
        case nil: return
        }
        let alert = NSAlert()
        alert.messageText = "Force quit \(label)?"
        alert.informativeText = "It stops at once and loses anything it has not saved."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { for pid in pids { kill(pid, SIGKILL) } }
        }
    }

    private func reveal() {
        var path: String?
        switch selection {
        case .app(let id): path = delegate.table.app(id)?.bundlePath
        case .process(let pid): path = delegate.table.processes.first { $0.pid == pid }?.path
        case nil: break
        }
        if let path { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    }
}

/// A name on the left and its value on the right, shortened in the middle so the
/// end of a path stays readable. The full value is in the tooltip.
final class FactRow: DrawnView {
    private var pair = ("", "")

    func set(_ pair: (String, String)) {
        guard pair != self.pair else { return }
        self.pair = pair
        toolTip = pair.1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let key = NSAttributedString(string: pair.0, attributes: [.font: Theme.sans(12), .foregroundColor: Theme.inkSecondary])
        key.draw(at: NSPoint(x: 0, y: (bounds.height - key.size().height) / 2))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingMiddle
        let left: CGFloat = 96
        (pair.1 as NSString).draw(with: NSRect(x: left, y: (bounds.height - 16) / 2, width: bounds.width - left, height: 17),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: Theme.sans(12, .medium), .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { pair.0 + " " + pair.1 }
}
