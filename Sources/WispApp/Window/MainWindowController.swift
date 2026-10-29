import AppKit
import IOKit
import WispCore

enum PageID: String, CaseIterable {
    case overview, apps, cpu, memory, energy, disk, network, gpu, neural, sound, bluetooth, sensors, ports, docker, agents, settings

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .apps: return "Apps"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Power"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .neural: return "Neural Engine"
        case .sound: return "Sound"
        case .bluetooth: return "Bluetooth"
        case .sensors: return "Sensors"
        case .ports: return "Projects"
        case .docker: return "Containers"
        case .agents: return "Coding Agents"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .apps: return "list.bullet.rectangle"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .energy: return "bolt"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .gpu: return "cube.transparent"
        case .neural: return "brain"
        case .sound: return "speaker.wave.2"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .sensors: return "thermometer.medium"
        case .ports: return "folder"
        case .docker: return "shippingbox"
        case .agents: return "sparkles"
        case .settings: return "gearshape"
        }
    }

    static let sections: [(String?, [PageID])] = [
        (nil, [.overview, .apps]),
        ("Machine", [.cpu, .memory, .gpu, .neural, .energy, .disk, .network, .sound, .bluetooth, .sensors]),
        ("Developer", [.ports, .docker, .agents]),
    ]
}

/// A page in the main window. Pages are built when first shown and dropped with the window.
@MainActor
protocol Page: NSViewController {
    /// Readings this page needs on top of the system basics and the process table.
    var demand: Demand { get }
    var toolbarHeading: (NSView, NSView)? { get }
    var toolbarItems: [NSView] { get }
    func update(system: SystemSnapshot)
    func update(table: ProcessTable)
}

extension Page {
    /// The page's own heading for the toolbar (title and subtitle views), if it keeps one.
    var toolbarHeading: (NSView, NSView)? { nil }
    /// Controls the page puts in the toolbar, each on its own glass capsule.
    var toolbarItems: [NSView] { [] }
    var demand: Demand { [] }
    func update(system: SystemSnapshot) {}
    func update(table: ProcessTable) {}
}

/// The window's root: the grey ground everything floats on. Dragging empty
/// ground moves the window, as there is no title bar.
final class WindowGround: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ground.cgColor }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private unowned let delegate: AppDelegate
    private let root = WindowGround()
    private let sidebar = Sidebar()
    private let container = WindowGround()
    private let toolbar = Toolbar()
    let drawer: AppDrawer
    private var drawerOpen = false
    private var pages: [PageID: Page] = [:]
    private var current: Page?
    private(set) var currentID: PageID = .apps

    static let sidebarWidth: CGFloat = 248
    static let drawerWidth: CGFloat = 400
    static let inset: CGFloat = 8

    init(delegate: AppDelegate) {
        self.delegate = delegate
        drawer = AppDrawer(delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Wisp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.ground
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 620)
        // Test runs (sizes, parked or background windows) must not change the size people saved.
        let environment = ProcessInfo.processInfo.environment
        if !["WISP_SIZE", "WISP_PARK", "WISP_BACKGROUND", "WISP_AUDIT"].contains(where: { environment[$0] != nil }) {
            window.setFrameAutosaveName("WispMain")
        }
        super.init(window: window)

        root.wantsLayer = true
        container.wantsLayer = true
        root.addSubview(container)
        root.addSubview(toolbar)
        root.addSubview(sidebar)
        root.addSubview(drawer)
        drawer.isHidden = true
        drawer.onClose = { [weak self] in self?.select(nil) }
        sidebar.onSelect = { [weak self] id in self?.show(id) }
        sidebar.onSettings = { [weak self] in self?.show(.settings) }
        window.contentView = root
        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rootResized), name: NSView.frameDidChangeNotification, object: root)
        window.delegate = self
        if !window.setFrameUsingName("WispMain") { window.center() }
        // For screenshots while other apps are in use.
        if ProcessInfo.processInfo.environment["WISP_FLOAT"] != nil { window.level = .floating }
        // WISP_BACKGROUND keeps the window under every other window, for audits and benchmarks
        // that run while the Mac is in use. It still renders, and screencapture -l still sees it.
        if Self.background { window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) }
        if Self.parked { window.level = .floating }
        // WISP_SIZE=1440x900 sets the window size, for screenshots.
        if let size = ProcessInfo.processInfo.environment["WISP_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            window.center()
        }
        place(animated: false)
        show(.overview)
        sidebar.update(system: delegate.system)

        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.isVisible else { return }
            self.current?.update(system: snapshot)
            self.sidebar.update(system: snapshot)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.isVisible else { return }
            self.current?.update(table: table)
            if self.drawerOpen { self.drawer.update(table: table) }
        }
        delegate.windowVisible = true
        // WISP_AUDIT=<folder> visits every page, then the app drawer, audits each layout and
        // quits. It writes the page it is on to <folder>/now so a script can screenshot it.
        if let folder = ProcessInfo.processInfo.environment["WISP_AUDIT"] {
            runAudit(into: URL(fileURLWithPath: folder))
        }
        // WISP_DEMO=<app id> walks pages and the drawer on a timer, for recording the motion.
        if let id = ProcessInfo.processInfo.environment["WISP_DEMO"] {
            let steps: [(Double, (MainWindowController) -> Void)] = [
                (6, { $0.show(.cpu) }), (7.5, { $0.show(.sensors) }), (9, { $0.show(.memory) }),
                (10.5, { $0.select(.app(id)) }), (12.5, { $0.select(nil) }),
            ]
            for (delay, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in if let self { step(self) } }
            }
        }
        // WISP_DRAWER=<app id> opens the drawer once data has arrived, for screenshots.
        if let id = ProcessInfo.processInfo.environment["WISP_DRAWER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.select(.app(id)) }
            if ProcessInfo.processInfo.environment["WISP_DUMP_LAYERS"] != nil {
                Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    guard let root = self?.window?.contentView?.superview?.layer else { return }
                    var lines: [String] = []
                    func walk(_ layer: CALayer, _ depth: Int) {
                        if layer.drawsAsynchronously {
                            var chain: [String] = []
                            var l: CALayer? = layer
                            while let current = l { chain.append(current.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: current))); l = current.superlayer }
                            lines.append("\(layer.bounds.size) " + chain.prefix(8).joined(separator: " < "))
                        }
                        layer.sublayers?.forEach { walk($0, depth + 1) }
                    }
                    walk(root, 0)
                    let entry = "\(Int(Date().timeIntervalSince1970) % 1000): " + lines.joined(separator: " | ") + "\n"
                    if let handle = FileHandle(forWritingAtPath: "/tmp/wisp-layers.txt") {
                        handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
                    } else {
                        try? entry.write(toFile: "/tmp/wisp-layers.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func runAudit(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = folder.appendingPathComponent("report.tsv")
        let now = folder.appendingPathComponent("now")
        let size = window.map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height))" } ?? "?"
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        var steps: [(String, () -> Void)] = PageID.allCases.map { page in (page.rawValue, { [weak self] in self?.show(page) }) }
        steps.append(("drawer", { [weak self] in
            guard let self, let app = self.delegate.table.apps.max(by: { $0.memory < $1.memory }) else { return }
            self.show(.apps)
            self.select(.app(app.id))
        }))
        var lines: [String] = []
        func run(_ index: Int) {
            guard index < steps.count else {
                try? lines.joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
                try? "done".write(to: now, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                return
            }
            let (name, step) = steps[index]
            step()
            // Let data arrive, layouts settle and entrance animations finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                root.layoutSubtreeIfNeeded()
                for issue in LayoutAudit.audit(root) { lines.append("\(appearance)\t\(size)\t\(name)\t\(issue)") }
                try? name.write(to: now, atomically: true, encoding: .utf8)
                // The script screenshots while the page holds still.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { run(index + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { run(0) }
    }

    @objc private func rootResized() { place(animated: false) }

    /// Sidebar on the left, the page in the middle, the drawer on the right when open.
    private func place(animated: Bool) {
        let bounds = root.bounds
        let inset = Self.inset
        sidebar.frame = NSRect(x: inset, y: inset, width: Self.sidebarWidth, height: bounds.height - inset * 2)
        let left = inset + Self.sidebarWidth
        // `drawerProgress` runs 0 to 1 as the drawer opens: the page gives up its
        // right edge at the same rate the drawer slides in, so they move as one.
        // When the page would be left narrower than 480 pt, the drawer lies over it instead.
        let squeezes = bounds.width - left - Self.drawerWidth - inset >= 480
        let room = (Self.drawerWidth + inset) * drawerProgress
        container.frame = NSRect(x: left, y: 0, width: max(200, bounds.width - left - (squeezes ? room : 0)), height: bounds.height)
        drawer.frame = NSRect(x: bounds.width - room, y: inset, width: Self.drawerWidth, height: bounds.height - inset * 2)
        // Lying over the page, the drawer needs an edge. The shadow has a path, so Core
        // Animation does not have to render the drawer offscreen to find its outline.
        drawer.wantsLayer = true
        if let layer = drawer.layer {
            layer.shadowOpacity = squeezes ? 0 : 0.16
            if !squeezes {
                layer.shadowRadius = 18
                layer.shadowOffset = .zero
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowPath = CGPath(roundedRect: drawer.bounds, cornerWidth: 20, cornerHeight: 20, transform: nil)
            }
        }
        current?.view.frame = container.bounds
        toolbar.frame = NSRect(x: container.frame.minX, y: 0, width: container.frame.width, height: Toolbar.height)
        placeWindowButtons()
    }

    /// "MacBook Pro · Apple M3 Max · 36 GB", under each page's title.
    static let machineSubtitle: String = {
        // "MacBook Pro (14-inch, Nov 2023)" from the device tree, without the brackets.
        var family = "Mac"
        let expert = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if expert != 0 {
            if let data = IORegistryEntryCreateCFProperty(expert, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data,
               let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) {
                family = name.components(separatedBy: " (").first ?? name
            }
            IOObjectRelease(expert)
        }
        return family + " · Apple " + Sidebar.machineName()
    }()

    /// The window buttons sit inside the floating sidebar, on its padding, rather
    /// than in the window corner where AppKit puts them.
    private var buttonSpacing: CGFloat?

    private func placeWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        if buttonSpacing == nil { buttonSpacing = max(18, mini.frame.minX - close.frame.minX) }
        let spacing = buttonSpacing ?? 20
        let height: CGFloat = 50
        let containerFrame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        let left = Self.inset + 20
        for (index, button) in [close, mini, zoom].enumerated() {
            let origin = NSPoint(x: left + CGFloat(index) * spacing,
                                 y: titlebar.bounds.height - (Self.inset + 22) - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    func windowDidResize(_ notification: Notification) { placeWindowButtons() }
    func windowDidBecomeKey(_ notification: Notification) { placeWindowButtons() }
    func windowDidResignKey(_ notification: Notification) { placeWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { placeWindowButtons() }

    /// 0 when the drawer is shut, 1 when it is open; in between while it moves.
    private var drawerProgress: CGFloat = 0
    private var drawerMotion: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    private var displayLink: CADisplayLink?

    /// Moves the drawer and the page together, one layout per screen refresh.
    /// About 0.3 s of relayout per open or close; nothing runs once it settles.
    private func moveDrawer(to target: CGFloat, done: (() -> Void)? = nil) {
        drawerDone = done
        guard !Theme.reduceMotion, window?.isVisible == true else {
            drawerProgress = target
            place(animated: false)
            finishDrawer()
            return
        }
        drawerMotion = (drawerProgress, target, CACurrentMediaTime(), target > drawerProgress ? 0.36 : 0.28)
        if displayLink == nil {
            displayLink = root.displayLink(target: self, selector: #selector(drawerFrame(_:)))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    private var drawerDone: (() -> Void)?

    @objc private func drawerFrame(_ link: CADisplayLink) {
        guard let motion = drawerMotion else { return finishDrawer() }
        let t = min(1, (CACurrentMediaTime() - motion.start) / motion.duration)
        // Smooth out: quick to start, long soft landing (0.22, 1, 0.36, 1).
        let eased = CGFloat(Motion.smoothOut(t))
        drawerProgress = motion.from + (motion.to - motion.from) * eased
        drawer.alphaValue = min(1, drawerProgress * 2.5)
        place(animated: false)
        if t >= 1 { finishDrawer() }
    }

    private func finishDrawer() {
        displayLink?.invalidate()
        displayLink = nil
        drawerMotion = nil
        drawer.alphaValue = drawerProgress > 0 ? 1 : 0
        let done = drawerDone
        drawerDone = nil
        done?()
    }

    static let background = ProcessInfo.processInfo.environment["WISP_BACKGROUND"] != nil
    /// WISP_PARK shows the window almost entirely past the right edge of the screen, above
    /// other windows: macOS counts it as visible, so it updates and draws as it would in use,
    /// while only a 24 pt strip covers the screen. For benchmarks run while the Mac is in use.
    static let parked = ProcessInfo.processInfo.environment["WISP_PARK"] != nil

    private var isVisible: Bool {
        guard let window else { return false }
        if Self.background { return window.isVisible }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    func show(_ id: PageID) {
        currentID = id
        sidebar.select(id)
        let page = pages[id] ?? makePage(id)
        pages[id] = page
        guard page !== current else { return }
        if current != nil { select(nil) }
        current?.view.removeFromSuperview()
        current = page
        page.view.translatesAutoresizingMaskIntoConstraints = true
        page.view.autoresizingMask = [.width, .height]
        page.view.frame = container.bounds
        container.addSubview(page.view)
        delegate.windowDemand = page.demand
        toolbar.show(title: id.title, subtitle: Self.machineSubtitle, heading: page.toolbarHeading, items: page.toolbarItems)
        page.update(system: delegate.system)
        page.update(table: delegate.table)
        if let cards = page as? CardPage {
            // Lay out now so the cascade knows where each card sits.
            cards.view.layoutSubtreeIfNeeded()
            Motion.cascade(cards.canvas.subviews, in: cards.scroll.documentVisibleRect)
        } else {
            Motion.enter(page.view, from: CGPoint(x: 0, y: 8), duration: 0.22)
        }
    }

    private func makePage(_ id: PageID) -> Page {
        let select: (Selection?) -> Void = { [weak self] selection in self?.select(selection) }
        switch id {
        case .overview: return OverviewPage(delegate: delegate, open: { [weak self] page in self?.show(page) }, select: select)
        case .apps: return AppsPage(delegate: delegate, onSelect: select)
        case .cpu: return CPUPage(title: "CPU", metric: .cpu, delegate: delegate, onSelect: select)
        case .memory: return MemoryPage(title: "Memory", metric: .memory, delegate: delegate, onSelect: select)
        case .disk: return DiskPage(title: "Disk", metric: .diskRead, delegate: delegate, onSelect: select)
        case .network: return NetworkPage(title: "Network", metric: .networkIn, delegate: delegate, onSelect: select)
        case .gpu: return GPUPage(title: "GPU", metric: .gpu, delegate: delegate, onSelect: select)
        case .energy: return EnergyPage(title: "Power", metric: .power, delegate: delegate, onSelect: select)
        case .sensors: return SensorsCardPage(delegate: delegate)
        case .neural: return NeuralPage(title: "Neural Engine", metric: .power, delegate: delegate, onSelect: select)
        case .sound: return SoundPage(delegate: delegate)
        case .bluetooth: return BluetoothPage(delegate: delegate)
        case .ports:
            let page = ProjectsPage(delegate: delegate)
            page.onSelect = select
            return page
        case .docker: return ContainersPage(title: "Containers", metric: .cpu, delegate: delegate, onSelect: select)
        case .agents: return AgentsPage(delegate: delegate, onSelect: select)
        case .settings: return SettingsPage(delegate: delegate)
        }
    }

    /// Opens the drawer for a selection, or closes it for nil. The drawer slides in
    /// while the page narrows beside it, and the reverse on close.
    private func select(_ selection: Selection?) {
        if let selection {
            // A second click on what is already open closes it.
            if drawerOpen, drawer.selection == selection { return select(nil) }
            drawer.show(selection)
            guard !drawerOpen else { return drawer.revealContent() }
            drawerOpen = true
            // Per-app network is measured only while something shows it.
            delegate.windowDemand = (current?.demand ?? []).union(.appNetwork)
            drawer.isHidden = false
            drawer.revealContent()
            moveDrawer(to: 1)
        } else {
            guard drawerOpen else { return }
            drawerOpen = false
            delegate.windowDemand = current?.demand ?? []
            (current as? Deselecting)?.clearSelection()
            moveDrawer(to: 0) { [weak self] in
                guard let self, !self.drawerOpen else { return }
                self.drawer.isHidden = true
            }
        }
    }

    /// Esc closes the drawer.
    override func cancelOperation(_ sender: Any?) {
        if drawerOpen { select(nil) }
    }

    func reveal(appID: String) {
        show(.apps)
        (pages[.apps] as? AppsPage)?.select(appID: appID)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        delegate.windowVisible = isVisible
    }

    func windowDidMiniaturize(_ notification: Notification) { delegate.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { delegate.windowVisible = true }
    func windowWillClose(_ notification: Notification) { delegate.mainWindowClosed() }
}

/// Pages that keep a selected row clear it when the drawer closes.
@MainActor
protocol Deselecting {
    func clearSelection()
}

/// Entrances and exits, all on Core Animation: a short slide and a fade,
/// nothing when Reduce Motion is on.
@MainActor
enum Motion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// cubic-bezier(0.22, 1, 0.36, 1) evaluated at time t, for motion driven frame by frame.
    static func smoothOut(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.22, 1.0, 0.36, 1.0)
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        // Solve x(s) = t by bisection; a dozen steps is well under a pixel.
        var low = 0.0, high = 1.0, s = t
        for _ in 0..<14 {
            s = (low + high) / 2
            if bezier(s, x1, x2) < t { low = s } else { high = s }
        }
        return bezier(s, y1, y2)
    }

    static func enter(_ view: NSView, from offset: CGPoint, duration: CFTimeInterval) {
        guard !Theme.reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        move.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = ease
        layer.add(group, forKey: "enter")
    }

    /// Brings a page's cards in one after another from top to bottom, only those
    /// on screen. Each is a transform and opacity animation the render server runs.
    static func cascade(_ views: [NSView], in visible: NSRect, offset: CGFloat = 10) {
        guard !Theme.reduceMotion else { return }
        let shown = views.filter { $0.frame.intersects(visible) && !$0.isHidden }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .prefix(12)
        let now = CACurrentMediaTime()
        for (index, view) in shown.enumerated() {
            guard let layer = view.layer else { continue }
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = CATransform3DMakeTranslation(0, offset, 0)
            move.toValue = CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.34
            group.beginTime = now + Double(index) * 0.028
            group.fillMode = .backwards
            group.timingFunction = ease
            layer.add(group, forKey: "enter")
        }
    }

    static func leave(_ view: NSView, to offset: CGPoint, duration: CFTimeInterval, then done: @escaping () -> Void) {
        guard !Theme.reduceMotion, let layer = view.layer else { return done() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DIdentity
        move.toValue = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { layer.removeAnimation(forKey: "leave") }
    }
}

/// What the inspector is looking at.
enum Selection: Equatable {
    case app(String)
    case process(Int32)
}

extension MachinePage: Deselecting {
    func clearSelection() { table.selectedID = nil }
}

extension AppsPage: Deselecting {
    func clearSelection() { outline.deselectAll(nil) }
}
