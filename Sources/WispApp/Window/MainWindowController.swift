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

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private unowned let delegate: AppDelegate
    private let split = NSSplitViewController()
    private let sidebar: SidebarController
    private let container = NSViewController()
    let inspector: InspectorController
    private var inspectorItem: NSSplitViewItem!
    private var pages: [PageID: Page] = [:]
    private var current: Page?
    private(set) var currentID: PageID = .apps

    init(delegate: AppDelegate) {
        self.delegate = delegate
        sidebar = SidebarController()
        inspector = InspectorController(delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Wisp"
        window.backgroundColor = Theme.ground
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 480)
        window.setFrameAutosaveName("WispMain")
        super.init(window: window)

        container.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.addSplitViewItem(inspectorItem)
        split.splitView.autosaveName = "WispSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1120, height: 680))

        let toolbar = NSToolbar(identifier: "main")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        if !window.setFrameUsingName("WispMain") { window.center() }
        // For screenshots while other apps are in use.
        if ProcessInfo.processInfo.environment["WISP_FLOAT"] != nil { window.level = .floating }

        sidebar.onSelect = { [weak self] id in self?.show(id) }
        inspectorItem.isCollapsed = true
        show(.overview)

        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.isVisible else { return }
            self.current?.update(system: snapshot)
            self.inspector.update(system: snapshot)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.isVisible else { return }
            self.current?.update(table: table)
            self.inspector.update(table: table)
        }
        delegate.windowVisible = true
    }

    required init?(coder: NSCoder) { fatalError() }

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
        page.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        window?.subtitle = ""
        delegate.windowDemand = page.demand
        page.update(system: delegate.system)
        page.update(table: delegate.table)
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

    /// The inspector folds away when nothing is selected, so tables get the width.
    private func select(_ selection: Selection?) {
        inspector.show(selection)
        if inspectorItem.isCollapsed != (selection == nil) {
            inspectorItem.animator().isCollapsed = selection == nil
        }
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

/// What the inspector is looking at.
enum Selection: Equatable {
    case app(String)
    case process(Int32)
}
