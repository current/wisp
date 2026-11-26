import AppKit
import ObjectiveC

/// What VoiceOver would find on a surface, as text: every element with its role,
/// label, value and help, indented by depth, and whether it can be pressed. The
/// layout audit and the dropdown snapshots write one beside each picture, so a
/// drawn control that says nothing, or a press that goes nowhere, shows up in review.
/// The second part lists views that draw or take clicks but expose nothing at all.
@MainActor
enum AccessibilityDump {
    static func dump(_ root: NSView) -> String {
        var lines: [String] = []
        walk(root, depth: 0, into: &lines)
        var silent: [String] = []
        findSilent(root, path: [], inside: false, into: &silent)
        if !silent.isEmpty {
            lines.append("")
            lines.append("# Drawn or clickable views with nothing for VoiceOver")
            lines.append(contentsOf: silent)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ root: NSView, to url: URL) {
        try? dump(root).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func describe(_ element: NSObject) -> String {
        let accessible = element as? NSAccessibilityProtocol
        var parts: [String] = [accessible?.accessibilityRole()?.rawValue ?? "?"]
        if let label = accessible?.accessibilityLabel(), !label.isEmpty { parts.append("label=\"\(label)\"") }
        if let title = accessible?.accessibilityTitle(), !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let value = accessible?.accessibilityValue() { parts.append("value=\"\(value)\"") }
        if let help = accessible?.accessibilityHelp(), !help.isEmpty { parts.append("help=\"\(help)\"") }
        if pressable(element) { parts.append("[press]") }
        if let actions = accessible?.accessibilityCustomActions(), !actions.isEmpty {
            parts.append("actions=[" + actions.map(\.name).joined(separator: ", ") + "]")
        }
        if let view = element as? NSView, view.acceptsFirstResponder || view.canBecomeKeyView { parts.append("[key]") }
        parts.append("(\(type(of: element)))")
        return parts.joined(separator: " ")
    }

    /// A press that does something: an AppKit control, or a class of ours that
    /// overrides the press action.
    private static func pressable(_ element: NSObject) -> Bool {
        if element is NSControl { return true }
        let selector = #selector(NSView.accessibilityPerformPress)
        let base: AnyClass = element is NSView ? NSView.self : NSAccessibilityElement.self
        guard element.responds(to: selector) else { return false }
        return class_getMethodImplementation(type(of: element), selector) != class_getMethodImplementation(base, selector)
    }

    private static func walk(_ element: NSObject, depth: Int, into lines: inout [String]) {
        guard depth < 40 else { return }
        if let view = element as? NSView, view.isHiddenOrHasHiddenAncestor { return }
        let accessible = element as? NSAccessibilityProtocol
        let isElement = accessible?.isAccessibilityElement() ?? false
        if isElement { lines.append(String(repeating: "  ", count: depth) + describe(element)) }
        for child in accessible?.accessibilityChildren() ?? [] {
            guard let child = child as? NSObject else { continue }
            walk(child, depth: isElement ? depth + 1 : depth, into: &lines)
        }
    }

    private static func overrides(_ view: NSView, _ selector: Selector) -> Bool {
        class_getMethodImplementation(type(of: view), selector) != class_getMethodImplementation(NSView.self, selector)
    }

    /// A view of ours that draws or handles clicks, is not an element itself and has no
    /// element below it: whatever it shows is invisible to VoiceOver.
    private static func findSilent(_ view: NSView, path: [String], inside: Bool, into lines: inout [String]) {
        guard !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let name = String(describing: type(of: view))
        let here = path + [name]
        let ours = NSStringFromClass(type(of: view)).hasPrefix("WispApp.")
        // Inside an element, a view is part of that element's face.
        if ours, !inside, !view.isAccessibilityElement(), !hasElement(below: view) {
            let draws = overrides(view, #selector(NSView.draw(_:))) || overrides(view, #selector(NSView.updateLayer))
            let clicks = overrides(view, #selector(NSView.mouseDown(with:))) || overrides(view, #selector(NSView.mouseUp(with:)))
            let hovers = overrides(view, #selector(NSView.mouseMoved(with:))) || overrides(view, #selector(NSView.mouseEntered(with:)))
            if draws || clicks || hovers {
                let what = [draws ? "draws" : nil, clicks ? "clicks" : nil, hovers ? "hovers" : nil].compactMap { $0 }.joined(separator: ",")
                lines.append("\(what)\t\(here.suffix(4).joined(separator: " > "))\t\(Int(view.bounds.width))x\(Int(view.bounds.height))")
            }
        }
        for child in view.subviews { findSilent(child, path: here, inside: inside || view.isAccessibilityElement(), into: &lines) }
    }

    private static func hasElement(below view: NSView) -> Bool {
        for child in view.accessibilityChildren() ?? [] {
            if let element = child as? NSAccessibilityProtocol, element.isAccessibilityElement() { return true }
            if let child = child as? NSView, hasElement(below: child) { return true }
        }
        return false
    }
}
