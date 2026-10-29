import AppKit

/// The Tahoe toolbar over the page: the page's title and a subtitle on the left,
/// its controls on the right, each on a glass capsule. The page scrolls under it;
/// a short fade from the ground colour keeps the title readable.
@MainActor
final class Toolbar: NSView {
    static let height: CGFloat = 60
    private let fade = CAGradientLayer()
    private let defaultTitle = TextLine()
    private let defaultSubtitle = TextLine()
    private var heading: (NSView, NSView)?
    private var capsules: [GlassCapsule] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fade)
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        // Solid under the title and controls, then a short fade, so scrolled
        // content never shows through the heading.
        fade.locations = [0, 0.82, 1]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Shows a page: its own heading views if it has them, else its name and the machine.
    func show(title: String, subtitle: String, heading custom: (NSView, NSView)?, items: [NSView]) {
        heading.map { [$0.0, $0.1].forEach { $0.removeFromSuperview() } }
        defaultTitle.removeFromSuperview()
        defaultSubtitle.removeFromSuperview()
        if let custom {
            heading = custom
        } else {
            defaultTitle.text = Self.title(title)
            // Narrow toolbars drop the model name, then the line.
            let short = subtitle.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            defaultSubtitle.variants = [subtitle, short, ""].map(Self.subtitle)
            heading = (defaultTitle, defaultSubtitle)
        }
        if let heading { addSubview(heading.0); addSubview(heading.1) }
        capsules.forEach { $0.removeFromSuperview() }
        capsules = items.map { GlassCapsule(content: $0) }
        capsules.forEach(addSubview)
        needsLayout = true
    }

    static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(15, .bold), .foregroundColor: Theme.ink, .kern: -0.15])
    }

    static func subtitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary])
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 14)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fade.colors = [Theme.ground.cgColor, Theme.ground.cgColor, Theme.ground.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
        var right = bounds.width - 16
        for capsule in capsules.reversed() {
            let width = capsule.naturalWidth
            capsule.frame = NSRect(x: right - width, y: 13, width: width, height: 34)
            right -= width + 10
        }
        if let (title, subtitle) = heading {
            let width = max(80, right - 24 - 12)
            title.frame = NSRect(x: 24, y: 13, width: width, height: 19)
            subtitle.frame = NSRect(x: 24, y: 32, width: width, height: 14)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A control on a Liquid Glass capsule, as Tahoe toolbars place them.
final class GlassCapsule: NSView {
    let content: NSView
    private let surface: NSView
    private let holder = Holder()

    private final class Holder: NSView {
        override var isFlipped: Bool { true }
    }

    init(content: NSView) {
        self.content = content
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            surface = glass
        } else {
            let card = CardView()
            card.fill = Theme.card
            surface = card
        }
        super.init(frame: .zero)
        addSubview(surface)
        holder.addSubview(content)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = holder
        } else {
            surface.addSubview(holder)
        }
        (content as? Segmented)?.onGlass = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var naturalWidth: CGFloat {
        if let segmented = content as? Segmented { return segmented.naturalWidth + 2 }
        if let search = content as? NSSearchField {
            // Room for the whole placeholder: text, the magnifier and the clear button.
            let text = (search.placeholderString ?? "") as NSString
            return max(180, ceil(text.size(withAttributes: [.font: search.font ?? Theme.sans(13)]).width) + 100)
        }
        return max(34, content.fittingSize.width + 12)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        } else if let card = surface as? CardView {
            card.radius = bounds.height / 2
        }
        holder.frame = surface.bounds
        if content is Segmented {
            content.frame = bounds.insetBy(dx: 1, dy: 0)
        } else if content is NSSearchField {
            content.frame = NSRect(x: 8, y: (bounds.height - 22) / 2, width: bounds.width - 16, height: 22)
        } else {
            content.frame = bounds.insetBy(dx: 6, dy: 3)
        }
    }
}
