import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Wisp"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        delegate.windowVisible = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func reveal(appID: String) {}

    func windowWillClose(_ notification: Notification) { delegate.mainWindowClosed() }
}
