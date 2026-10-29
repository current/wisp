import AppKit
import WispCore

/// The panel behind every status item. A borderless window with a solid
/// background rather than an NSPopover: the popover's blurred material has to
/// re-render behind every animation and holds a large GPU buffer while open.
/// Built once; while closed it receives no updates.
@MainActor
final class DashboardPopover: NSObject {
    private unowned let delegate: AppDelegate
    private var panel: DashboardPanel?
    private var content: DashboardView?
    private var monitors: [Any] = []
    /// WISP_PIN keeps it open; WISP_BACKGROUND also keeps it behind other windows, for screenshots.
    private let pinned = ProcessInfo.processInfo.environment["WISP_PIN"] != nil || MainWindowController.background

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.isShown else { return }
            self.content?.update(snapshot, history: delegate.monitor.history)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.isShown else { return }
            self.content?.update(table)
        }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    /// The saved layout changed: rebuild the blocks. A closed dashboard does it now
    /// too, so it opens at the right size.
    func layoutChanged() {
        guard let content else { return }
        content.apply(delegate.settings.dashboard, animated: false)
        if isShown {
            content.update(delegate.system, history: delegate.monitor.history)
            content.update(delegate.table)
        }
        panel?.fit()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { return close() }
        let view = content ?? DashboardView(delegate: delegate)
        content = view
        let panel = self.panel ?? DashboardPanel(content: view)
        self.panel = panel
        view.onHeightChange = { [weak panel] in panel?.fit() }
        view.update(delegate.system, history: delegate.monitor.history)
        view.update(delegate.table)
        let screen = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.maxHeight = screen.height - 16
        panel.fit()

        if let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - panel.frame.width / 2
            x = min(max(screen.minX + 8, x), screen.maxX - panel.frame.width - 8)
            panel.anchorTop = anchor.minY - 6
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - panel.frame.height))
        }
        panel.alphaValue = 0
        if MainWindowController.background {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            panel.orderBack(nil)
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        delegate.dashboardOpen = true
        guard !pinned else { return }
        // Close on a click anywhere else, in another app or in the menu bar.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        } as Any)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        content?.hideTooltip()
        delegate.dashboardOpen = false
    }
}

/// A rounded panel on the grey ground that holds the dashboard and can take key
/// focus without activating the app. When the blocks are taller than the screen,
/// they scroll.
final class DashboardPanel: NSPanel {
    private let frameView = CardView()
    private let scroll = NSScrollView()
    private let view: DashboardView
    var maxHeight: CGFloat = 2000
    /// The screen y the panel hangs from, so it grows and shrinks downwards.
    var anchorTop: CGFloat?

    init(content: DashboardView) {
        view = content
        super.init(contentRect: NSRect(origin: .zero, size: content.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        frameView.fill = Theme.ground
        frameView.radius = Theme.panelRadius
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        frameView.addSubview(scroll)
        contentView = frameView
        setAccessibilityLabel("Wisp")
    }

    override var canBecomeKey: Bool { true }

    func fit() {
        let size = NSSize(width: view.frame.width, height: min(view.frame.height, maxHeight))
        if frame.size != size {
            var origin = frame.origin
            if let anchorTop { origin.y = anchorTop - size.height }
            setFrame(NSRect(origin: origin, size: size), display: true)
        }
        frameView.frame = NSRect(origin: .zero, size: size)
        // Inset by the corner radius' worth so scrolled content stays inside the rounded edge.
        scroll.frame = NSRect(origin: .zero, size: size)
    }
}

/// The dashboard: a header, the blocks chosen in Settings in their order, and a
/// footer. The same view, scaled down and not clickable, is the builder's preview.
@MainActor
final class DashboardView: DrawnView {
    private unowned let delegate: AppDelegate
    static let width: CGFloat = 384
    static let outer: CGFloat = 10
    static let spacing: CGFloat = 8
    static let blocksTop: CGFloat = 52
    /// The builder's copy: drawn the same, but the builder takes every click.
    let preview: Bool

    // Header
    private let title = TextLine(Toolbar.title("Wisp"))
    private let chip = MachineChip()
    private lazy var settingsButton = SymbolButton(symbol: "slider.horizontal.3", label: "Settings", target: self, action: #selector(openSettings))
    private lazy var closeButton = SymbolButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeDashboard))

    // Blocks
    private(set) var layout: [DashboardBlock] = []
    private var views: [DashboardBlock: DashboardBlockView] = [:]
    private let emptyNote = TextLine(Theme.caption("No blocks yet. Add some in Settings, Menu Bar."), alignment: .center)

    // Footer, one view so it moves as one when blocks come and go.
    private let footer = DrawnView()
    private lazy var moreButton = SymbolButton(symbol: "ellipsis", label: "More", target: self, action: #selector(showMore(_:)))
    private let footerRule = CardView()
    private let status = TextLine()
    private lazy var openButton = ActionButton(title: "Open Wisp", target: self, action: #selector(openWindow))

    private let tooltip = Tooltip()
    private var lastSystem: SystemSnapshot?
    private var lastTable: ProcessTable?
    var onHeightChange: (() -> Void)?

    init(delegate: AppDelegate, preview: Bool = false) {
        self.delegate = delegate
        self.preview = preview
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        wantsLayer = true
        for view in [title, chip, settingsButton, closeButton, emptyNote, footer] as [NSView] { addSubview(view) }
        for view in [moreButton, footerRule, status, openButton] as [NSView] { footer.addSubview(view) }
        footer.wantsLayer = true
        tooltip.isHidden = true
        addSubview(tooltip)
        footerRule.fill = Theme.cardBorder
        footerRule.stroke = .clear
        footerRule.radius = 0

        title.frame = NSRect(x: 20, y: 16, width: 60, height: 20)
        closeButton.frame = NSRect(x: Self.width - 14 - 26, y: 13, width: 26, height: 26)
        settingsButton.frame = NSRect(x: closeButton.frame.minX - 30, y: 13, width: 26, height: 26)
        placeChip()
        moreButton.frame = NSRect(x: 12, y: 14, width: 26, height: 26)
        footerRule.frame = NSRect(x: 44, y: 18, width: 1, height: 18)
        let openSize = openButton.intrinsicContentSize
        openButton.frame = NSRect(x: Self.width - Self.outer - 4 - openSize.width, y: 12, width: openSize.width, height: openSize.height)
        status.frame = NSRect(x: 56, y: 20, width: openButton.frame.minX - 64, height: 14)
        apply(delegate.settings.dashboard, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { preview ? nil : super.hitTest(point) }

    private func placeChip() {
        chip.frame = NSRect(x: settingsButton.frame.minX - 8 - chip.naturalWidth, y: 12, width: chip.naturalWidth, height: 28)
    }

    // MARK: Blocks

    /// Room left open in the stack while the builder drags a block over it.
    struct Gap: Equatable {
        var index: Int
        var height: CGFloat
    }

    func view(for block: DashboardBlock) -> DashboardBlockView? { views[block] }

    /// The block's view, made now if it has not been shown yet (to know its height).
    func prepare(_ block: DashboardBlock) -> DashboardBlockView {
        if let view = views[block] { return view }
        let view = DashboardBlockView.makeView(block, delegate: delegate)
        views[block] = view
        configure(view)
        return view
    }

    /// The open slot while the builder drags a block, in this view's coordinates.
    private(set) var gapRect: NSRect?

    /// Where each block sits, in this view's coordinates.
    func frames() -> [(DashboardBlock, NSRect)] {
        layout.compactMap { block in views[block].map { (block, $0.frame) } }
    }

    /// The y where the blocks end and the footer starts.
    var blocksBottom: CGFloat { footer.frame.minY }

    /// Shows `layout` top to bottom. With a gap, the blocks from that index down
    /// sit lower to leave room. Animated, every block slides from where it is now.
    func apply(_ newLayout: [DashboardBlock], gap: Gap? = nil, animated: Bool) {
        for block in layout where !newLayout.contains(block) {
            views[block]?.removeFromSuperview()
        }
        layout = newLayout
        var y = Self.blocksTop
        let width = Self.width - Self.outer * 2
        gapRect = nil
        for (index, block) in newLayout.enumerated() {
            if let gap, gap.index == index {
                gapRect = NSRect(x: Self.outer, y: y, width: width, height: gap.height)
                y += gap.height + Self.spacing
            }
            let view = prepare(block)
            var fresh = false
            if view.superview !== self {
                fresh = true
                addSubview(view, positioned: .below, relativeTo: tooltip)
                view.isHidden = false
                if let lastSystem { view.update(lastSystem, history: delegate.monitor.history) }
                if let lastTable { view.update(lastTable) }
            }
            place(view, NSRect(x: Self.outer, y: y, width: width, height: view.height), animated: animated && !fresh)
            if fresh, animated, !Theme.reduceMotion { Self.appear(view) }
            y += view.height + Self.spacing
        }
        if let gap, gap.index >= newLayout.count {
            gapRect = NSRect(x: Self.outer, y: y, width: width, height: gap.height)
            y += gap.height + Self.spacing
        }
        emptyNote.isHidden = !newLayout.isEmpty || gap != nil
        if newLayout.isEmpty, gap == nil {
            emptyNote.frame = NSRect(x: Self.outer, y: y + 8, width: width, height: 16)
            y += 40
        }
        let bottom = y - (newLayout.isEmpty && gap == nil ? 0 : Self.spacing)
        place(footer, NSRect(x: 0, y: bottom, width: Self.width, height: 54), animated: animated)
        let height = bottom + 54
        if frame.height != height {
            setFrameSize(NSSize(width: Self.width, height: height))
            onHeightChange?()
        }
    }

    private func configure(_ view: DashboardBlockView) {
        view.onResize = { [weak self] in
            guard let self else { return }
            self.apply(self.layout, animated: false)
        }
        if let apps = view as? AppsBlock { apps.interactive = !preview }
        if let cores = view as? CoresBlock, !preview {
            cores.onHover = { [weak self, weak cores] hover in
                guard let self, let cores else { return }
                self.hoverCore(hover, in: cores)
            }
        }
    }

    /// Moves a view to its new frame. Animated, the layer runs from where it shows
    /// now to the new spot on the render server, so a slide costs the app nothing.
    func place(_ view: NSView, _ target: NSRect, animated: Bool) {
        guard view.frame != target else { return }
        guard animated, !Theme.reduceMotion, let layer = view.layer, view.frame.size == target.size else {
            view.frame = target
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = target
        CATransaction.commit()
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: layer.position)
        slide.duration = 0.34
        slide.timingFunction = DashboardView.smoothOut
        layer.add(slide, forKey: "slide")
    }

    /// A block that joins the stack fades in once the others have made room.
    private static func appear(_ view: NSView) {
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + 0.1
        fade.duration = 0.24
        fade.fillMode = .backwards
        fade.timingFunction = smoothOut
        layer.add(fade, forKey: "appear")
    }

    /// cubic-bezier(0.22, 1, 0.36, 1), the same curve as Motion.smoothOut.
    static let smoothOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    // MARK: Updates

    func update(_ s: SystemSnapshot, history: HistoryStore) {
        lastSystem = s
        for block in layout { views[block]?.update(s, history: history) }
        let interval = delegate.settings.interval
        let live = NSMutableAttributedString(string: "● ", attributes: [.font: Theme.mono(9), .foregroundColor: Theme.good])
        live.append(Theme.caption("Live · every \(interval.formatted()) s"))
        status.text = live
    }

    func update(_ table: ProcessTable) {
        lastTable = table
        for block in layout { views[block]?.update(table) }
    }

    // MARK: Hover

    private func hoverCore(_ hover: (Int, Int, NSRect)?, in block: CoresBlock) {
        let heatmap = block.heatmap
        guard let (row, column, rect) = hover, heatmap.rows.indices.contains(row) else { return hideTooltip() }
        let values = heatmap.rows[row].values
        let index = values.count - 1 - column
        guard index >= 0 else { return hideTooltip() }
        let seconds = Double(column) * max(delegate.settings.interval, 1)
        tooltip.title = "Core \(heatmap.rows[row].label)"
        tooltip.detail = column == 0 ? "Now" : Format.duration(seconds) + " ago"
        tooltip.lines = [Tooltip.Line(color: Theme.heat(values[index], appearance: effectiveAppearance),
                                      name: "Busy", value: String(format: "%.0f%%", values[index] * 100))]
        tooltip.show(in: self, above: convert(rect, from: heatmap))
    }

    func hideTooltip() { tooltip.hide() }

    // MARK: Actions

    @objc private func openWindow() { delegate.showWindow() }
    @objc private func openSettings() { delegate.showSettings() }
    @objc private func closeDashboard() { delegate.closeDashboard() }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Customize Dashboard…", action: #selector(customize), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func customize() { delegate.showSettings(section: .menuBar) }

    // MARK: Helpers

    static func split(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (text, "")
    }

    static func titleText(_ name: String, _ count: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: Theme.sans(14), .foregroundColor: Theme.ink])
        if !count.isEmpty {
            text.append(NSAttributedString(string: " · " + count, attributes: [.font: Theme.sans(14), .foregroundColor: Theme.inkTertiary]))
        }
        return text
    }
}

/// Caption, figure with unit, and a tick meter, stacked.
final class Meter: DrawnView {
    var caption = "" { didSet { if caption != oldValue { needsDisplay = true } } }
    private var value = ""
    private var unit = ""
    private let ticks = TickMeter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(ticks)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(value newValue: String, unit newUnit: String, fraction: Double, color: NSColor) {
        if newValue != value || newUnit != unit {
            value = newValue
            unit = newUnit
            needsDisplay = true
        }
        ticks.fraction = fraction.isFinite ? fraction : 0
        if ticks.color != color { ticks.color = color }
    }

    override func layout() {
        super.layout()
        ticks.frame = NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.caption(caption, size: 9.5).draw(at: .zero)
        let text = NSMutableAttributedString(string: value, attributes: [.font: Theme.figure(13, .medium), .foregroundColor: Theme.ink])
        if !unit.isEmpty {
            text.append(NSAttributedString(string: " " + unit, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkTertiary]))
        }
        text.draw(at: NSPoint(x: 0, y: 13))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { caption }
    override func accessibilityValue() -> Any? { value + " " + unit }
}

/// The chip in the header naming this Mac's chip and memory.
final class MachineChip: DrawnView {
    private(set) var chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer)
        return name.isEmpty ? "This Mac" : name
    }()
    /// Installed memory; read once, so the header needs no memory sampling.
    private let memory = Format.memory(ProcessInfo.processInfo.physicalMemory)

    private var text: String {
        let short = chipName.replacingOccurrences(of: "Apple ", with: "")
        return memory.isEmpty ? short : "\(short) · \(memory)"
    }

    var naturalWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Theme.sans(12)]).width) + 40
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.card.setFill()
        shape.fill()
        Theme.cardBorder.setStroke()
        shape.stroke()
        if let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                Theme.inkSecondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 10, y: (bounds.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (text as NSString).draw(at: NSPoint(x: 28, y: (bounds.height - 15) / 2),
                                withAttributes: [.font: Theme.sans(12), .foregroundColor: Theme.ink])
    }
}
