import AppKit
import WispCore

enum PageID: String, CaseIterable {
    case overview, apps, cpu, memory, energy, disk, network, gpu, neural, sound, bluetooth, sensors, ports, docker, agents

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
    func update(system: SystemSnapshot)
    func update(table: ProcessTable)
}

extension Page {
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
    let drawer: AppDrawer
    private var drawerOpen = false
    private var pages: [PageID: Page] = [:]
    private var current: Page?
    private(set) var currentID: PageID = .apps

    static let sidebarWidth: CGFloat = 228
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
        window.setFrameAutosaveName("WispMain")
        super.init(window: window)

        root.wantsLayer = true
        container.wantsLayer = true
        root.addSubview(container)
        root.addSubview(sidebar)
        root.addSubview(drawer)
        drawer.isHidden = true
        drawer.onClose = { [weak self] in self?.select(nil) }
        sidebar.onSelect = { [weak self] id in self?.show(id) }
        sidebar.onSettings = { [weak delegate] in delegate?.showSettings() }
        window.contentView = root
        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rootResized), name: NSView.frameDidChangeNotification, object: root)
        window.delegate = self
        if !window.setFrameUsingName("WispMain") { window.center() }
        // For screenshots while other apps are in use.
        if ProcessInfo.processInfo.environment["WISP_FLOAT"] != nil { window.level = .floating }
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
        // WISP_DRAWER=<app id> opens the drawer once data has arrived, for screenshots.
        if let id = ProcessInfo.processInfo.environment["WISP_DRAWER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.select(.app(id)) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func rootResized() { place(animated: false) }

    /// Sidebar on the left, the page in the middle, the drawer on the right when open.
    private func place(animated: Bool) {
        let bounds = root.bounds
        let inset = Self.inset
        sidebar.frame = NSRect(x: inset, y: inset, width: Self.sidebarWidth, height: bounds.height - inset * 2)
        let left = inset + Self.sidebarWidth
        let right = drawerOpen ? Self.drawerWidth + inset : 0
        container.frame = NSRect(x: left, y: 0, width: max(200, bounds.width - left - right), height: bounds.height)
        drawer.frame = NSRect(x: bounds.width - Self.drawerWidth - inset, y: inset, width: Self.drawerWidth, height: bounds.height - inset * 2)
        current?.view.frame = container.bounds
    }

    private var isVisible: Bool {
        guard let window else { return false }
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
        page.update(system: delegate.system)
        page.update(table: delegate.table)
        Motion.enter(page.view, from: CGPoint(x: 0, y: 8), duration: 0.22)
    }

    private func makePage(_ id: PageID) -> Page {
        let select: (Selection?) -> Void = { [weak self] selection in self?.select(selection) }
        switch id {
        case .overview: return OverviewPage(delegate: delegate, open: { [weak self] page in self?.show(page) })
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
        }
    }

    /// Opens the drawer for a selection, or closes it for nil. The page makes room
    /// first, then the drawer slides in, so nothing re-lays out while it moves.
    private func select(_ selection: Selection?) {
        if let selection {
            // A second click on what is already open closes it.
            if drawerOpen, drawer.selection == selection { return select(nil) }
            drawer.show(selection)
            guard !drawerOpen else { return }
            drawerOpen = true
            // Per-app network is measured only while something shows it.
            delegate.windowDemand = (current?.demand ?? []).union(.appNetwork)
            place(animated: false)
            drawer.isHidden = false
            Motion.enter(drawer, from: CGPoint(x: 28, y: 0), duration: 0.28)
        } else {
            guard drawerOpen else { return }
            drawerOpen = false
            delegate.windowDemand = current?.demand ?? []
            (current as? Deselecting)?.clearSelection()
            Motion.leave(drawer, to: CGPoint(x: 28, y: 0), duration: 0.18) { [weak self] in
                guard let self, !self.drawerOpen else { return }
                self.drawer.isHidden = true
                self.place(animated: false)
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
