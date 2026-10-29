import AppKit
import QuartzCore
import WispCore

/// Settings > Menu Bar: the dashboard at a smaller scale, live, next to the blocks
/// it can hold. Drag a block from the list onto the preview to add it, drag inside
/// the preview to reorder, drag it off (or press its remove button) to take it out.
///
/// The block being dragged is a bitmap on its own layer that follows the pointer;
/// the others slide on the render server. Nothing here draws per frame.
@MainActor
final class DashboardBuilder: DrawnView {
    private unowned let delegate: AppDelegate
    static let scale: CGFloat = 0.6
    private let inset: CGFloat = 20
    /// Room under the preview so a block dragged in has somewhere to go.
    private let slack: CGFloat = 150

    private let stage = CardView()
    private let holder = Holder()
    let preview: DashboardView
    private let paletteTitle = TextLine(NSAttributedString(string: "Blocks", attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.ink]))
    private let paletteNote = TextLine(Theme.caption("Drag one onto the preview, or click to add it."))
    private var chips: [PaletteChip] = []
    private let removeButton = RemoveButton()
    private let indicator = CAShapeLayer()
    private var drag: Drag?
    private var hovered: DashboardBlock?
    private var elements: [BlockElement] = []
    /// Asks the settings page to lay out again when the builder's height changes.
    var onHeightChange: (() -> Void)?

    private final class Holder: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct Drag {
        var block: DashboardBlock
        var fromPalette: Bool
        var start: NSPoint
        var grab = CGPoint.zero
        var started = false
        var ghost: CALayer?
        var remaining: [DashboardBlock]
        var index: Int?
        var height: CGFloat = 0
    }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        preview = DashboardView(delegate: delegate, preview: true)
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 600))
        wantsLayer = true
        stage.fill = Theme.ground
        stage.radius = Theme.panelRadius * Self.scale
        addSubview(stage)
        holder.wantsLayer = true
        holder.addSubview(preview)
        addSubview(holder)
        for view in [paletteTitle, paletteNote] as [NSView] { addSubview(view) }
        for block in DashboardBlock.allCases {
            let chip = PaletteChip(block)
            chip.onPress = { [weak self] in self?.add(block) }
            chips.append(chip)
            addSubview(chip)
        }
        removeButton.isHidden = true
        removeButton.onPress = { [weak self] in
            guard let self, let block = self.hovered else { return }
            self.remove(block)
        }
        addSubview(removeButton)
        indicator.opacity = 0
        indicator.zPosition = 50
        indicator.lineWidth = 1.5
        indicator.lineDashPattern = [5, 4]
        layer?.addSublayer(indicator)
        preview.onHeightChange = { [weak self] in self?.previewResized() }
        refreshChips()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dashboard layout")
        if ProcessInfo.processInfo.environment["WISP_BUILDER_DEMO"] != nil { scheduleDemo() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var layoutBlocks: [DashboardBlock] { delegate.settings.dashboard }

    // MARK: Layout

    private var stageOrigin: NSPoint { NSPoint(x: inset, y: inset) }
    private var paletteX: CGFloat { inset + DashboardView.width * Self.scale + 28 }
    private static let chipHeight: CGFloat = 42
    private static let chipGap: CGFloat = 6

    /// The builder's height for the saved layout.
    var preferredHeight: CGFloat {
        let committed = committedPreviewHeight
        let stageBottom = inset + (committed + slack) * Self.scale + inset
        let paletteBottom = 66 + CGFloat(chips.count) * (Self.chipHeight + Self.chipGap) - Self.chipGap + inset
        return ceil(max(stageBottom, paletteBottom))
    }

    private var committedPreviewHeight: CGFloat = 0

    override func layout() {
        super.layout()
        if drag == nil { committedPreviewHeight = preview.frame.height }
        placeHolder()
        stage.frame = scaled(NSRect(origin: .zero, size: preview.frame.size))
        let x = paletteX
        let width = max(120, bounds.width - x - inset)
        paletteTitle.frame = NSRect(x: x, y: inset, width: width, height: 18)
        paletteNote.frame = NSRect(x: x, y: inset + 20, width: width, height: 16)
        for (index, chip) in chips.enumerated() {
            chip.frame = NSRect(x: x, y: 66 + CGFloat(index) * (Self.chipHeight + Self.chipGap), width: width, height: Self.chipHeight)
        }
        placeRemoveButton()
    }

    /// The preview keeps its full-size coordinates; the holder's bounds scale it
    /// down, so AppKit still knows which part of it is on screen.
    private func placeHolder() {
        let size = preview.frame.size
        holder.frame = NSRect(x: stageOrigin.x, y: stageOrigin.y, width: size.width * Self.scale, height: size.height * Self.scale)
        holder.bounds = NSRect(origin: .zero, size: size)
        preview.frame.origin = .zero
    }

    /// A rect in the preview's coordinates, in the builder's.
    private func scaled(_ rect: NSRect) -> NSRect {
        NSRect(x: stageOrigin.x + rect.minX * Self.scale, y: stageOrigin.y + rect.minY * Self.scale,
               width: rect.width * Self.scale, height: rect.height * Self.scale)
    }

    private func previewY(_ y: CGFloat) -> CGFloat { (y - stageOrigin.y) / Self.scale }

    /// The preview grew or shrank: the panel behind it follows, sliding like the blocks.
    private func previewResized() {
        placeHolder()
        let target = scaled(NSRect(origin: .zero, size: preview.frame.size))
        guard drag != nil || !Theme.reduceMotion, let layer = stage.layer, stage.frame != target, window != nil else {
            stage.frame = target
            return
        }
        let fromBounds = layer.presentation()?.bounds ?? layer.bounds
        let fromPosition = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = target
        CATransaction.commit()
        for (key, from, to) in [("bounds", NSValue(rect: fromBounds), NSValue(rect: layer.bounds)),
                                ("position", NSValue(point: fromPosition), NSValue(point: layer.position))] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 0.34
            animation.timingFunction = DashboardView.smoothOut
            layer.add(animation, forKey: key)
        }
    }

    // MARK: Data

    func update(system: SystemSnapshot) { preview.update(system, history: delegate.monitor.history) }
    func update(table: ProcessTable) { preview.update(table) }

    private func refreshChips() {
        let shown = Set(layoutBlocks)
        for chip in chips { chip.inUse = shown.contains(chip.block) }
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Chips and the preview are drawn; the builder takes their clicks and drags.
        guard let hit = super.hitTest(point) else { return nil }
        return hit === removeButton ? hit : self
    }

    private func block(at point: NSPoint) -> DashboardBlock? {
        preview.frames().first { scaled($0.1).contains(point) }?.0
    }

    private func chip(at point: NSPoint) -> PaletteChip? {
        chips.first { $0.frame.contains(point) }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        setHovered(block(at: point) ?? (removeButton.frame.contains(point) ? hovered : nil))
        for chip in chips { chip.hovering = chip.frame.contains(point) && !chip.inUse }
        if hovered != nil || chip(at: point).map({ !$0.inUse }) == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        setHovered(nil)
        chips.forEach { $0.hovering = false }
        NSCursor.arrow.set()
    }

    private func setHovered(_ block: DashboardBlock?) {
        guard block != hovered else { return }
        hovered = block
        placeRemoveButton()
    }

    private func placeRemoveButton() {
        guard drag == nil, let hovered, let view = preview.view(for: hovered), view.superview != nil else {
            removeButton.isHidden = true
            return
        }
        let rect = scaled(view.frame)
        removeButton.frame = NSRect(x: rect.maxX - 13, y: rect.minY - 7, width: 20, height: 20)
        removeButton.label = "Remove \(hovered.title)"
        removeButton.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let block = block(at: point) {
            drag = Drag(block: block, fromPalette: false, start: point, remaining: layoutBlocks.filter { $0 != block })
        } else if let chip = chip(at: point), !chip.inUse {
            chip.pressed = true
            drag = Drag(block: chip.block, fromPalette: true, start: point, remaining: layoutBlocks)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        moveDrag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        if current.started {
            endDrag()
        } else {
            drag = nil
            chips.forEach { $0.pressed = false }
            if current.fromPalette { add(current.block) }
        }
    }

    // MARK: Dragging

    private func moveDrag(to point: NSPoint) {
        guard var current = drag else { return }
        if !current.started {
            guard hypot(point.x - current.start.x, point.y - current.start.y) > 3 else { return }
            current = beginDrag(current)
        }
        guard let ghost = current.ghost else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.position = CGPoint(x: point.x - current.grab.x + ghost.bounds.width / 2, y: point.y - current.grab.y + ghost.bounds.height / 2)
        CATransaction.commit()

        let center = ghost.position
        let stageRect = scaled(NSRect(origin: .zero, size: NSSize(width: DashboardView.width, height: committedPreviewHeight)))
        let inside = center.x > stageRect.minX - 24 && center.x < stageRect.maxX + 24 && center.y > 0 && center.y < bounds.height
        let index = inside ? insertionIndex(forY: center.y, in: current.remaining) : nil
        if index != current.index {
            current.index = index
            preview.apply(current.remaining, gap: index.map { DashboardView.Gap(index: $0, height: current.height) }, animated: true)
            showIndicator(index != nil)
            // Off the preview, a block from the preview will be removed on release; it says so by fading.
            if !current.fromPalette {
                ghost.opacity = index == nil ? 0.5 : 1
            }
        }
        drag = current
    }

    private func beginDrag(_ start: Drag) -> Drag {
        var current = start
        current.started = true
        setHovered(nil)
        removeButton.isHidden = true
        NSCursor.closedHand.set()
        let rect: NSRect
        let image: CGImage?
        let radius: CGFloat
        if current.fromPalette, let chip = chips.first(where: { $0.block == current.block }) {
            rect = chip.frame
            image = snapshot(chip, scale: 1)
            radius = 10
            chip.placeholder = true
            current.height = preview.prepare(current.block).height
        } else if let view = preview.view(for: current.block), let index = layoutBlocks.firstIndex(of: current.block) {
            rect = scaled(view.frame)
            image = snapshot(view, scale: Self.scale)
            radius = Theme.radius * Self.scale
            current.height = view.height
            current.index = index
            preview.apply(current.remaining, gap: DashboardView.Gap(index: index, height: view.height), animated: false)
        } else {
            return current
        }
        current.grab = CGPoint(x: current.start.x - rect.minX, y: current.start.y - rect.minY)
        let ghost = CALayer()
        ghost.contents = image
        ghost.contentsScale = window?.backingScaleFactor ?? 2
        ghost.frame = rect
        ghost.cornerRadius = radius
        ghost.cornerCurve = .continuous
        ghost.zPosition = 100
        // The shadow has its own path, so Core Animation never has to work it out from the bitmap.
        ghost.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowRadius = 14
        ghost.shadowOffset = CGSize(width: 0, height: isFlippedLayer ? 8 : -8)
        ghost.shadowOpacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(ghost)
        CATransaction.commit()
        current.ghost = ghost
        if !Theme.reduceMotion {
            ghost.transform = CATransform3DMakeScale(1.04, 1.04, 1)
            ghost.shadowOpacity = 0.22
            let lift = CASpringAnimation(keyPath: "transform.scale")
            lift.fromValue = 1
            lift.toValue = 1.04
            lift.damping = 18
            lift.stiffness = 320
            lift.duration = lift.settlingDuration
            ghost.add(lift, forKey: "lift")
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = 0
            shadow.toValue = 0.22
            shadow.duration = 0.2
            ghost.add(shadow, forKey: "shadow")
        }
        if current.index != nil {
            indicatorPath(height: current.height)
            showIndicator(true)
        }
        return current
    }

    private func endDrag() {
        guard let current = drag, let ghost = current.ghost else {
            drag = nil
            return
        }
        drag = nil
        showIndicator(false)
        chips.forEach { $0.pressed = false }
        if current.index != nil { chips.forEach { $0.placeholder = false } }
        if let index = current.index {
            var next = current.remaining
            next.insert(current.block, at: min(index, next.count))
            let slot = preview.gapRect.map(scaled)
            preview.apply(next, animated: true)
            let target = slot ?? preview.view(for: current.block).map { scaled($0.frame) } ?? ghost.frame
            settle(ghost, to: target, fade: current.fromPalette)
            commit(next)
        } else if current.fromPalette, let chip = chips.first(where: { $0.block == current.block }) {
            settle(ghost, to: chip.frame, fade: false) { chip.placeholder = false }
        } else {
            vanish(ghost)
            commit(current.remaining)
        }
    }

    /// Where a block dropped at builder y `y` would go among `blocks`.
    private func insertionIndex(forY y: CGFloat, in blocks: [DashboardBlock]) -> Int {
        let target = previewY(y)
        var top = DashboardView.blocksTop
        for (index, block) in blocks.enumerated() {
            let height = preview.prepare(block).height
            if target < top + height / 2 { return index }
            top += height + DashboardView.spacing
        }
        return blocks.count
    }

    /// The ghost springs into place, then hands over to the real block under it.
    private func settle(_ ghost: CALayer, to rect: NSRect, fade: Bool, then done: (() -> Void)? = nil) {
        let target = CGPoint(x: rect.midX, y: rect.midY)
        guard !Theme.reduceMotion else {
            ghost.removeFromSuperlayer()
            done?()
            return
        }
        let from = ghost.presentation()?.position ?? ghost.position
        let fromScale = ghost.presentation()?.value(forKeyPath: "transform.scale") ?? 1.04
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.position = target
        ghost.transform = CATransform3DIdentity
        ghost.shadowOpacity = 0
        ghost.opacity = fade ? 0 : 1
        CATransaction.commit()
        CATransaction.begin()
        let move = CASpringAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: target)
        move.damping = 20
        move.stiffness = 260
        move.duration = move.settlingDuration
        CATransaction.setCompletionBlock {
            ghost.removeFromSuperlayer()
            done?()
        }
        ghost.add(move, forKey: "settle")
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = fromScale
        scale.toValue = 1
        scale.damping = 20
        scale.stiffness = 260
        scale.duration = scale.settlingDuration
        ghost.add(scale, forKey: "scale")
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.22
        shadow.toValue = 0
        shadow.duration = 0.3
        ghost.add(shadow, forKey: "shadow")
        if fade {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 1
            opacity.toValue = 0
            opacity.beginTime = CACurrentMediaTime() + 0.12
            opacity.duration = 0.2
            opacity.fillMode = .backwards
            ghost.add(opacity, forKey: "fade")
        }
        CATransaction.commit()
    }

    /// A block dropped off the preview shrinks away.
    private func vanish(_ ghost: CALayer) {
        guard !Theme.reduceMotion else { return ghost.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        ghost.opacity = 0
        ghost.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        CATransaction.commit()
    }

    // MARK: Drop indicator

    private var isFlippedLayer: Bool { layer?.isGeometryFlipped == false && isFlipped }

    private func indicatorPath(height: CGFloat) {
        let size = CGSize(width: (DashboardView.width - DashboardView.outer * 2) * Self.scale, height: height * Self.scale)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.fillColor = Theme.accent.withAlphaComponent(0.07).cgColor
            indicator.strokeColor = Theme.accent.withAlphaComponent(0.7).cgColor
        }
        let radius = Theme.radius * Self.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.bounds = CGRect(origin: .zero, size: size)
        indicator.path = CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    private func showIndicator(_ on: Bool) {
        guard on, let rect = preview.gapRect.map(scaled) else {
            indicator.opacity = 0
            return
        }
        let target = CGPoint(x: rect.midX, y: rect.midY)
        if indicator.opacity == 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicator.position = target
            CATransaction.commit()
            indicator.opacity = 1
        } else {
            let from = indicator.presentation()?.position ?? indicator.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicator.position = target
            CATransaction.commit()
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: from)
            slide.toValue = NSValue(point: target)
            slide.duration = 0.34
            slide.timingFunction = DashboardView.smoothOut
            indicator.add(slide, forKey: "slide")
        }
    }

    // MARK: Changes

    private func commit(_ blocks: [DashboardBlock]) {
        let before = preferredHeight
        delegate.change { $0.dashboard = blocks }
        refreshChips()
        committedPreviewHeight = preview.frame.height
        needsLayout = true
        if preferredHeight != before {
            // Wait for the slides to finish before the settings page lays out again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onHeightChange?() }
        }
    }

    func add(_ block: DashboardBlock, at index: Int? = nil) {
        guard !layoutBlocks.contains(block) else { return }
        var next = layoutBlocks
        next.insert(block, at: min(index ?? next.count, next.count))
        preview.apply(next, animated: true)
        commit(next)
    }

    func remove(_ block: DashboardBlock) {
        let next = layoutBlocks.filter { $0 != block }
        setHovered(nil)
        guard let view = preview.view(for: block), let layer = view.layer, !Theme.reduceMotion else {
            preview.apply(next, animated: true)
            return commit(next)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            layer.removeAllAnimations()
            layer.opacity = 1
            self?.preview.apply(next, animated: true)
            self?.commit(next)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.16
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "remove")
        CATransaction.commit()
    }

    func move(_ block: DashboardBlock, by offset: Int) {
        guard let index = layoutBlocks.firstIndex(of: block) else { return }
        let target = index + offset
        guard layoutBlocks.indices.contains(target) else { return }
        let next = DashboardBlock.moving(block, to: target, in: layoutBlocks)
        preview.apply(next, animated: true)
        commit(next)
    }

    func reset() {
        preview.apply(DashboardBlock.defaultLayout, animated: true)
        commit(DashboardBlock.defaultLayout)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let block = block(at: point) { return menu(for: block) }
        if let chip = chip(at: point), !chip.inUse {
            let menu = NSMenu()
            menu.addItem(MenuAction("Add to Dashboard") { [weak self] in self?.add(chip.block) }.item)
            return menu
        }
        return nil
    }

    private func menu(for block: DashboardBlock) -> NSMenu {
        let menu = NSMenu()
        let index = layoutBlocks.firstIndex(of: block) ?? 0
        let up = MenuAction("Move Up") { [weak self] in self?.move(block, by: -1) }.item
        up.isEnabled = index > 0
        let down = MenuAction("Move Down") { [weak self] in self?.move(block, by: 1) }.item
        down.isEnabled = index < layoutBlocks.count - 1
        menu.autoenablesItems = false
        menu.addItem(up)
        menu.addItem(down)
        menu.addItem(.separator())
        menu.addItem(MenuAction("Remove") { [weak self] in self?.remove(block) }.item)
        return menu
    }

    // MARK: Accessibility

    /// Each block in the preview is a button; its actions move or remove it.
    private final class BlockElement: NSAccessibilityElement {
        weak var owner: DashboardBuilder?
        var block: DashboardBlock = .cpu

        override func accessibilityFrameInParentSpace() -> NSRect {
            MainActor.assumeIsolated {
                guard let owner, let view = owner.preview.view(for: block) else { return .zero }
                let rect = owner.scaled(view.frame)
                return NSRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            }
        }

        override func accessibilityPerformPress() -> Bool { accessibilityPerformShowMenu() }

        override func accessibilityPerformShowMenu() -> Bool {
            MainActor.assumeIsolated {
                guard let owner, let view = owner.preview.view(for: block) else { return false }
                let rect = owner.scaled(view.frame)
                owner.menu(for: block).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: owner)
                return true
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let blocks = layoutBlocks
        elements = blocks.enumerated().map { index, block in
            let element = BlockElement()
            element.owner = self
            element.block = block
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(block.title)
            element.setAccessibilityHelp("Block \(index + 1) of \(blocks.count) in the dashboard")
            element.setAccessibilityParent(self)
            var actions: [NSAccessibilityCustomAction] = []
            if index > 0 {
                actions.append(NSAccessibilityCustomAction(name: "Move up") { [weak self] in self?.move(block, by: -1); return true })
            }
            if index < blocks.count - 1 {
                actions.append(NSAccessibilityCustomAction(name: "Move down") { [weak self] in self?.move(block, by: 1); return true })
            }
            actions.append(NSAccessibilityCustomAction(name: "Remove") { [weak self] in self?.remove(block); return true })
            element.setAccessibilityCustomActions(actions)
            return element
        }
        return elements + chips
    }

    // MARK: Bitmaps

    /// The view as it shows now, layers and all, as one bitmap at `scale`.
    private func snapshot(_ view: NSView, scale: CGFloat) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let backing = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        let width = Int(ceil(size.width * scale * backing)), height = Int(ceil(size.height * scale * backing))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if layer.isGeometryFlipped || view.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: scale * backing, y: scale * backing)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.render(in: context)
        }
        return context.makeImage()
    }

    // MARK: Demo

    /// WISP_BUILDER_DEMO=1 runs a scripted reorder, an add from the list and a
    /// removal, pausing mid-drag on each so a screenshot can catch it.
    private func scheduleDemo() {
        let steps: [(Double, () -> Void)] = [
            (2.0, { [weak self] in self?.demoDrag(from: { $0.centerOf(block: .apps) }, to: { $0.slotPoint(1) }) }),
            (6.0, { [weak self] in self?.endDrag() }),
            (8.0, { [weak self] in self?.demoDrag(from: { $0.centerOf(chip: .gpu) }, to: { $0.slotPoint(1) }) }),
            (12.0, { [weak self] in self?.endDrag() }),
            (14.0, { [weak self] in self?.demoDragOut(from: { $0.centerOf(block: .cores) }, toX: { $0.paletteX + 80 }) }),
            (18.0, { [weak self] in self?.endDrag() }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    private func centerOf(block: DashboardBlock) -> NSPoint? {
        preview.view(for: block).map { scaled($0.frame) }.map { NSPoint(x: $0.midX, y: $0.minY + 20) }
    }

    private func centerOf(chip block: DashboardBlock) -> NSPoint? {
        chips.first { $0.block == block }.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    /// A point over slot `index` of the saved layout.
    private func slotPoint(_ index: Int) -> NSPoint? {
        let frames = preview.frames()
        guard frames.indices.contains(index) else { return nil }
        let rect = scaled(frames[index].1)
        return NSPoint(x: rect.midX, y: rect.minY + 6)
    }

    private func demoDrag(from start: (DashboardBuilder) -> NSPoint?, to end: (DashboardBuilder) -> NSPoint?) {
        guard let a = start(self), let b = end(self) else { return }
        demoDrag(from: a, to: b)
    }

    private func demoDragOut(from start: (DashboardBuilder) -> NSPoint?, toX x: (DashboardBuilder) -> CGFloat) {
        guard let a = start(self) else { return }
        demoDrag(from: a, to: NSPoint(x: x(self), y: a.y))
    }

    private func demoDrag(from a: NSPoint, to b: NSPoint) {
        if let block = block(at: a) {
            drag = Drag(block: block, fromPalette: false, start: a, remaining: layoutBlocks.filter { $0 != block })
        } else if let chip = chip(at: a) {
            drag = Drag(block: chip.block, fromPalette: true, start: a, remaining: layoutBlocks)
        } else {
            return
        }
        moveDrag(to: NSPoint(x: a.x + 4, y: a.y + 4))
        let steps = 40
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) { [weak self] in
                let t = Motion.smoothOut(Double(step) / Double(steps))
                self?.moveDrag(to: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
    }
}

// MARK: - Pieces

/// One block in the builder's list: its symbol, name and a line about it. A block
/// already on the dashboard says so and cannot be added twice.
final class PaletteChip: DrawnView {
    let block: DashboardBlock
    var onPress: (() -> Void)?
    var inUse = false { didSet { if inUse != oldValue { needsDisplay = true } } }
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    /// While its block is being dragged out, the chip shows where it came from.
    var placeholder = false { didSet { if placeholder != oldValue { needsDisplay = true } } }

    init(_ block: DashboardBlock) {
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if placeholder {
            shape.setLineDash([4, 3], count: 2, phase: 0)
            Theme.cardBorderHover.setStroke()
            shape.stroke()
            return
        }
        (pressed ? Theme.track : hovering ? Theme.hover : Theme.fill).setFill()
        shape.fill()
        let alpha: CGFloat = inUse ? 0.5 : 1
        IconTile.image(block.symbol, tint: block.tint, size: 26, appearance: effectiveAppearance)
            .draw(in: NSRect(x: 9, y: (bounds.height - 26) / 2, width: 26, height: 26), from: .zero, operation: .sourceOver,
                  fraction: alpha, respectFlipped: true, hints: nil)
        let trailing: CGFloat = 70
        let room = bounds.width - 46 - trailing
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (block.title as NSString).draw(with: NSRect(x: 44, y: 5, width: room, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: Theme.sans(13, .medium), .foregroundColor: Theme.ink.withAlphaComponent(alpha), .paragraphStyle: paragraph])
        (block.detail as NSString).draw(with: NSRect(x: 44, y: 22, width: room, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary.withAlphaComponent(alpha), .paragraphStyle: paragraph])
        if inUse {
            let text = NSAttributedString(string: "Shown", attributes: [.font: Theme.sans(11), .foregroundColor: Theme.inkSecondary])
            let size = text.size()
            IconTile.glyph("checkmark", tint: Theme.inkSecondary, size: 12, appearance: effectiveAppearance)
                .draw(in: NSRect(x: bounds.width - 14 - size.width - 16, y: (bounds.height - 12) / 2, width: 12, height: 12),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            text.draw(at: NSPoint(x: bounds.width - 12 - size.width, y: (bounds.height - size.height) / 2))
        } else {
            IconTile.glyph("plus", tint: Theme.accent, size: 14, appearance: effectiveAppearance)
                .draw(in: NSRect(x: bounds.width - 26, y: (bounds.height - 14) / 2, width: 14, height: 14),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { inUse ? "\(block.title), shown" : "Add \(block.title)" }
    override func accessibilityHelp() -> String? { block.detail }
    override func isAccessibilityEnabled() -> Bool { !inUse }
    override func accessibilityPerformPress() -> Bool {
        guard !inUse else { return false }
        onPress?()
        return true
    }
}

/// The small round button on a hovered block in the preview.
final class RemoveButton: DrawnView {
    var onPress: (() -> Void)?
    var label = "Remove"
    private var pressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (pressed ? Theme.hover : Theme.card).setFill()
        circle.fill()
        Theme.cardBorderHover.setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        IconTile.glyph("xmark", tint: Theme.inkSecondary, size: 10, appearance: effectiveAppearance)
            .draw(in: NSRect(x: (bounds.width - 10) / 2, y: (bounds.height - 10) / 2, width: 10, height: 10),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// A menu item that runs a closure.
@MainActor
final class MenuAction: NSObject {
    let item: NSMenuItem
    private let body: () -> Void

    init(_ title: String, _ body: @escaping () -> Void) {
        self.body = body
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.target = self
        item.action = #selector(run)
        item.representedObject = self
    }

    @objc private func run() { body() }
}
