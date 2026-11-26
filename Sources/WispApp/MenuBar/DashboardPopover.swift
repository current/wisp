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
    /// Items redone in the soft style have their own dropdown and panel, made on first use.
    private var soft: [MenuMetric: (view: SoftDropdown, panel: DashboardPanel)] = [:]
    /// Whichever panel is open, or was last.
    private var current: DashboardPanel?
    private var monitors: [Any] = []
    private var closedByClickAt: TimeInterval = 0
    /// The status item the dropdown hangs from, and the reading it is about (nil: the dashboard).
    private weak var anchorButton: NSStatusBarButton?
    private var focus: MenuMetric?
    /// WISP_PIN keeps it open; WISP_BACKGROUND also keeps it behind other windows, for screenshots.
    private let pinned = ProcessInfo.processInfo.environment["WISP_PIN"] != nil || MainWindowController.background

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.isShown else { return }
            if let focus = self.focus, let view = self.soft[focus]?.view { return view.update(snapshot, history: delegate.monitor.history) }
            self.content?.update(snapshot, history: delegate.monitor.history)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.isShown else { return }
            if let focus = self.focus, let view = self.soft[focus]?.view { return view.update(table) }
            self.content?.update(table)
        }
    }

    var isShown: Bool { current?.isVisible ?? false }

    /// The saved layout changed: rebuild the blocks. A closed dashboard does it now
    /// too, so it opens at the right size.
    func layoutChanged() {
        guard let content, focus == nil else { return }
        content.apply(delegate.settings.dashboard, animated: false)
        if isShown, current === panel {
            content.update(delegate.system, history: delegate.monitor.history)
            content.update(delegate.table)
        }
        panel?.fit()
    }

    func toggle(relativeTo button: NSStatusBarButton, focus: MenuMetric? = nil) {
        let sameItem = button === anchorButton && focus == self.focus
        if isShown {
            if sameItem { return close() }
            // Another item while open: move the dropdown to it.
            close()
        }
        // A click on the status item while open reaches the outside-click monitor on
        // mouse down and closes the panel; the button's action then arrives on mouse up.
        // That click meant "close", so do not open again.
        if sameItem, ProcessInfo.processInfo.systemUptime - closedByClickAt < 0.5 { return }
        anchorButton = button
        self.focus = focus
        let panel: DashboardPanel
        if let focus, let made = softDropdown(for: focus) {
            panel = made.panel
            delegate.dashboardLayout = Self.softBlocks(focus)
            made.view.prepare()
        } else {
            let view = content ?? DashboardView(delegate: delegate)
            content = view
            panel = self.panel ?? DashboardPanel(content: view, soft: true)
            self.panel = panel
            view.onHeightChange = { [weak panel] in panel?.fit() }
            view.show(focus: focus)
            delegate.dashboardLayout = view.layout
            if view.layout.contains(.usage) { delegate.plans.refresh(maxAge: 20, liveAge: 180) }
            view.update(delegate.system, history: delegate.monitor.history)
            view.update(delegate.table)
        }
        current = panel
        let screen = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.maxHeight = screen.height - 16
        panel.fit()

        if let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            // The frame includes the room for a soft panel's shadow; place the panel itself.
            let margin = panel.margin
            var x = anchor.midX - panel.frame.width / 2
            x = min(max(screen.minX + 8 - margin, x), screen.maxX - panel.frame.width - 8 + margin)
            panel.anchorTop = anchor.minY - 6
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - panel.frame.height + margin))
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
            self?.closedByClickAt = ProcessInfo.processInfo.systemUptime
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        } as Any)
    }

    /// The soft dropdown for `focus`, made the first time it opens; nil for items that
    /// still use the dashboard's blocks.
    private func softDropdown(for focus: MenuMetric) -> (view: SoftDropdown, panel: DashboardPanel)? {
        if let made = soft[focus] { return made }
        guard let view = Self.makeSoft(focus, delegate: delegate) else { return nil }
        let panel = DashboardPanel(content: view, soft: true)
        view.onHeightChange = { [weak panel] in panel?.fit() }
        soft[focus] = (view, panel)
        return (view, panel)
    }

    private static func makeSoft(_ focus: MenuMetric, delegate: AppDelegate) -> SoftDropdown? {
        switch focus {
        case .usage: return UsageDropdown(delegate: delegate)
        case .temperature: return TemperatureDropdown(delegate: delegate)
        case .memory: return MemoryDropdown(delegate: delegate)
        case .cpu: return CPUDropdown(delegate: delegate)
        case .network: return NetworkDropdown(delegate: delegate)
        case .gpu: return GPUDropdown(delegate: delegate)
        case .disk: return DiskDropdown(delegate: delegate)
        case .battery, .power: return PowerDropdown(delegate: delegate, metric: focus)
        }
    }

    /// What a soft dropdown reads while open, so the monitor samples it.
    private static func softBlocks(_ focus: MenuMetric) -> [DashboardBlock] {
        switch focus {
        case .usage: return [.usage]
        case .temperature: return [.sensors]
        case .memory: return [.memory, .apps]
        case .cpu: return [.cpu, .cores, .apps]
        case .network: return [.network, .apps]
        case .gpu: return [.gpu, .sensors]
        case .disk: return [.disk, .apps]
        case .battery, .power: return [.power, .apps]
        }
    }

    /// WISP_POPOVER_SNAPSHOT=<file.png> builds the dashboard in a panel far off every
    /// screen, lets it fill for WISP_SNAPSHOT_DELAY seconds (default 5), draws it into
    /// a PNG and quits. The real popover never opens. Liquid Glass does not show here.
    func snapshotIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["WISP_POPOVER_SNAPSHOT"] else { return }
        let delay = ProcessInfo.processInfo.environment["WISP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 5
        // WISP_POPOVER_FOCUS=usage (or temperature) draws that item's soft dropdown instead.
        let focus = ProcessInfo.processInfo.environment["WISP_POPOVER_FOCUS"].flatMap(MenuMetric.init(rawValue:))
        let view = DashboardView(delegate: delegate)
        let softView = focus.flatMap { Self.makeSoft($0, delegate: delegate) }
        let panel = softView.map { DashboardPanel(content: $0, soft: true) } ?? DashboardPanel(content: view, soft: true)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        view.onHeightChange = { [weak panel] in panel?.fit() }
        softView?.onHeightChange = { [weak panel] in panel?.fit() }
        panel.fit()
        panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        panel.orderBack(nil)
        // The monitor samples only what the open blocks show, as it does for the real dropdown.
        delegate.dashboardLayout = focus.map(Self.softBlocks) ?? view.layout
        delegate.dashboardOpen = true
        if focus == .usage || (focus == nil && view.layout.contains(.usage)) { delegate.plans.refresh(maxAge: 0, liveAge: 180) }
        softView?.prepare()
        // The dashboard view goes once a soft dropdown takes the panel; only one is drawn.
        let refresh = { [weak self, weak view] in
            guard let self else { return }
            if let softView {
                softView.update(self.delegate.system, history: self.delegate.monitor.history)
                return softView.update(self.delegate.table)
            }
            guard let view else { return }
            view.update(self.delegate.system, history: self.delegate.monitor.history)
            view.update(self.delegate.table)
        }
        refresh()
        delegate.observeSystem { _ in refresh() }
        delegate.observeTable { _ in refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            panel.fit()
            Self.write(panel, to: URL(fileURLWithPath: path))
            if let root = panel.contentView {
                AccessibilityDump.write(root, to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("ax.txt"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func write(_ panel: NSWindow, to url: URL) {
        guard let root = panel.contentView, let layer = root.layer else { return }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let scale: CGFloat = 2
        let size = root.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        // The panel's root is flipped; its layer draws top-down, the bitmap bottom-up.
        if root.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        root.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    func close() {
        guard let current, current.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        current.orderOut(nil)
        delegate.dashboardOpen = false
    }
}

/// A rounded panel on the grey ground that holds the dashboard and can take key
/// focus without activating the app. When the blocks are taller than the screen,
/// they scroll.
final class DashboardPanel: NSPanel {
    private let frameView = CardView()
    /// The soft panel's frosted glass: the window server blurs what is behind the panel,
    /// and `frameView` lays a tint over it. Snapshots have nothing behind to blur.
    private var blur: NSVisualEffectView?
    private var face: SoftDropdown.Face?
    private let scroll = NSScrollView()
    private let view: NSView
    var maxHeight: CGFloat = 2000
    /// The screen y the panel hangs from, so it grows and shrinks downwards.
    var anchorTop: CGFloat?
    /// Room around a soft panel for the shadow it draws itself. The system's window
    /// shadow traces the edge with a crisp dark line; this one is only a soft falloff.
    let margin: CGFloat
    private var shadow: SoftDropdown.Shadow?

    /// `soft`: the tinted panel with larger corners that the AI usage dropdown sits on.
    init(content: NSView, soft: Bool = false) {
        view = content
        margin = soft && !Theme.solidPanels ? 28 : 0
        super.init(contentRect: NSRect(origin: .zero, size: content.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        // Blocks come and go as the dashboard fills; Tab follows whatever is shown.
        autorecalculatesKeyViewLoop = true
        frameView.fill = Theme.ground
        frameView.radius = Theme.panelRadius
        if soft {
            // The face draws the panel; the frame only holds the scroll view.
            frameView.fill = .clear
            frameView.stroke = .clear
            let face = SoftDropdown.Face()
            face.solid = Theme.solidPanels
            self.face = face
            if !Theme.solidPanels {
                hasShadow = false
                let shadow = SoftDropdown.Shadow()
                shadow.margin = margin
                self.shadow = shadow
                let blur = NSVisualEffectView()
                blur.material = .popover
                blur.blendingMode = .behindWindow
                blur.state = .active
                blur.maskImage = Self.roundedMask(radius: SoftDropdown.panelRadius)
                self.blur = blur
            }
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        frameView.addSubview(scroll)
        if let face {
            let root = NSView()
            if let shadow { root.addSubview(shadow) }
            if let blur { root.addSubview(blur) }
            root.addSubview(face)
            root.addSubview(frameView)
            contentView = root
        } else {
            contentView = frameView
        }
        setAccessibilityLabel("Wisp")
    }

    /// A stretchable mask with the panel's continuous corners, for the blur.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        // A continuous corner starts curving further along the side than its radius, so
        // the fixed caps must cover all of it or stretching bends the curve.
        let cap = ceil(radius * 1.3) + 1
        let side = cap * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: CGPath.continuous(rect, radius: radius)).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { true }

    func fit() {
        let size = NSSize(width: view.frame.width, height: min(view.frame.height, maxHeight))
        let outer = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        if frame.size != outer {
            var origin = frame.origin
            if let anchorTop { origin.y = anchorTop - size.height - margin }
            setFrame(NSRect(origin: origin, size: outer), display: true)
        }
        shadow?.frame = NSRect(origin: .zero, size: outer)
        frameView.frame = NSRect(origin: NSPoint(x: margin, y: margin), size: size)
        blur?.frame = frameView.frame
        face?.frame = frameView.frame
        // Inset by the corner radius' worth so scrolled content stays inside the rounded edge.
        scroll.frame = NSRect(origin: .zero, size: size)
    }
}

/// The dashboard: the blocks chosen in Settings, in their order, in the soft dropdowns'
/// style. Wisp's icon with a title and a line summing up the blocks; a section titled
/// This Mac with the machine's chip, holding a card per block; and a footer with a hint
/// and a link into Wisp. The same view, unscaled and not clickable, is the builder's
/// preview.
@MainActor
final class DashboardView: DrawnView {
    private unowned let delegate: AppDelegate
    /// Laid out in the dropdowns' 400-point space; the menu bar panel shows it at their
    /// scale, the builder at its own.
    static let width: CGFloat = SoftDropdown.width
    /// Where the cards start from the edge: the section's margin plus its inset.
    static let outer: CGFloat = SoftDropdown.sectionX + SoftDropdown.inset
    static let spacing: CGFloat = SoftDropdown.cardGap
    static let blocksTop: CGFloat = SoftDropdown.headHeight + SoftDropdown.sectionTitle
    /// The builder's copy: drawn the same, but the builder takes every click.
    let preview: Bool

    // Header
    private let face: DashboardFace?
    private let plate = SoftDropdown.Plate()
    private let head = SoftDropdown.Head()
    private let chip = MachineChip()
    private lazy var moreButton = SoftDropdown.RoundButton(symbol: "ellipsis", label: "More", target: self, action: #selector(showMore(_:)))
    private lazy var settingsButton = SoftDropdown.RoundButton(symbol: "slider.horizontal.3", label: "Settings", target: self,
                                                               action: #selector(openSettings))
    private lazy var closeButton = SoftDropdown.RoundButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeDashboard))

    // Blocks
    private(set) var layout: [DashboardBlock] = []
    private var views: [DashboardBlock: DashboardBlockView] = [:]
    private let emptyNote = SoftText()
    private lazy var emptyButton: ActionButton = {
        let button = ActionButton(title: "Choose Blocks", target: self, action: #selector(customize))
        button.secondary = true
        button.font = SoftLook.strong
        return button
    }()
    /// A block changed height while the stack was being laid out; it is placed then anyway.
    private var applying = false
    /// The section's smaller size, waiting for the blocks to finish sliding up into it.
    private var pendingSection: NSRect?

    // Footer, one view so it moves as one when blocks come and go.
    private let footer = DrawnView()
    private let hint = SoftText()
    private lazy var openLink = SoftDropdown.LinkButton(title: "Open Wisp", target: self, action: #selector(openWindow))

    private var lastSystem: SystemSnapshot?
    private var lastTable: ProcessTable?
    var onHeightChange: (() -> Void)?

    init(delegate: AppDelegate, preview: Bool = false) {
        self.delegate = delegate
        self.preview = preview
        face = preview ? DashboardFace() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        wantsLayer = true
        if let face { addSubview(face) }
        plate.title = "This Mac"
        head.title = "Wisp"
        for view in [plate, head, chip, moreButton, settingsButton, closeButton, emptyNote, emptyButton, footer] as [NSView] { addSubview(view) }
        for view in [hint, openLink] as [NSView] { footer.addSubview(view) }
        footer.wantsLayer = true
        emptyNote.centered = true

        let width = Self.width, button: CGFloat = 30
        head.frame = NSRect(x: 0, y: 0, width: width, height: SoftDropdown.headHeight)
        closeButton.frame = NSRect(x: width - 16 - button, y: (SoftDropdown.headHeight - button) / 2 + 1, width: button, height: button)
        settingsButton.frame = closeButton.frame.offsetBy(dx: -(button + 8), dy: 0)
        moreButton.frame = settingsButton.frame.offsetBy(dx: -(button + 8), dy: 0)
        head.textRight = moreButton.frame.minX - 12
        let chipWidth = chip.naturalWidth
        let titleMid = SoftDropdown.headHeight + SoftDropdown.sectionTitle / 2 + 1
        chip.frame = NSRect(x: width - SoftDropdown.sectionX - SoftDropdown.padX + 3 - chipWidth, y: titleMid - 12, width: chipWidth, height: 24)
        let link = openLink.intrinsicContentSize
        openLink.frame = NSRect(x: width - 18 - link.width, y: ((SoftDropdown.footerHeight - link.height) / 2 - SoftDropdown.footerLift).rounded(),
                                width: link.width, height: link.height)
        let hintLeft = SoftDropdown.sectionX + 8
        hint.frame = NSRect(x: hintLeft, y: (SoftDropdown.footerHeight / 2 - SoftDropdown.footerLift - 10).rounded(),
                            width: openLink.frame.minX - 12 - hintLeft, height: 20)
        apply(delegate.settings.dashboard, animated: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Wisp dashboard")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { preview ? nil : super.hitTest(point) }

    /// The whole dashboard (nil), or the blocks about one menu bar reading, with the apps
    /// sorted by that reading.
    func show(focus: MenuMetric?) {
        head.title = focus?.title ?? "Wisp"
        guard let focus else { return apply(delegate.settings.dashboard, animated: false) }
        let dropdown = focus.dropdown
        apply(dropdown.blocks, animated: false)
        (views[.apps] as? AppsBlock)?.tabs.select(dropdown.appsTab, animated: false)
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
        applying = true
        defer { applying = false }
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
                addSubview(view, positioned: .below, relativeTo: footer)
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
        let empty = newLayout.isEmpty && gap == nil
        emptyNote.isHidden = !empty
        emptyButton.isHidden = !empty || preview
        if empty {
            let rect = NSRect(x: Self.outer, y: y, width: width, height: preview ? 64 : SoftDropdown.emptyHeight)
            plate.cards = [rect]
            emptyNote.text = "No blocks yet. Pick some in Settings, Menu Bar."
            emptyNote.frame = NSRect(x: rect.minX + 16, y: rect.minY + 22, width: rect.width - 32, height: 20)
            let size = emptyButton.intrinsicContentSize
            emptyButton.frame = NSRect(x: (rect.midX - size.width / 2).rounded(), y: rect.minY + 54, width: size.width, height: size.height)
            y = rect.maxY + Self.spacing
        } else {
            plate.cards = []
        }
        // A hint for what the blocks shown can do.
        hint.text = empty ? "" : newLayout.contains(.apps) ? "Click an app to see it in Wisp."
            : newLayout.contains(.usage) ? "Hover a limit for its reset time."
            : newLayout.contains(.cores) ? "Hover a core for its reading." : "Click a card to open its page."
        let section = NSRect(x: SoftDropdown.sectionX, y: SoftDropdown.headHeight, width: Self.width - SoftDropdown.sectionX * 2,
                             height: y - Self.spacing + SoftDropdown.bottomInset - SoftDropdown.headHeight)
        place(footer, NSRect(x: 0, y: section.maxY, width: Self.width, height: SoftDropdown.footerHeight), animated: animated)
        placeSection(section, animated: animated)
        resize(section.maxY + SoftDropdown.footerHeight)
        alignColumns()
    }

    /// The section follows the blocks. Growing, it makes room at once; shrinking while the
    /// blocks slide, it waits for them so the last card never hangs below its edge.
    private func placeSection(_ section: NSRect, animated: Bool) {
        if animated, !Theme.reduceMotion, section.height < plate.section.height {
            pendingSection = section
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.pendingSection == section else { return }
                self.pendingSection = nil
                self.plate.section = section
                self.plate.frame = NSRect(x: 0, y: 0, width: Self.width, height: self.bounds.height)
            }
            return
        }
        pendingSection = nil
        plate.section = section
    }

    /// Sizes the view to its content: in the menu bar, shown at the dropdowns' scale with
    /// its bounds kept at full size, as `SoftDropdown.arrange` does.
    private func resize(_ height: CGFloat) {
        let full = NSSize(width: Self.width, height: height)
        let plateHeight = pendingSection == nil ? height : max(height, plate.section.maxY + SoftDropdown.footerHeight)
        plate.frame = NSRect(x: 0, y: 0, width: Self.width, height: plateHeight)
        face?.frame = NSRect(origin: .zero, size: full)
        let shown = preview ? full : NSSize(width: (Self.width * SoftDropdown.scale).rounded(), height: (height * SoftDropdown.scale).rounded())
        guard frame.size != shown || bounds.size != full else { return }
        setFrameSize(shown)
        setBoundsSize(full)
        onHeightChange?()
    }

    /// Every card's lines share one label column, and the cards of readings one figure and
    /// detail column, so the bars line up down the whole dashboard. Lists of apps keep
    /// their own, as in the dropdowns.
    private func alignColumns() {
        let cards = layout.compactMap { views[$0] }.flatMap(\.cards)
        let readings = cards.filter { !$0.listsApps }
        let column = SoftCard.column(labels: readings.map(\.labelWidth).max() ?? 0)
        let detailed = readings.filter { $0.detailNeed > 0 }
        let sharedDetail = detailed.map(\.detailNeed).max() ?? 0
        let sharedFigure = detailed.map(\.figureNeed).max() ?? 0
        for card in cards {
            card.column = card.listsApps ? SoftCard.column(labels: card.labelWidth) : column
            card.shared = card.listsApps || card.detailNeed == 0 ? (0, 0) : (sharedFigure, sharedDetail)
        }
    }

    private func configure(_ view: DashboardBlockView) {
        view.onResize = { [weak self] in
            guard let self, !self.applying else { return }
            self.apply(self.layout, animated: false)
        }
        if let apps = view as? AppsBlock { apps.interactive = !preview }
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
        alignColumns()
        showStatus()
    }

    private func showStatus() {
        head.status = DashboardStatus.make(layout, lastSystem, table: lastTable,
                                           agents: (views[.agents] as? AgentsBlock)?.running, plans: delegate.plans.plans,
                                           hidden: Set(delegate.settings.hiddenUsageAccounts))
    }

    func update(_ table: ProcessTable) {
        lastTable = table
        for block in layout { views[block]?.update(table) }
        alignColumns()
        showStatus()
    }

    // MARK: Actions

    @objc private func openWindow() { delegate.showWindow() }
    @objc private func openSettings() { delegate.showSettings() }
    @objc private func closeDashboard() { delegate.closeDashboard() }
    @objc private func openWhatsNew() { delegate.showWhatsNew() }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Customize Dashboard…", action: #selector(customize), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What's New in Wisp", action: #selector(openWhatsNew), keyEquivalent: "").target = self
        if layout.contains(.usage), let usage = views[.usage] as? UsageBlock {
            let items = usage.menuItems()
            if !items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func customize() { delegate.showSettings(section: .menuBar) }

    // MARK: Helpers

    static func split(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (text, "")
    }
}

extension MenuMetric {
    /// What the dropdown for this item shows, and the apps tab it opens on
    /// (CPU, Memory, Power, Net).
    var dropdown: (blocks: [DashboardBlock], appsTab: Int) {
        switch self {
        case .cpu: return ([.cpu, .cores, .apps], 0)
        case .memory: return ([.memory, .apps], 1)
        case .network: return ([.network, .apps], 3)
        case .gpu: return ([.gpu, .apps], 0)
        case .temperature: return ([.sensors, .cpu, .apps], 0)
        case .battery, .power: return ([.power, .apps], 2)
        case .disk: return ([.disk, .apps], 0)
        case .usage: return ([.usage], 0)
        }
    }
}
