import AppKit

/// The menu bar at the top of the screen while Wisp is the active app: About,
/// Settings (⌘,), Hide and Quit, the editing commands the search field needs,
/// a View menu with a ⌘ shortcut for the first nine pages, and Window.
@MainActor
enum MainMenu {
    static func install(delegate: AppDelegate) {
        let bar = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Wisp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(Item("Settings…", key: ",") { delegate.showSettings() })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Wisp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Wisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Wisp", to: bar)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f").tag =
            NSTextFinder.Action.showFindInterface.rawValue
        add(edit, titled: "Edit", to: bar)

        let view = NSMenu(title: "View")
        for page in PageID.allCases where page != .settings {
            view.addItem(Item(page.title, key: page.shortcut ?? "") { delegate.showPage(page) })
        }
        add(view, titled: "View", to: bar)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, titled: "Window", to: bar)
        NSApp.windowsMenu = window

        NSApp.mainMenu = bar
    }

    private static func add(_ menu: NSMenu, titled title: String, to bar: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }

    /// A menu item that runs a closure.
    final class Item: NSMenuItem {
        private let run: () -> Void

        init(_ title: String, key: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: key)
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { run() }
    }
}
