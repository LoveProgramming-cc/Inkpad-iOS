import UIKit

/// What the pen is in the middle of doing.
final class Op {
    enum Kind { case stroke, erase, shape, lasso, move, laser }

    var kind: Kind
    let page: Page
    let i: Int
    var item: Item?                       // the stroke or shape being drawn
    var smooth = (0.0, 0.0)               // where the stabilised line has got to
    var anchor = CGPoint.zero             // where the pen last rested, for hold-to-snap
    var fixed = false                     // snapped to a shape: further movement is ignored
    var rule: (CGPoint, CGVector)?        // the ruler's edge the stroke runs along, in the view
    var trail = false                     // a laser that leaves a line
    var predicted: [Pt] = []
    var dirty: Box?                       // page area of the overlay to draw again
    var pos = CGPoint.zero                // eraser position in the view
    var last = (0.0, 0.0)
    var before: [Item] = []
    var changed = false
    var pts: [Pt] = []                    // the lasso
    var rect = false
    var start = (0.0, 0.0)                // moving a selection
    var origin = (0.0, 0.0)
    var scaling = false
    var s = 1.0
    var dx = 0.0
    var dy = 0.0
    var copy = false                      // a copy is being carried: the originals stay where they are
    var at = CGPoint.zero                 // where in the view the selection was taken hold of
    var slack: CGFloat = 0                // how far a finger has to go before the selection follows it
    var live = false

    init(_ kind: Kind, _ page: Page, _ i: Int) {
        self.kind = kind
        self.page = page
        self.i = i
    }
}

struct Selection {
    let page: Page
    var items: [Item]
    var bbox: Box
}

/// Hands one touch (the pencil, or a finger when fingers may write) to the canvas, sample
/// by sample. A gesture recognizer rather than touchesBegan, so that the scroll view's own
/// handling of touches does not delay the ink.
final class StrokeGesture: UIGestureRecognizer {
    weak var canvas: CanvasView?
    private var touch: UITouch?
    private var second: UITouch?          // a finger beside the one carrying the selection: a copy goes along
    private var live = false              // the canvas was told of a touch and not yet of its end
    private var idle: UITouch?            // a finger carried through only to set the gestures going again

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let canvas else {
            state = .failed
            return
        }
        for t in touches {
            if touch == nil, canvas.accepts(t) {
                touch = t
                state = .began
                live = true
                canvas.strokeBegan(t, event)
            } else if let current = touch, second == nil, t.type == .direct, canvas.copyUnderFingers(current) {
                second = t
            } else if let current = touch, current.type != .pencil, t.type == .direct {
                // A second finger: this is a scroll or a pinch, not writing.
                canvas.strokeInterrupted(current)
                touch = nil
                live = false
                state = .cancelled
            } else if touch == nil, idle == nil, t.type == .direct {
                // Every finger that only moves the page goes through as a stroke that draws
                // nothing as well: as it ends, it sets all the window's gestures going again,
                // which after a swipe on a window that is not in front nothing else does.
                idle = t
                state = .began
            } else {
                ignore(t, for: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let idle, touches.contains(idle) { state = .changed }
        guard let touch, touches.contains(touch) else { return }
        canvas?.strokeMoved(touch, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let idle, touches.contains(idle) {
            self.idle = nil
            state = .ended
            return
        }
        if let touch, let second, touches.contains(second), !touches.contains(touch) {
            // A finger fewer than the gesture needs ends it where it is.
            live = false
            canvas?.strokeEnded(touch, event)
            state = .ended
            return
        }
        guard let touch, touches.contains(touch) else { return }
        live = false
        canvas?.strokeEnded(touch, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let idle, touches.contains(idle) {
            self.idle = nil
            state = .cancelled
            return
        }
        guard let touch, touches.contains(touch) else { return }
        live = false
        canvas?.strokeCancelled()
        state = .cancelled
    }

    override func reset() {
        // The system can take a touch away without saying so, as when it moves the window that
        // is not in front: the canvas must still hear the stroke is over, or the page stays
        // unable to scroll until the pencil next writes.
        if live {
            live = false
            canvas?.strokeCancelled()
        }
        touch = nil
        second = nil
        idle = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// The small bar that floats by a selection.
final class SelectionBar: UIView {
    let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The same floating pill as the tool options.
        backgroundColor = Theme.popoverUI
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.withAlphaComponent(0.05).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 5)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    func separator() {
        let line = UIView()
        line.backgroundColor = UIColor.label.withAlphaComponent(0.14)
        let holder = UIView()
        holder.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 15), holder.heightAnchor.constraint(equalToConstant: 36),
            line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 18),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor), line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        stack.addArrangedSubview(holder)
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func button(_ symbol: String, _ label: String, tint: UIColor? = nil, menu: UIMenu? = nil, action: (() -> Void)? = nil) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = Lucide.image(symbol)
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        config.background.cornerRadius = 12
        let b = UIButton(configuration: config, primaryAction: action.map { fn in UIAction { _ in fn() } })
        b.accessibilityLabel = label
        b.tintColor = tint ?? .label
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        if let menu {
            b.menu = menu
            b.showsMenuAsPrimaryAction = true
        }
        stack.addArrangedSubview(b)
        return b
    }
}

/// The colours a selection can be given, five to a row, as the desktop's popover has them.
final class SwatchGrid: UIViewController, UIPopoverPresentationControllerDelegate {
    private let colors: [RGB]
    private let pick: (RGB) -> Void

    init(colors: [RGB], pick: @escaping (RGB) -> Void) {
        self.colors = colors
        self.pick = pick
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        let rows = (colors.count + 4) / 5
        preferredContentSize = CGSize(width: 5 * 40 + 4 * 4 + 20, height: CGFloat(rows) * 40 + CGFloat(rows - 1) * 4 + 20)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.popoverUI
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
        for start in stride(from: 0, to: colors.count, by: 5) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            for (k, c) in colors[start..<min(start + 5, colors.count)].enumerated() {
                let swatch = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { ctx in
                    c.ui.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 24, height: 24))
                    UIColor.gray.withAlphaComponent(0.6).setStroke()
                    ctx.cgContext.strokeEllipse(in: CGRect(x: 1, y: 1, width: 24, height: 24))
                }.withRenderingMode(.alwaysOriginal)
                var config = UIButton.Configuration.plain()
                config.image = swatch
                config.background.cornerRadius = 10
                let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    self.dismiss(animated: true)
                    self.pick(c)
                })
                b.accessibilityLabel = tr("颜色") + " \(start + k + 1)"
                b.widthAnchor.constraint(equalToConstant: 40).isActive = true
                b.heightAnchor.constraint(equalToConstant: 40).isActive = true
                row.addArrangedSubview(b)
            }
            grid.addArrangedSubview(row)
        }
    }

    // A popover on an iPhone too, rather than a sheet over the whole screen.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}

/// A few lines of text for a text box or a sticky note.
final class TextEntryController: UIViewController {
    let textView = UITextView()
    var onClose: ((String) -> Void)?
    private var closed = false

    init(text: String, title: String) {
        super.init(nibName: nil, bundle: nil)
        textView.text = text
        self.title = title
        preferredContentSize = CGSize(width: 340, height: 190)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.font = .systemFont(ofSize: 17)
        textView.frame = view.bounds.insetBy(dx: 8, dy: 4)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: tr("完成"), style: .done, target: self, action: #selector(done))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: tr("取消"), style: .plain, target: self, action: #selector(cancel))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func done() { dismiss(animated: true) }

    @objc private func cancel() {
        closed = true
        dismiss(animated: true)
    }

    // Dismissing by tapping outside commits too, as closing the popover does on the desktop.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !closed {
            closed = true
            onClose?(textView.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension CanvasView {
    // MARK: input

    func setUpInput() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        strokeGesture = StrokeGesture(target: nil, action: nil)
        strokeGesture.canvas = self
        strokeGesture.delegate = self
        strokeGesture.cancelsTouchesInView = false
        strokeGesture.delaysTouchesBegan = false
        strokeGesture.delaysTouchesEnded = false
        addGestureRecognizer(strokeGesture)
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(fingerTap(_:)))
        tapGesture.allowedTouchTypes = direct
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
        // Holding still with the select tool asks for a menu at that place. Not with the pencil:
        // it holds still too often while writing for that to be meant.
        pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        pressGesture.minimumPressDuration = 0.55
        pressGesture.allowableMovement = 10
        pressGesture.allowedTouchTypes = direct
        pressGesture.delegate = self
        addGestureRecognizer(pressGesture)
        addInteraction(editMenu)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        // Coming back to the front, the page can be moved again whatever happened to the touch
        // that was down when the window went behind or was moved.
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(regainScrolling), name: name, object: nil)
        }
        applyInputSettings()
        #if DEBUG
        // There is no pencil to squeeze in the simulator: the tests ask for the palette this way.
        if ProcessInfo.processInfo.arguments.contains("-palette") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.toolRing == nil else { return }
                self.togglePalette(at: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
            }
        }
        #endif
    }

    /// One finger writes: fingers may, or the laser is in hand (a finger can always point).
    var fingersWrite: Bool { tools.p.fingerDraw || tools.tool == "laser" }

    /// A mouse writes, until a pencil has been used: from then on it moves the page.
    var mouseDraws: Bool { !(tools.p.mouseHand && Self.hasPen) }

    /// Fingers either write (then two of them scroll) or only scroll and zoom.
    func applyInputSettings() {
        scroll.panGestureRecognizer.minimumNumberOfTouches = fingersWrite ? 2 : 1
        var moving = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        if !mouseDraws { moving.append(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)) }
        scroll.panGestureRecognizer.allowedTouchTypes = moving
        scroll.showsVerticalScrollIndicator = tools.p.scrollbars
        // Side by side the lower bar is drawn here, for the page in view only.
        scroll.showsHorizontalScrollIndicator = tools.p.scrollbars && !across
        placePageBar()
        if !slots.isEmpty { updateZoomLimits() }
    }

    /// Together with the page's own gestures only, not with the window's (those by which a
    /// window that is not in front is scrolled or brought forward).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard let view = other.view else { return false }
        return view === self || view.isDescendant(of: self)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Touches on the selection bar and the map belong to their buttons.
        if let view = touch.view, view.isDescendant(of: selBar) || view.isDescendant(of: minimap) || view is PencilPalette { return false }
        // A tap is for the touches that do not write, and the ruler takes its own.
        if g === tapGesture { return !accepts(touch) && !(touch.view is RulerView) }
        return true
    }

    func accepts(_ touch: UITouch) -> Bool {
        if let view = touch.view, view.isDescendant(of: selBar) || view.isDescendant(of: minimap) || view is PencilPalette { return false }
        if touch.type == .pencil { return true }
        // With the select tool a finger on the selection carries it, and at its edge resizes it,
        // even when fingers otherwise only move the page.
        if touch.type == .direct, !fingersWrite, tools.tool == "lasso", grip(touch.location(in: self), reach: 22) != nil { return true }
        guard touch.type == .indirectPointer ? mouseDraws : fingersWrite && touch.type == .direct else { return false }
        // A finger or the mouse on the ruler moves it; only the pencil draws across it.
        return !(touch.view is RulerView) || rulerZone(touch.location(in: self)) == .edge
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { pencilTapped() }

    // Once the delegate answers squeezes the system sends taps only this way.
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { pencilTapped() }

    private func pencilTapped() {
        guard tools.p.pencilDoubleTap else { return }
        if tools.tool == "eraser" {
            tools.tool = previousTool
        } else {
            previousTool = tools.tool
            tools.tool = "eraser"
        }
    }

    private func pressure(_ t: UITouch) -> Double {
        if t.type == .indirectPointer {
            // No pressure to read: thin the line with speed for a calligraphic feel.
            let p = t.location(in: self)
            let speed = hypot(p.x - mouseLast.x, p.y - mouseLast.y)
            mouseP = mouseP * 0.75 + max(0.15, min(0.85, 0.95 - Double(speed) / 45)) * 0.25
            mouseLast = p
            return mouseP
        }
        guard t.type == .pencil else { return 0.5 }
        // A pencil without a pressure sensor (the USB-C one) reports the same force all the
        // time. It is known by that, and its line then thins with speed, as a mouse's does.
        let p = t.preciseLocation(in: self), force = Double(t.force)
        let dt = t.timestamp - penLast
        if dt > 0 {
            let speed = Double(hypot(p.x - mouseLast.x, p.y - mouseLast.y)) / dt   // points a second
            let aim = max(0.16, min(0.92, 0.95 - speed / 1700))
            mouseP += (aim - mouseP) * (1 - exp(-dt / 0.045))
            mouseLast = p
            penLast = t.timestamp
        }
        forceCount += 1
        if forceCount == 1 {
            forceFirst = force
        } else if !forceVaries, abs(force - forceFirst) > 0.02 {
            forceVaries = true
            Self.penForce = true
        } else if !forceVaries, forceCount == 12 {
            Self.penForce = false
        }
        // Speed is given twice the say pressure has: the pens answer to pressure gently, and a
        // line that only speed can shape would otherwise hardly change.
        if !Self.penForce || force <= 0 { return max(0, min(1, 0.5 + (mouseP - 0.5) * 2)) }
        // An ordinary writing press is about 1; twice that is as hard as the pens respond to.
        // Speed has its say beside the pressure: a quick line is thinner however hard it is pressed.
        return max(0, min(1, force / 2 + (mouseP - 0.5) * 0.7))
    }

    @objc func regainScrolling() {
        // Nothing is touching the canvas: anything still under way was cut off. Turning the
        // page's own gestures off and on again also clears whatever they were still holding on
        // to, which is what a stroke of the pencil used to do by the way.
        guard let strokeGesture, strokeGesture.state == .possible else { return }
        if op != nil { cancelOp() }
        setScrolling(false)
        setScrolling(true)
    }

    private func setScrolling(_ on: Bool) {
        scroll.panGestureRecognizer.isEnabled = on
        scroll.pinchGestureRecognizer?.isEnabled = on
    }

    func strokeBegan(_ t: UITouch, _ event: UIEvent) {
        // While the pencil is down a resting palm must not scroll the page away.
        if t.type == .pencil {
            setScrolling(false)
            mouseP = 0.5
            mouseLast = t.preciseLocation(in: self)
            penLast = t.timestamp
            forceCount = 0
            forceVaries = false
            if !Self.hasPen {
                Self.hasPen = true
                applyInputSettings()
            }
        } else if t.type == .indirectPointer {
            mouseP = 0.45
            mouseLast = t.location(in: self)
        } else if !fingersWrite {
            setScrolling(false)   // a finger that has hold of the selection must not move the page too
        }
        grabReach = t.type == .direct ? 22 : 7
        // A page still gliding from the flick before must stop where it is: ink is placed by
        // where the page is, and would be smeared across a page that moves under the pen.
        if scroll.isDecelerating || scroll.isDragging { scroll.setContentOffset(scroll.contentOffset, animated: false) }
        hidePalette()
        hoverLayer.isHidden = true
        log("down: \(describe(t)), tool \(tools.tool)")
        strokeStart = t.timestamp
        down(t.preciseLocation(in: self), pressure(t), pencil: t.type == .pencil)
    }

    func strokeMoved(_ t: UITouch, _ event: UIEvent) {
        for c in event.coalescedTouches(for: t) ?? [t] { move(c.preciseLocation(in: self), pressure(c)) }
        if let op, op.kind == .stroke, !op.fixed, let stroke = op.item as? Stroke, let last = stroke.pts.last {
            // Where the pen is about to be: drawn ahead of the samples, then thrown away.
            op.dirty = union(op.dirty, Geom.bbox(op.predicted + [last]))
            op.predicted = (event.predictedTouches(for: t) ?? []).map { c in
                let p = toPage(op.i, c.preciseLocation(in: self))
                return Pt(x: p.0, y: p.1, p: last.p)
            }
            if op.rule != nil || (tools.penStab > 0 && stroke.tool != "hl" && stroke.tool != "tape") { op.predicted = [] }
            op.dirty = union(op.dirty, Geom.bbox(op.predicted + [last]))
        }
        flushOverlay()
    }

    func strokeEnded(_ t: UITouch, _ event: UIEvent) {
        log("up: \(describe(t))")
        up(t.preciseLocation(in: self))
        resumeScrolling(t.type == .pencil)
    }

    func strokeCancelled() {
        log("cancelled: the system took the touch away")
        cancelOp()
        resumeScrolling(false)
    }

    /// Fingers get the page back, after the pencil a moment later: the hand that held it
    /// is still resting on the screen.
    private func resumeScrolling(_ afterPencil: Bool) {
        let wait = afterPencil ? tools.p.palmMs / 1000 : 0
        if wait <= 0 {
            setScrolling(true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            if self?.op == nil { self?.setScrolling(true) }
        }
    }

    /// A second finger came down while one was writing.
    func strokeInterrupted(_ t: UITouch) {
        if let op, op.kind == .stroke, let stroke = op.item as? Stroke, t.timestamp - strokeStart < 0.3 || stroke.pts.count < 8 {
            log("dropped: a second finger came down just after the first")
            cancelOp()   // barely begun: it was the first finger of a pinch
        } else if op?.kind == .move {
            cancelOp()   // the hand had hold of the selection: it goes back
        } else {
            up(t.preciseLocation(in: self))
        }
        setScrolling(true)
    }

    @objc func fingerTap(_ g: UITapGestureRecognizer) {
        let v = g.location(in: self)
        if selBar.frame.contains(v) && !selBar.isHidden { return }
        if toolRing != nil {
            hidePalette()
            return
        }
        let tool = tools.tool
        if tool != "eraser" && tool != "lasso" && toggleTape(v) { return }
        if tool == "text" || tool == "note" {
            clearSelection()
            if let (i, px, py) = locate(v) { editText(i, doc.pages[i], v, px, py, note: tool == "note") }
        } else if tool == "lasso" {
            pick(at: v)   // with the select tool a tap picks what is under it
        } else {
            clearSelection()
        }
    }

    // MARK: overlay

    /// Ask for the part of the overlay that the current stroke changed to be drawn again.
    private func flushOverlay() {
        guard let op else { return }
        if op.kind == .stroke, !op.fixed, let dirty = op.dirty, let stroke = op.item as? Stroke {
            op.dirty = nil
            overlay.setNeedsDisplay(viewRect(op.i, dirty.padded(stroke.pad() + 2)).insetBy(dx: -2, dy: -2))
        } else {
            overlay.setNeedsDisplay()
        }
    }

    func drawOverlay(_ g: CGContext, _ rect: CGRect) {
        guard slots.count == doc.pages.count else { return }
        let z = scroll.zoomScale
        let accent = UIColor(red: 0.21, green: 0.52, blue: 0.89, alpha: 1)
        for (n, (i, box)) in marks.enumerated() where slots.indices.contains(i) {
            let hit = viewRect(i, box).insetBy(dx: -2, dy: -2)
            guard hit.intersects(bounds) else { continue }
            g.setFillColor((n == markAt ? UIColor(red: 1, green: 0.5, blue: 0, alpha: 0.5) : UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.35)).cgColor)
            g.fill(hit)
        }
        if let op, slots.indices.contains(op.i) {
            switch op.kind {
            case .stroke, .shape:
                guard let item = op.item else { break }
                g.saveGState()
                // Keep the ink on its page, as it will be once the stroke is done.
                if !op.page.board { g.clip(to: viewRect(op.i, Box(0, 0, op.page.w, op.page.h))) }
                g.concatenate(pageToView(op.i))
                var live = item
                if let stroke = item as? Stroke, !op.predicted.isEmpty, !op.fixed {
                    live = Stroke(stroke.tool, stroke.color, stroke.width, stroke.pts + op.predicted, sens: stroke.sens, dash: stroke.dash)
                }
                // A marker multiplies with the page through the layer; inside it is plain colour.
                live.draw(g, DrawEnv(onDark: true))
                g.restoreGState()
            case .erase:
                let r = CGFloat(tools.eraserR) * z
                let ring = CGRect(x: op.pos.x - r, y: op.pos.y - r, width: 2 * r, height: 2 * r)
                g.setFillColor(UIColor(white: 1, alpha: 0.5).cgColor)
                g.fillEllipse(in: ring)
                g.setStrokeColor(UIColor(white: 0.3, alpha: 0.8).cgColor)
                g.setLineWidth(1)
                g.strokeEllipse(in: ring)
            case .lasso:
                guard op.pts.count > 1 else { break }
                let t = pageToView(op.i)
                g.setStrokeColor(accent.cgColor)
                g.setLineWidth(1.5)
                g.setLineDash(phase: 0, lengths: [6, 4])
                if op.rect {
                    g.setFillColor(accent.withAlphaComponent(0.1).cgColor)
                    let box = viewRect(op.i, Geom.bbox(op.pts))
                    g.fill(box)
                    g.stroke(box)
                } else {
                    g.addLines(between: op.pts.map { CGPoint(x: $0.x, y: $0.y).applying(t) })
                    g.strokePath()
                }
                g.setLineDash(phase: 0, lengths: [])
            case .move, .laser:
                break
            }
        }
        if !laserTrails.isEmpty || laserDot != nil { drawLaser(g) }
        if pull != 0 {
            // Pulled past an end of a side-by-side notebook: a ring that fills as the pull grows.
            let done = min(1, abs(pull) / CanvasView.pullToAdd)
            let c = CGPoint(x: pull > 0 ? bounds.width - 70 : 70, y: bounds.height / 2)
            let ring = CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52)
            g.setFillColor(accent.withAlphaComponent(0.12 + 0.5 * done).cgColor)
            g.fillEllipse(in: ring)
            g.setStrokeColor(accent.cgColor)
            g.setLineWidth(2)
            g.strokeEllipse(in: ring)
            g.setFillColor((done >= 1 ? UIColor.white : accent).cgColor)
            g.fill(CGRect(x: c.x - 9, y: c.y - 1, width: 18, height: 2))
            g.fill(CGRect(x: c.x - 1, y: c.y - 9, width: 2, height: 18))
            let text = tr(done >= 1 ? "松手添加页面" : "继续拉动添加页面") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: accent]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y + 34), withAttributes: attrs)
        }
        if let rect = selectionRect() {
            g.setStrokeColor(accent.cgColor)
            g.setLineWidth(1.5)
            g.setLineDash(phase: 0, lengths: [6, 4])
            g.stroke(rect.insetBy(dx: -4, dy: -4))
            g.setLineDash(phase: 0, lengths: [])
            let handle = CGRect(x: rect.maxX + 4 - 7, y: rect.maxY + 4 - 7, width: 14, height: 14)
            g.setFillColor(UIColor.white.cgColor)
            g.fillEllipse(in: handle)
            g.setLineWidth(2)
            g.strokeEllipse(in: handle)
        }
    }

    private func setMarker(_ on: Bool) {
        overlay.layer.compositingFilter = on ? "multiplyBlendMode" : nil
    }

    // MARK: tools

    func down(_ v: CGPoint, _ pressure: Double, pencil: Bool) {
        op = nil
        let tool = tools.tool
        var v = v
        let zone = tool == "eraser" ? nil : rulerZone(v)
        if !pencil && tool != "eraser" && tool != "lasso" && zone == nil && toggleTape(v) { return }   // a finger on a tape lifts it or puts it back
        var rule: (CGPoint, CGVector)?
        if zone != nil, ["pen", "hl", "tape"].contains(tool), let edge = rulerEdge(v) {
            // A stroke begun at the ruler runs along its edge.
            rule = edge
            v = onto(edge, v)
        }
        if tool == "lasso", sel != nil, grabSelection(v, reach: grabReach) { return }
        clearSelection()
        guard let (i, px, py) = locate(v) else { return }
        let page = doc.pages[i]
        switch tool {
        case "pen", "hl", "tape":
            let item: Stroke
            if tool == "tape" {
                item = Stroke("tape", tools.tapeColor, tools.tapeWidth, [Pt(x: px, y: py)])
            } else if tool == "pen" {
                item = Stroke(tools.p.penType, tools.penColor, tools.penWidth, [Pt(x: px, y: py, p: pressure)], sens: tools.penSens, dash: tools.pen.dash)
            } else {
                item = Stroke("hl", tools.hlColor, tools.hlWidth, [Pt(x: px, y: py)])
            }
            let new = Op(.stroke, page, i)
            new.item = item
            new.smooth = (px, py)
            new.anchor = v
            new.rule = rule
            op = new
            setMarker(tool == "hl" && !page.onDark)
        case "eraser":
            let new = Op(.erase, page, i)
            new.pos = v
            new.last = (px, py)
            new.before = page.items
            op = new
            erase(new, px, py)
        case "shape":
            let new = Op(.shape, page, i)
            new.item = Shape(tools.p.shapeKind, px, py, px, py, tools.penColor, tools.penWidth)
            op = new
        case "lasso":
            let new = Op(.lasso, page, i)
            new.pts = [Pt(x: px, y: py)]
            new.rect = tools.p.lassoRect
            op = new
        case "text", "note":
            editText(i, page, v, px, py, note: tool == "note")
        case "laser":
            laserReset()
            let new = Op(.laser, page, i)
            new.trail = tools.p.laserMode == "trail"
            if new.trail {
                laserTrails.append((page, [Pt(x: px, y: py)]))
            } else {
                laserDot = (page, px, py)
            }
            op = new
        default:
            break
        }
        overlay.setNeedsDisplay()
    }

    func move(_ v: CGPoint, _ pressure: Double) {
        guard let op, slots.indices.contains(op.i) else { return }
        var v = v
        if let rule = op.rule { v = onto(rule, v) }
        var (px, py) = toPage(op.i, v)
        if op.kind == .move {
            if !op.live {
                // A finger does not hold still: the selection stays put until it clearly moves.
                if hypot(v.x - op.at.x, v.y - op.at.y) < op.slack { return }
                op.live = true
            }
            if op.scaling {
                let (ox, oy) = op.origin, (sx, sy) = op.start
                op.s = max(0.1, hypot(px - ox, py - oy) / max(1.0, hypot(sx - ox, sy - oy)))
            } else {
                op.dx = px - op.start.0
                op.dy = py - op.start.1
            }
            placeMoveLayer()
            return
        }
        if op.fixed { return }
        switch op.kind {
        case .stroke:
            guard let item = op.item as? Stroke else { return }
            let marker = item.tool == "hl" || item.tool == "tape"
            if tools.p.holdShape && op.rule == nil {
                if holdTimer == nil || hypot(v.x - op.anchor.x, v.y - op.anchor.y) > 5 {
                    op.anchor = v
                    holdTimer?.invalidate()
                    holdTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.held() }
                }
            }
            if tools.penStab > 0 && !marker && op.rule == nil {
                // Stabiliser: the ink follows the pen through a low-pass filter.
                let k = 1.0 - 0.9 * tools.penStab
                px = op.smooth.0 + (px - op.smooth.0) * k
                py = op.smooth.1 + (py - op.smooth.1) * k
                op.smooth = (px, py)
            }
            guard let last = item.pts.last else { return }
            let least = 0.4 / zoom
            if (px - last.x) * (px - last.x) + (py - last.y) * (py - last.y) < least * least { return }
            item.pts.append(Pt(x: px, y: py, p: marker ? 0.5 : pressure))
            op.dirty = union(op.dirty, Geom.bbox(Array(item.pts.suffix(4))))
        case .erase:
            op.pos = v
            erase(op, px, py)
        case .shape:
            guard let item = op.item as? Shape else { return }
            item.x1 = px
            item.y1 = py
            item.updateBBox()
        case .lasso:
            if op.rect {
                op.pts = [op.pts[0], Pt(x: px, y: py)]
            } else {
                op.pts.append(Pt(x: px, y: py))
            }
        case .laser:
            if op.trail, !laserTrails.isEmpty {
                laserTrails[laserTrails.count - 1].pts.append(Pt(x: px, y: py))
            } else if !op.trail {
                laserDot = (op.page, px, py)
            }
        case .move:
            break
        }
    }

    /// Lift the tape under a point, or put it back; true if there was one.
    func toggleTape(_ v: CGPoint) -> Bool {
        guard let (i, px, py) = locate(v) else { return false }
        let page = doc.pages[i]
        for it in page.items.reversed() {
            guard let tape = it as? Stroke, tape.tool == "tape", tape.bbox.contains(px, py), tape.hit(px, py, 2 / zoom) else { continue }
            tape.open.toggle()
            page.rev += 1
            doc.touch()
            repaint(page, tape.bbox)
            return true
        }
        return false
    }

    /// The pen rested at the end of a stroke: snap the stroke to a clean shape.
    private func held() {
        holdTimer = nil
        guard let op, op.kind == .stroke, let item = op.item as? Stroke, item.pts.count >= 6,
              let found = Geom.recognizeShape(item.pts) else { return }
        if item.tool == "hl" || item.tool == "tape" {
            guard found.kind == "line" else { return }
            item.pts = [Pt(x: found.x0, y: found.y0), Pt(x: found.x1, y: found.y1)]
            item.updateBBox()
        } else {
            op.kind = .shape
            op.item = Shape(found.kind, found.x0, found.y0, found.x1, found.y1, item.color, item.width)
        }
        op.fixed = true
        op.predicted = []
        overlay.setNeedsDisplay()
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    func up(_ v: CGPoint) {
        guard let op else { return }
        self.op = nil
        stopHold()
        let page = op.page
        defer {
            setMarker(false)
            refreshOverlay()
        }
        guard index(of: page) != nil else { return }
        switch op.kind {
        case .stroke:
            guard let item = op.item as? Stroke else { return }
            let marker = item.tool == "hl" || item.tool == "tape"
            if tools.penStab > 0 && !marker && !op.fixed && op.rule == nil, let last = item.pts.last {
                // Catch the lagging stabilised line up with where the pen lifted.
                let (px, py) = toPage(op.i, v)
                item.pts.append(Pt(x: px, y: py, p: last.p))
            }
            item.updateBBox()
            if !marker && !op.fixed && op.rule == nil && tools.p.scribbleErase && Geom.isScribble(item.pts, loose: tools.p.scribbleLoose) {
                let targets = Geom.scribbleTargets(item.pts, page.items)
                if !targets.isEmpty {
                    // Scribble to erase, recorded as two steps: the scribble as ordinary ink, then
                    // the erasure. One undo brings everything back with the scribble still there
                    // (in case it was not meant as one), a second undo removes the scribble too.
                    doc.addItems(page, [item])
                    doc.removeItems(page, targets + [item])
                    return
                }
            }
            doc.addItems(page, [item])
        case .erase:
            if op.changed {
                doc.pushDiff(page, op.before)
                // "Deselect automatically": one erasure, then back to what was in hand.
                if tools.p.eraserAuto && tools.tool == "eraser" { tools.tool = previousTool }
            }
        case .laser:
            laserDot = nil
            if !laserTrails.isEmpty {
                laserTimer = Timer.scheduledTimer(withTimeInterval: Self.laserHold, repeats: false) { [weak self] _ in self?.laserExpire() }
            }
        case .shape:
            guard let item = op.item as? Shape else { return }
            if hypot(item.x1 - item.x0, item.y1 - item.y0) > 2 { doc.addItems(page, [item]) }
        case .lasso:
            let box = Geom.bbox(op.pts)
            let picked: [Item]
            let items = selectable(page)
            if max(box.w, box.h) * zoom < 8 {
                pick(at: v)   // a tap selects the topmost item under it
                return
            } else if op.rect {
                picked = Geom.rectPick(box, items)
            } else {
                picked = Geom.lassoPick(op.pts, items)
            }
            select(page, picked)
        case .move:
            lifted = []
            moveLayer.isHidden = true
            moveLayer.contents = nil
            guard let sel else { return }
            if abs(op.s - 1) > 1e-3 || hypot(op.dx, op.dy) * zoom > 1 {
                let news = sel.items.map { $0.transformed(op.s, op.origin.0, op.origin.1, op.dx, op.dy) }
                if op.copy {
                    doc.addItems(page, news)   // the originals stay where they were
                } else {
                    doc.replaceItems(page, sel.items, news)
                }
                select(page, news)
            } else {
                repaint(page, sel.bbox)
            }
        }
    }

    func cancelOp() {
        guard let op else { return }
        self.op = nil
        stopHold()
        setMarker(false)
        if op.kind == .erase && op.changed {
            doc.pushDiff(op.page, op.before)
        } else if op.kind == .laser {
            laserDot = nil
            if op.trail, !laserTrails.isEmpty { laserTrails.removeLast() }
        } else if op.kind == .move {
            lifted = []
            moveLayer.isHidden = true
            moveLayer.contents = nil
            if let sel { repaint(op.page, sel.bbox) }
        }
        refreshOverlay()
    }

    private func erase(_ op: Op, _ px: Double, _ py: Double) {
        let page = op.page
        let r = tools.eraserR
        let (lx, ly) = op.last
        op.last = (px, py)
        let reach = Box(min(lx, px) - r, min(ly, py) - r, max(lx, px) + r, max(ly, py) + r)
        let whole = tools.p.eraserMode == "stroke"
        var out: [Item] = []
        out.reserveCapacity(page.items.count)
        var rect: Box?
        for it in page.items {
            // Ink, markers and shapes can be rubbed out, each only while its switch is on;
            // text and pictures cannot.
            let stroke = it as? Stroke, shape = it as? Shape
            let family = stroke.map { $0.tool == "hl" ? "hl" : "pen" } ?? (shape != nil ? "shape" : "")
            guard it.bbox.intersects(reach), tools.p.eraseFilter.contains(family) else {
                out.append(it)
                continue
            }
            if whole || shape?.shape == "arrow" || stroke?.tool == "tape" {
                let steps = max(1, Int(hypot(px - lx, py - ly) / (r * 0.7)))
                if (0...steps).contains(where: { k in
                    it.hit(lx + (px - lx) * Double(k) / Double(steps), ly + (py - ly) * Double(k) / Double(steps), r)
                }) {
                    rect = union(rect, it.bbox)
                } else {
                    out.append(it)
                }
                continue
            }
            // Standard eraser: cut the touched part out and keep the rest as shorter strokes.
            let pts = stroke?.pts ?? it.polyline()
            let width = stroke?.width ?? shape?.width ?? 1
            guard let cut = Geom.eraseRuns(pts, lx, ly, px, py, r + width / 2) else {
                out.append(it)
                continue
            }
            let color = stroke?.color ?? shape?.color ?? .black
            var tool = "ball", sens = 1.0, dash = 0
            if let stroke, stroke.dash == 0 {
                rect = union(rect, cut.box.padded(stroke.pad() + 2))
                tool = stroke.tool
                sens = stroke.sens
            } else {
                rect = union(rect, it.bbox)   // a shape or dashed line is redrawn as a whole
                if let stroke {
                    tool = stroke.tool
                    sens = stroke.sens
                    dash = stroke.dash
                }
            }
            for run in cut.runs where run.count > 1 { out.append(Stroke(tool, color, width, run, sens: sens, dash: dash)) }
        }
        guard let rect else { return }
        page.items = out
        op.changed = true
        repaint(page, rect)
    }

    // MARK: selection

    /// What the lasso may pick up, by the kinds switched on in its settings.
    private func selectable(_ page: Page) -> [Item] {
        let names = ["s": "ink", "h": "shape", "i": "image", "t": "text"]
        let allowed = tools.p.lassoFilter
        return page.items.filter { allowed.contains(names[$0.kind] ?? "") }
    }

    func select(_ page: Page, _ items: [Item]) {
        if items.isEmpty {
            sel = nil
        } else {
            var box: Box?
            for it in items { box = union(box, it.bbox) }
            sel = Selection(page: page, items: items, bbox: box!)
        }
        onSelection?()
        refreshOverlay()
    }

    func clearSelection() {
        guard sel != nil else { return }
        sel = nil
        onSelection?()
        refreshOverlay()
    }

    /// The selection box in view coordinates, or nil (also while it is being dragged).
    func selectionRect() -> CGRect? {
        guard let sel, op?.kind != .move, let i = index(of: sel.page), slots.indices.contains(i) else { return nil }
        return viewRect(i, sel.bbox)
    }

    /// Where a point of the view takes hold of the selection: inside it to move it, on its edge
    /// (within reach points) or its handle to resize it. Nil if the point is elsewhere.
    func grip(_ v: CGPoint, reach: Double) -> (scaling: Bool, origin: (Double, Double))? {
        guard let sel, let i = index(of: sel.page), slots.indices.contains(i) else { return nil }
        let (px, py) = toPage(i, v)
        let b = sel.bbox, k = zoom
        if hypot((px - b.x1) * k - 4, (py - b.y1) * k - 4) <= 18 { return (true, (b.x0, b.y0)) }
        // The box as drawn is 4 points larger all round.
        let box = b.padded(4 / k), r = reach / k
        guard box.padded(r).contains(px, py) else { return nil }
        // The edge is a band about the outline; a small selection keeps a middle to move it by.
        let inner = min(r, box.w / 4, box.h / 4)
        if box.x0 + inner < px, px < box.x1 - inner, box.y0 + inner < py, py < box.y1 - inner { return (false, (b.x0, b.y0)) }
        // It grows and shrinks about the point opposite the one taken hold of.
        return (true, (b.x0 + b.x1 - max(b.x0, min(b.x1, px)), b.y0 + b.y1 - max(b.y0, min(b.y1, py))))
    }

    /// The selected items as one picture, to be carried about.
    private func lift(_ sel: Selection) -> UIImage {
        let b = sel.bbox
        let scale = min(Double(scroll.zoomScale * UIScreen.main.scale), 4096 / max(b.w, b.h, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: max(1, b.w * scale), height: max(1, b.h * scale))
        let env = DrawEnv(onDark: true)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            ctx.cgContext.translateBy(x: -b.x0, y: -b.y0)
            for it in sel.items { it.draw(ctx.cgContext, env) }
        }
    }

    private func carry(_ new: Op, _ image: UIImage) {
        op = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moveLayer.contents = image.cgImage
        moveLayer.isHidden = false
        CATransaction.commit()
        placeMoveLayer()
        refreshOverlay()
    }

    private func grabSelection(_ v: CGPoint, reach: Double = 7) -> Bool {
        guard let sel, let i = index(of: sel.page), slots.indices.contains(i), let grip = grip(v, reach: reach) else { return false }
        // Lift the items out of the page raster and carry them as one picture.
        let image = lift(sel)
        lifted = Set(sel.items.map { ObjectIdentifier($0) })
        repaint(sel.page, sel.bbox)
        let new = Op(.move, sel.page, i)
        new.start = toPage(i, v)
        new.origin = grip.origin
        new.scaling = grip.scaling
        new.at = v
        new.slack = reach > 7 ? 8 : 0
        carry(new, image)
        return true
    }

    /// A second finger came down beside the one moving the selection: the selection goes back
    /// and a copy of it is carried instead. False if there is nothing being moved by a finger.
    func copyUnderFingers(_ first: UITouch) -> Bool {
        guard first.type == .direct, let old = op, old.kind == .move, !old.copy, !old.scaling else { return false }
        cancelOp()
        guard let sel, let i = index(of: sel.page), slots.indices.contains(i) else { return false }
        let v = first.location(in: self)
        let new = Op(.move, sel.page, i)
        new.start = toPage(i, v)
        new.origin = (sel.bbox.x0, sel.bbox.y0)
        new.copy = true
        new.at = v
        new.slack = 8
        carry(new, lift(sel))
        return true
    }

    /// Select the topmost picture, shape or text box at a point of the view, or nothing if
    /// none is there.
    @discardableResult
    func pick(at v: CGPoint) -> Bool {
        var picked: [Item] = []
        guard let (i, px, py) = locate(v) else {
            clearSelection()
            return false
        }
        let page = doc.pages[i]
        let r = 10 / max(1e-6, zoom)
        let near = Box(px - r, py - r, px + r, py + r)
        for it in selectable(page).reversed() {
            // Not handwriting: a tap among the lines of a page would always catch some of it.
            if it.kind == "s" || !it.bbox.intersects(near) { continue }
            // Pictures and text are picked anywhere inside; shapes on their lines.
            if it.kind == "i" || it.kind == "t" || it.hit(px, py, r) {
                picked = [it]
                break
            }
        }
        if picked.isEmpty { clearSelection() } else { select(page, picked) }
        return !picked.isEmpty
    }

    // MARK: the menu a long press with the select tool asks for

    @objc func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, tools.tool == "lasso", toolRing == nil else { return }
        let v = g.location(in: self)
        // Whatever the press had begun (a lasso, a move of the selection) is given up, and what
        // is left of the press does nothing more.
        strokeGesture.isEnabled = false
        strokeGesture.isEnabled = true
        cancelOp()
        setScrolling(true)
        menuAt = v
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: v))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let v = menuAt
        // What can be done with the selection if the press was on it, and pasting at that place.
        var rows: [UIMenuElement] = []
        if let rect = selectionRect(), rect.insetBy(dx: -8, dy: -8).contains(v) {
            rows = [
                UIAction(title: tr("剪切"), image: Lucide.image("scissors")) { [weak self] _ in
                    self?.copySelection()
                    self?.deleteSelection()
                },
                UIAction(title: tr("拷贝"), image: Lucide.image("copy")) { [weak self] _ in self?.copySelection() },
                UIAction(title: tr("复制"), image: Lucide.image("duplicate")) { [weak self] _ in self?.duplicateSelection() },
                UIAction(title: tr("删除"), image: Lucide.image("trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
            ]
        }
        rows.append(UIAction(title: tr("粘贴"), image: Lucide.image("paste")) { [weak self] _ in self?.pasteAnything(at: v) })
        return UIMenu(children: rows)
    }

    private func placeMoveLayer() {
        guard let op, op.kind == .move, let sel, slots.indices.contains(op.i) else { return }
        let rect = viewRect(op.i, sel.bbox)
        let z = scroll.zoomScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // It is scaled about the point that stays where it is, which need not be its corner.
        let fixed = viewRect(op.i, Box(op.origin.0, op.origin.1, op.origin.0, op.origin.1)).origin
        moveLayer.bounds = CGRect(origin: .zero, size: rect.size)
        moveLayer.position = CGPoint(x: fixed.x + (rect.minX - fixed.x) * op.s + op.dx * z, y: fixed.y + (rect.minY - fixed.y) * op.s + op.dy * z)
        moveLayer.transform = CATransform3DMakeScale(op.s, op.s, 1)
        CATransaction.commit()
    }

    func placeSelBar() {
        guard let rect = selectionRect(), bounds.intersects(rect) else {
            selBar.isHidden = true
            return
        }
        if selBar.stack.arrangedSubviews.isEmpty { buildSelBar() }
        let size = selBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // The undo and tool option pills float along the top: the bar stays clear of them,
        // going below the selection when there is no room above it.
        let top: CGFloat = bounds.height > 240 ? 64 : 6
        var y = rect.minY - size.height - 14
        if y < top { y = rect.maxY + 18 }
        y = max(top, min(bounds.height - size.height - 6, y))
        let x = min(max(6, rect.midX - size.width / 2), bounds.width - size.width - 6)
        selBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        selBar.isHidden = false
    }

    private func buildSelBar() {
        // The desktop's bar: colour | cut, copy, duplicate, delete, more.
        weak var colorButton: UIButton?
        colorButton = selBar.button("palette", tr("颜色")) { [weak self] in
            guard let self, let colorButton else { return }
            let grid = SwatchGrid(colors: palette) { [weak self] c in self?.recolorSelection(c) }
            grid.popoverPresentationController?.sourceView = colorButton
            grid.popoverPresentationController?.sourceRect = colorButton.bounds
            self.host?.present(grid, animated: true)
        }
        selBar.separator()
        selBar.button("scissors", tr("剪切")) { [weak self] in
            self?.copySelection()
            self?.deleteSelection()
        }
        selBar.button("copy", tr("拷贝")) { [weak self] in self?.copySelection() }
        selBar.button("duplicate", tr("复制")) { [weak self] in self?.duplicateSelection() }
        selBar.button("trash", tr("删除"), tint: Theme.dangerUI) { [weak self] in self?.deleteSelection() }
        let rotate = UIMenu(options: .displayInline, children: [
            UIAction(title: tr("向左旋转"), image: Lucide.image("reset")) { [weak self] _ in self?.rotateSelection(3) },
            UIAction(title: tr("向右旋转"), image: Lucide.image("rotate_cw")) { [weak self] _ in self?.rotateSelection(1) },
        ])
        let order = UIMenu(options: .displayInline, children: [
            UIAction(title: tr("移到最前"), image: Lucide.image("to_front")) { [weak self] _ in self?.restackSelection(front: true) },
            UIAction(title: tr("移到最后"), image: Lucide.image("to_back")) { [weak self] _ in self?.restackSelection(front: false) },
        ])
        let paste = UIMenu(options: .displayInline, children: [
            UIAction(title: tr("粘贴"), image: Lucide.image("paste")) { [weak self] _ in self?.pasteAnything() },
            UIAction(title: tr("截图到剪贴板"), image: Lucide.image("camera")) { [weak self] _ in
                guard let self, let image = self.selectionImage() else { return }
                UIPasteboard.general.image = image
                self.onToast?(tr("截图已拷贝到剪贴板"))
            },
            UIAction(title: tr("存为图片…"), image: Lucide.image("image")) { [weak self] _ in
                guard let self, let image = self.selectionImage(scale: 3) else { return }
                self.onSaveImage?(image)
            },
        ])
        selBar.button("dots", tr("更多"), menu: UIMenu(children: [rotate, order, paste]))
    }

    func deleteSelection() {
        guard let sel else { return }
        self.sel = nil
        doc.removeItems(sel.page, sel.items)
        onSelection?()
        refreshOverlay()
    }

    func duplicateSelection() {
        guard let sel else { return }
        let items = sel.items.map { $0.transformed(1, 0, 0, 14, 14) }
        doc.addItems(sel.page, items)
        select(sel.page, items)
    }

    /// Give the selected ink, shapes and text a colour; pictures are left as they are.
    func recolorSelection(_ color: RGB) {
        guard let sel else { return }
        let news = sel.items.map { it -> Item in
            let new = it.transformed(1, 0, 0, 0, 0)
            (new as? Stroke)?.color = color
            (new as? Shape)?.color = color
            (new as? TextItem)?.color = color
            return new
        }
        doc.replaceItems(sel.page, sel.items, news)
        select(sel.page, news)
    }

    /// Turn the selection k quarter turns clockwise about its own centre (text stays upright).
    func rotateSelection(_ k: Int) {
        guard let sel else { return }
        let page = sel.page, b = sel.bbox
        let turned = sel.items.map { $0.rotated(k % 4, page.w, page.h) }
        var box: Box?
        for it in turned { box = union(box, it.bbox) }
        guard let box else { return }
        let dx = (b.x0 + b.x1 - box.x0 - box.x1) / 2, dy = (b.y0 + b.y1 - box.y0 - box.y1) / 2
        let news = turned.map { $0.transformed(1, 0, 0, dx, dy) }
        doc.replaceItems(page, sel.items, news)
        select(page, news)
    }

    /// Move the selection above (or below) everything else on its page.
    func restackSelection(front: Bool) {
        guard let sel else { return }
        let page = sel.page
        let chosen = Set(sel.items.map { ObjectIdentifier($0) })
        let ordered = page.items.enumerated().filter { chosen.contains(ObjectIdentifier($0.element)) }.map { ($0.offset, $0.element) }
        let base = front ? page.items.count - ordered.count : 0
        doc.perform(.items(page, removed: ordered, added: ordered.enumerated().map { (base + $0.offset, $0.element.1) }))
        refreshOverlay()
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let sel else { return false }
        Self.clip = sel.items.map { $0.transformed(1, 0, 0, 0, 0) }
        onToast?(tr("已拷贝"))
        return true
    }

    /// Put the copied items on the page: a little beside where they were, or centred on a
    /// point of the view.
    @discardableResult
    func paste(at: CGPoint? = nil) -> Bool {
        guard !Self.clip.isEmpty, doc.pages.indices.contains(currentPageIndex()) else { return false }
        if let at, let (i, px, py) = locate(at) {
            let page = doc.pages[i]
            var box: Box?
            for it in Self.clip { box = union(box, it.bbox) }
            let b = box!
            let items = Self.clip.map { $0.transformed(1, 0, 0, px - (b.x0 + b.x1) / 2, py - (b.y0 + b.y1) / 2) }
            doc.addItems(page, items)
            tools.tool = "lasso"
            select(page, items)
            return true
        }
        let page = doc.pages[currentPageIndex()]
        let items = Self.clip.map { $0.transformed(1, 0, 0, 14, 14) }
        Self.clip = items
        doc.addItems(page, items)
        tools.tool = "lasso"
        select(page, items)
        return true
    }

    /// Paste what was copied here, or else a picture from the clipboard.
    func pasteAnything(at: CGPoint? = nil) {
        if paste(at: at) { return }
        guard let image = UIPasteboard.general.image, let (png, w, h) = Self.png(of: image) else { return }
        insertImage(png, width: w, height: h, at: at)
    }

    /// (png bytes, width, height) of a picture, upright and capped at 2000 pixels.
    static func png(of image: UIImage, limit: CGFloat = 2000) -> (Data, Double, Double)? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let k = min(1, limit / max(w, h))
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = small.pngData() else { return nil }
        return (png, Double(size.width), Double(size.height))
    }

    /// Place an image in the middle of the visible part of the current page, or centred on a
    /// point of the view.
    func insertImage(_ png: Data, width: Double, height: Double, at: CGPoint? = nil) {
        let spot = at.flatMap { locate($0) }
        let i = spot?.0 ?? currentPageIndex()
        guard doc.pages.indices.contains(i), width > 0, height > 0 else { return }
        let page = doc.pages[i]
        let region = slots[i].region
        let k = min(1.0, min(region.w, 2000) * 0.6 / width, min(region.h, 2000) * 0.6 / height)
        let w = width * k, h = height * k
        let (cx, cy) = spot.map { ($0.1, $0.2) } ?? toPage(i, CGPoint(x: bounds.midX, y: bounds.midY))
        var x = cx - w / 2, y = cy - h / 2
        if !page.board {
            x = max(0, min(page.w - w, x))
            y = max(0, min(page.h - h, y))
        }
        let item = ImageItem(x, y, w, h, ImageData(png))
        doc.addItems(page, [item])
        tools.tool = "lasso"
        select(page, [item])
    }

    // MARK: text

    private var host: UIViewController? {
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc }
            r = next
        }
        return nil
    }

    func editText(_ i: Int, _ page: Page, _ v: CGPoint, _ px: Double, _ py: Double, note: Bool) {
        let existing = page.items.reversed().first { $0.kind == "t" && $0.bbox.contains(px, py) } as? TextItem
        let color = tools.penColor, size = tools.textSize, noteColor = tools.noteColor
        let entry = TextEntryController(text: existing?.text ?? "", title: tr(note || existing?.bg != nil ? "便签" : "文本框"))
        entry.onClose = { [weak self] text in
            guard let self, self.index(of: page) != nil else { return }
            if let existing {
                guard page.items.contains(where: { $0 === existing }) else { return }
                if text.isEmpty {
                    self.doc.removeItems(page, [existing])
                } else if text != existing.text {
                    let new = TextItem(existing.x, existing.y, text, existing.size, existing.color, wrap: existing.wrap, bg: existing.bg)
                    self.doc.replaceItems(page, [existing], [new])
                }
            } else if !text.isEmpty && note {
                self.doc.addItems(page, [TextItem(px, py, text, 13.0, RGB(0.16, 0.15, 0.12), wrap: 170.0, bg: noteColor)])
            } else if !text.isEmpty {
                self.doc.addItems(page, [TextItem(px, py, text, size, color, wrap: page.board ? 400.0 : max(60.0, page.w - px - 12))])
            }
        }
        let nav = UINavigationController(rootViewController: entry)
        nav.modalPresentationStyle = .popover
        nav.popoverPresentationController?.sourceView = self
        nav.popoverPresentationController?.sourceRect = CGRect(x: v.x - 1, y: v.y - 1, width: 2, height: 2)
        host?.present(nav, animated: true)
    }
}
