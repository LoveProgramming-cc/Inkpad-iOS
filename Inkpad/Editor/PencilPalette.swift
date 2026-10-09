import Combine
import UIKit

/// The tools on two arcs around the pencil's tip, shown by squeezing an Apple Pencil Pro:
/// undo, redo and the tools on the inner arc (the tools scroll along it), and the colours
/// and widths of the tool in hand on the outer one.
final class PencilPalette: UIView {
    private struct Spot {
        let label: String
        let at: CGPoint
        let on: Bool
        let enabled: Bool
        let draw: (CGContext, CGPoint, Bool) -> Void
        let act: () -> Void
    }

    // Angles are in degrees, clockwise from the right as the screen has them: 180 is to the
    // left of the centre and 270 above it.
    static let inner: CGFloat = 170, outer: CGFloat = 230
    static let thick: CGFloat = 54, thin: CGFloat = 44
    static let step: CGFloat = 16          // between two icons of the inner arc
    static let first: CGFloat = 180        // undo
    static let toolsFrom: CGFloat = 207, toolsTo: CGFloat = 284
    static let reach: CGFloat = 262        // how far the arcs go from the centre
    /// Where the arcs are, relative to the centre: what has to stay on screen.
    static let extent = CGRect(x: -262, y: -262, width: 262 + 72, height: 262 + 40)

    private let tools: ToolState
    private weak var canvas: CanvasView?
    private var offset: CGFloat = 0        // how far the tools have been scrolled, in degrees
    private var lastAngle: CGFloat = 0
    private var scrolling = false
    private var speed: CGFloat = 0         // degrees per second, while the tools glide on
    private var glide: CADisplayLink?
    private var watch: AnyCancellable?
    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    init(tools: ToolState, canvas: CanvasView) {
        self.tools = tools
        self.canvas = canvas
        super.init(frame: CGRect(x: 0, y: 0, width: Self.reach * 2, height: Self.reach * 2))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 9
        layer.shadowOffset = CGSize(width: 0, height: 3)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        // The header bar can change the tool too while this is up.
        watch = tools.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        offset = clampedOffset(CGFloat(max(0, entries.firstIndex { $0.on } ?? 0) - 2) * Self.step)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { glide?.invalidate() }

    // MARK: what is on the arcs

    private var entries: [(label: String, icon: String, on: Bool, pick: () -> Void)] {
        let tools = tools
        var list: [(String, String, Bool, () -> Void)] = []
        for (id, icon, label) in toolList where id == "pen" || !tools.p.hiddenTools.contains(id) {
            if id == "pen" {
                // Each kind of pen has its own place, as the tools do.
                for (kind, icon, label) in penList {
                    list.append((tr(label), icon, tools.tool == "pen" && tools.p.penType == kind, {
                        tools.p.penType = kind
                        tools.tool = "pen"
                    }))
                }
            } else {
                list.append((tr(label), icon, tools.tool == id, { tools.tool = id }))
            }
        }
        return list
    }

    private func point(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a))
    }

    private func angle(_ p: CGPoint) -> CGFloat {
        let a = atan2(p.y - centre.y, p.x - centre.x) * 180 / .pi
        return a < 0 ? a + 360 : a
    }

    private func band(_ radius: CGFloat, _ from: CGFloat, _ to: CGFloat, _ width: CGFloat, round: Bool = true) -> CGPath {
        let arc = UIBezierPath(arcCenter: centre, radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: true)
        return arc.cgPath.copy(strokingWithWidth: width, lineCap: round ? .round : .butt, lineJoin: .round, miterLimit: 4)
    }

    private var innerBand: CGPath { band(Self.inner, Self.first, Self.toolsTo - 3, Self.thick) }
    private var toolsBand: CGPath { band(Self.inner, Self.toolsFrom, Self.toolsTo, Self.thick, round: false) }

    /// The segments of the outer arc: the colours, then the widths, of the tool in hand.
    private var groups: [[Spot]] {
        let tools = tools
        var out: [[Spot]] = []
        func swatch(_ color: RGB, _ label: String, _ on: Bool, _ act: @escaping () -> Void) -> Spot {
            Spot(label: label, at: .zero, on: on, enabled: true, draw: { ctx, at, on in
                let box = CGRect(x: at.x - 12, y: at.y - 12, width: 24, height: 24)
                ctx.setFillColor(UIColor(red: color.r, green: color.g, blue: color.b, alpha: 1).cgColor)
                ctx.fillEllipse(in: box)
                ctx.setStrokeColor(UIColor.label.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: box)
                if on {
                    ctx.setStrokeColor(Theme.accentUI.cgColor)
                    ctx.setLineWidth(2.5)
                    ctx.strokeEllipse(in: box.insetBy(dx: -4, dy: -4))
                }
            }, act: act)
        }
        func dot(_ size: CGFloat, _ label: String, _ on: Bool, _ act: @escaping () -> Void) -> Spot {
            Spot(label: label, at: .zero, on: on, enabled: true, draw: { ctx, at, on in
                if on {
                    ctx.setFillColor(Theme.accentUI.withAlphaComponent(0.22).cgColor)
                    ctx.fillEllipse(in: CGRect(x: at.x - 16, y: at.y - 16, width: 32, height: 32))
                }
                ctx.setFillColor((on ? Theme.accentUI : UIColor.label).cgColor)
                ctx.fillEllipse(in: CGRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size))
            }, act: act)
        }
        let sizes: [CGFloat] = [6, 10, 15]
        switch tools.tool {
        case "pen":
            out.append(tools.p.penColors.enumerated().map { i, c in
                swatch(RGB(c), tr("颜色") + " \(i + 1)", i == tools.p.penColor) { tools.p.penColor = i }
            })
            out.append((0..<3).map { i in dot(sizes[i], tr("粗细") + " \(i + 1)", i == tools.pen.slot) { tools.pen.slot = i } })
        case "hl":
            out.append(tools.p.hlColors.enumerated().map { i, c in
                swatch(RGB(c), tr("颜色") + " \(i + 1)", i == tools.p.hlColor) { tools.p.hlColor = i }
            })
            out.append((0..<3).map { i in dot(sizes[i], tr("粗细") + " \(i + 1)", i == tools.p.hlW) { tools.p.hlW = i } })
        case "eraser":
            out.append((0..<3).map { i in dot(sizes[i], tr("粗细") + " \(i + 1)", i == tools.p.eraserSize) { tools.p.eraserSize = i } })
        case "tape":
            out.append(tapeColors.enumerated().map { i, c in
                swatch(c, tr("颜色") + " \(i + 1)", i == tools.p.tapeColor) { tools.p.tapeColor = i }
            })
            out.append((0..<3).map { i in dot(sizes[i], tr("粗细") + " \(i + 1)", i == tools.p.tapeW) { tools.p.tapeW = i } })
        case "note":
            out.append(noteColors.enumerated().map { i, c in
                swatch(c, tr("颜色") + " \(i + 1)", i == tools.p.noteColor) { tools.p.noteColor = i }
            })
        case "laser":
            out.append(laserColors.enumerated().map { i, c in
                swatch(c, tr("颜色") + " \(i + 1)", i == tools.p.laserColor) { tools.p.laserColor = i }
            })
        default:
            break
        }
        // Along the arc: 9.5 degrees from one to the next, and a gap between the segments.
        var at: CGFloat = 186
        return out.map { group in
            let placed = group.enumerated().map { i, s in
                Spot(label: s.label, at: point(Self.outer, at + CGFloat(i) * 9.5), on: s.on, enabled: true, draw: s.draw, act: s.act)
            }
            at += CGFloat(group.count - 1) * 9.5 + 20
            return placed
        }
    }

    private func icon(_ name: String, _ label: String, _ degrees: CGFloat, on: Bool, enabled: Bool = true, act: @escaping () -> Void) -> Spot {
        Spot(label: label, at: point(Self.inner, degrees), on: on, enabled: enabled, draw: { ctx, at, on in
            if on {
                ctx.setFillColor(Theme.accentUI.cgColor)
                ctx.fillEllipse(in: CGRect(x: at.x - 20, y: at.y - 20, width: 40, height: 40))
            }
            let tint: UIColor = on ? .white : enabled ? .label : UIColor.label.withAlphaComponent(0.3)
            Lucide.image(name, size: 22)?.withTintColor(tint, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: at.x - 11, y: at.y - 11))
        }, act: act)
    }

    private var fixed: [Spot] {
        let doc = canvas?.doc
        return [
            icon("undo", tr("撤销"), Self.first, on: false, enabled: doc?.canUndo ?? false) { [weak self] in self?.canvas?.undo() },
            icon("redo", tr("重做"), Self.first + Self.step, on: false, enabled: doc?.canRedo ?? false) { [weak self] in self?.canvas?.redo() },
        ]
    }

    private var scrolled: [Spot] {
        entries.enumerated().map { i, e in
            icon(e.icon, e.label, Self.toolsFrom + 9 + CGFloat(i) * Self.step - offset, on: e.on, act: e.pick)
        }
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        let most = CGFloat(entries.count - 1) * Self.step + 18 - (Self.toolsTo - Self.toolsFrom)
        return min(max(0, value), max(0, most))
    }

    // MARK: drawing

    func refresh() {
        let shape = CGMutablePath()
        shape.addPath(innerBand)
        for group in groups { shape.addPath(segment(group)) }
        layer.shadowPath = shape
        setNeedsDisplay()
        // Each thing on the arcs is a button to VoiceOver, and to the tests.
        let toolsBand = toolsBand
        let seen = fixed + scrolled.filter { toolsBand.contains($0.at) } + groups.flatMap { $0 }
        accessibilityElements = seen.map { spot in
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = spot.label
            element.accessibilityIdentifier = "palette-" + spot.label
            element.accessibilityTraits = spot.on ? [.button, .selected] : .button
            element.accessibilityFrameInContainerSpace = CGRect(x: spot.at.x - 18, y: spot.at.y - 18, width: 36, height: 36)
            return element
        }
    }

    private func segment(_ group: [Spot]) -> CGPath {
        guard let a = group.first, let b = group.last else { return CGMutablePath() }
        return band(Self.outer, angle(a.at), max(angle(a.at) + 0.01, angle(b.at)), Self.thin)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let fill = Theme.popoverUI.resolvedColor(with: traitCollection).cgColor
        let line = UIColor.label.withAlphaComponent(0.12).cgColor
        var bands = [innerBand]
        bands += groups.map(segment)
        for path in bands {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(line)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        for spot in fixed + groups.flatMap({ $0 }) { spot.draw(ctx, spot.at, spot.on) }
        // The line between redo and the tools.
        ctx.move(to: point(Self.inner - 15, Self.toolsFrom - 2))
        ctx.addLine(to: point(Self.inner + 15, Self.toolsFrom - 2))
        ctx.setStrokeColor(UIColor.label.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        // The tools show only inside their stretch of the arc.
        ctx.saveGState()
        ctx.addPath(band(Self.inner, Self.toolsFrom, Self.toolsTo - 3, Self.thick))
        ctx.clip()
        ctx.addPath(band(Self.inner, Self.toolsFrom, Self.toolsTo + 12, Self.thick, round: false))
        ctx.clip()
        for spot in scrolled { spot.draw(ctx, spot.at, spot.on) }
        ctx.restoreGState()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsDisplay()
    }

    // MARK: touches

    /// Only the arcs take touches: the page between and around them is still the page.
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        if innerBand.contains(p) { return true }
        return groups.contains { segment($0).contains(p) }
    }

    private func spot(at p: CGPoint) -> Spot? {
        var all = fixed + groups.flatMap { $0 }
        if toolsBand.contains(p) || band(Self.inner, Self.toolsTo, Self.toolsTo + 14, Self.thick).contains(p) { all += scrolled }
        let near = all.min { hypot($0.at.x - p.x, $0.at.y - p.y) < hypot($1.at.x - p.x, $1.at.y - p.y) }
        guard let near, near.enabled, hypot(near.at.x - p.x, near.at.y - p.y) < 26 else { return nil }
        return near
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        stopGlide()
        guard let spot = spot(at: g.location(in: self)) else { return }
        spot.act()
        refresh()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            stopGlide()
            scrolling = toolsBand.contains(p) || band(Self.inner, Self.toolsTo, Self.toolsTo + 14, Self.thick).contains(p)
            lastAngle = angle(p)
        case .changed where scrolling:
            let a = angle(p)
            offset = clampedOffset(offset - (a - lastAngle))
            lastAngle = a
            refresh()
        case .ended where scrolling:
            // The speed along the arc, as an angle: the tools glide on and slow down.
            let v = g.velocity(in: self), a = angle(p) * .pi / 180
            let along = -v.x * sin(a) + v.y * cos(a)
            speed = along / Self.inner * 180 / .pi
            if abs(speed) > 30 {
                glide = CADisplayLink(target: self, selector: #selector(glided(_:)))
                glide?.add(to: .main, forMode: .common)
            }
            scrolling = false
        default:
            if g.state != .changed { scrolling = false }
        }
    }

    @objc private func glided(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        let next = clampedOffset(offset - speed * dt)
        speed *= pow(0.004, dt)
        if next == offset || abs(speed) < 8 { stopGlide() }
        offset = next
        refresh()
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
    }
}

extension CanvasView {
    /// The pencil was squeezed: the palette comes up around its tip, or goes away again.
    func togglePalette(at tip: CGPoint?) {
        if toolRing != nil {
            hidePalette()
            return
        }
        cancelOp()
        let p = tip ?? (hoverAt.x.isFinite ? hoverAt : CGPoint(x: bounds.midX, y: bounds.midY))
        let view = PencilPalette(tools: tools, canvas: self)
        // The middle of the arcs lies up and to the left of the tip, clear of the hand, and
        // all of them stay on screen.
        let e = PencilPalette.extent
        var c = CGPoint(x: p.x + 118, y: p.y + 140)
        c.x = max(12 - e.minX, min(bounds.width - 12 - e.maxX, c.x))
        c.y = max(12 - e.minY, min(bounds.height - 12 - e.maxY, c.y))
        view.center = c
        addSubview(view)
        toolRing = view
        hoverLayer.isHidden = true
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.16) {
            view.alpha = 1
            view.transform = .identity
        }
    }

    func hidePalette() {
        guard let view = toolRing else { return }
        toolRing = nil
        UIView.animate(withDuration: 0.14, animations: { view.alpha = 0 }, completion: { _ in view.removeFromSuperview() })
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard tools.p.pencilSqueeze, squeeze.phase == .ended else { return }
        togglePalette(at: squeeze.hoverPose?.location)
    }
}
