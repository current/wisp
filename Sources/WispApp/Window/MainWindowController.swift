import AppKit
import WispCore

enum PageID: String, CaseIterable {
    case apps, cpu, memory, energy, disk, network, gpu, sensors, ports, docker, agents

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .sensors: return "Sensors"
        case .ports: return "Dev Servers"
        case .docker: return "Docker"
        case .agents: return "Coding Agents"
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .energy: return "bolt"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .gpu: return "cube.transparent"
        case .sensors: return "thermometer.medium"
        case .ports: return "server.rack"
        case .docker: return "shippingbox"
        case .agents: return "sparkles"
        }
    }

    static let sections: [(String?, [PageID])] = [
        (nil, [.apps]),
        ("Machine", [.cpu, .memory, .energy, .disk, .network, .gpu, .sensors]),
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
        show(.apps)

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
        case .apps: return AppsPage(delegate: delegate, onSelect: select)
        case .cpu, .memory, .energy, .disk, .network, .gpu:
            return MetricPage(id, delegate: delegate, onSelect: select)
        case .sensors: return SensorsPage(delegate: delegate)
        case .ports:
            let page = PortsPage(delegate: delegate)
            page.onSelect = select
            return page
        case .docker: return DockerPage(delegate: delegate)
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
