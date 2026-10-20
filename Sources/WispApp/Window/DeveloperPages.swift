import AppKit
import WispCore

@MainActor
final class PortsPage: NSViewController, Page {
    private unowned let delegate: AppDelegate
    init(delegate: AppDelegate) { self.delegate = delegate; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}

@MainActor
final class DockerPage: NSViewController, Page {
    private unowned let delegate: AppDelegate
    init(delegate: AppDelegate) { self.delegate = delegate; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}

@MainActor
final class AgentsPage: NSViewController, Page {
    private unowned let delegate: AppDelegate
    init(delegate: AppDelegate, onSelect: @escaping (Selection?) -> Void) { self.delegate = delegate; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}
