import AppKit
import WispCore

/// The question an assistant asks through Wisp: may I change the fans? One at a time, and
/// the default button leaves them as they are.
@MainActor
final class FanPrompt {
    static let shared = FanPrompt()
    private var open = false

    /// Returns false when a question is already on screen.
    func ask(_ mode: FanMode, current: FanMode?, reason: String) -> Bool {
        guard !open else { return false }
        open = true
        DispatchQueue.main.async { [self] in
            let alert = NSAlert()
            alert.messageText = "An assistant asks to set the fans to \(mode.title)"
            var detail = "The fans are on \(current?.title ?? "Automatic") now."
            if !reason.isEmpty { detail += "\n\n“\(reason)”" }
            alert.informativeText = detail + "\n\nYou can change it back on the Sensors page or from the menu bar."
            alert.addButton(withTitle: "Leave As Is")
            alert.addButton(withTitle: "Set to \(mode.title)")
            NSApp.activate()
            let answer = alert.runModal()
            open = false
            guard answer == .alertSecondButtonReturn else { return }
            FanService.shared.set(mode)
        }
        return true
    }
}
