import AppKit
import WispCore

/// Settings in their own window, as macOS apps keep them: a toolbar of sections over
/// the section's page. The window keeps its place and size between openings.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private unowned let delegate: AppDelegate
    private let page: SettingsPage

    init(delegate: AppDelegate) {
        self.delegate = delegate
        page = SettingsPage(delegate: delegate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.toolbarStyle = .preference
        window.collectionBehavior = [.fullScreenNone]
        super.init(window: window)

        let ground = SettingsGround()
        page.view.frame = ground.bounds
        page.view.autoresizingMask = [.width, .height]
        ground.addSubview(page.view)
        window.contentView = ground

        let toolbar = NSToolbar(identifier: "WispSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
        select(page.section)

        if !window.setFrameUsingName("WispSettings") { window.center() }
        window.setFrameAutosaveName("WispSettings")

        delegate.observeSystem { [weak self] snapshot in
            guard let self, self.isVisible else { return }
            self.page.update(system: snapshot)
        }
        delegate.observeTable { [weak self] table in
            guard let self, self.isVisible else { return }
            self.page.update(table: table)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible == true && window?.occlusionState.contains(.visible) == true }

    func show(_ section: SettingsPage.Section?) {
        if let section { select(section) }
        if MainWindowController.background {
            // Shown without taking focus, and off every screen.
            if let window {
                let screens = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
                window.setFrameOrigin(NSPoint(x: screens.maxX + 4000, y: screens.minY))
                window.orderBack(nil)
            }
        } else {
            NSApp.activate()
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
        updateDemand()
    }

    private func select(_ section: SettingsPage.Section) {
        page.loadViewIfNeeded()
        if page.section != section { page.show(section, animated: false) }
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section.rawValue)
        window?.title = section.title
        updateDemand()
    }

    @objc private func picked(_ sender: NSToolbarItem) {
        guard let section = SettingsPage.Section(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(section)
    }

    private func updateDemand() {
        delegate.settingsDemand = window?.isVisible == true ? page.demand : nil
    }

    // MARK: Window

    func windowDidChangeOcclusionState(_ notification: Notification) { updateDemand() }
    func windowWillClose(_ notification: Notification) { delegate.settingsDemand = nil }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.Section.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = SettingsPage.Section(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = section.title
        item.image = NSImage(systemSymbolName: section.sidebarSymbol, accessibilityDescription: section.title)
        item.target = self
        item.action = #selector(picked(_:))
        return item
    }
}

/// The settings window's ground, the same grey as the main window's pages.
private final class SettingsGround: NSView {
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.ground.cgColor
        }
    }
}
