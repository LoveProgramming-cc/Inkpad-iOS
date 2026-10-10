import UIKit

/// The ruler that lies on the screen: a stroke begun at one of its long edges runs along it.
/// A finger moves it and two fingers turn it; the pencil writes across it.
final class RulerView: UIView, UIGestureRecognizerDelegate {
    static let halfWidth: CGFloat = 46   // half the ruler's width
    static let snap: CGFloat = 18        // how near its edge a stroke has to start to follow it

    weak var canvas: CanvasView?
    private(set) var angle: CGFloat = 0
    private var turnedFrom: CGFloat = 0
    private var pan: UIPanGestureRecognizer!

    var half: CGFloat { bounds.width / 2 }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        resize()
        center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = fingers
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)
        let turn = UIRotationGestureRecognizer(target: self, action: #selector(turned(_:)))
        turn.allowedTouchTypes = fingers
        turn.delegate = self
        addGestureRecognizer(turn)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// As long as the window allows, and never shorter than is useful.
    func resize() {
        guard let canvas else { return }
        let length = max(260, 0.42 * max(canvas.bounds.width, canvas.bounds.height))
        let t = transform
        transform = .identity
        bounds = CGRect(x: 0, y: 0, width: 2 * length, height: 2 * Self.halfWidth)
        transform = t
        setNeedsDisplay()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // A finger that may write and starts at the edge draws along it instead.
        guard g === pan, let canvas, canvas.fingersWrite else { return true }
        return canvas.rulerZone(g.location(in: canvas)) != .edge
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let canvas else { return }
        let d = g.translation(in: canvas)
        g.setTranslation(.zero, in: canvas)
        center = CGPoint(x: min(max(center.x + d.x, 0), canvas.bounds.width), y: min(max(center.y + d.y, 0), canvas.bounds.height))
    }

    @objc private func turned(_ g: UIRotationGestureRecognizer) {
        if g.state == .began { turnedFrom = angle }
        turn(to: turnedFrom + g.rotation)
    }

    /// Settle on the nearest 45 degrees when turned to within a degree and a half of it.
    func turn(to a: CGFloat) {
        let near = (a / (.pi / 4)).rounded() * (.pi / 4)
        angle = abs(a - near) < 1.5 * .pi / 180 ? near : a
        transform = CGAffineTransform(rotationAngle: angle)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let g = UIGraphicsGetCurrentContext(), let canvas else { return }
        let w = Self.halfWidth, half = half
        let ink = UIColor(red: 0.22, green: 0.25, blue: 0.32, alpha: 0.9)
        g.translateBy(x: half, y: w)
        g.setFillColor(UIColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 0.66).cgColor)
        g.fill(CGRect(x: -half, y: -w, width: 2 * half, height: 2 * w))
        g.setFillColor(ink.cgColor)
        g.fill(CGRect(x: -half, y: -w, width: 2 * half, height: 1))
        g.fill(CGRect(x: -half, y: w - 1, width: 2 * half, height: 1))
        // The scale is the page's own: a centimetre on the ruler is a centimetre on the printed
        // page, so it grows and shrinks with the zoom.
        let mm = 72 / 25.4 * CGFloat(canvas.zoom)
        let step = [1, 5, 10, 50, 100, 500, 1000].first { CGFloat($0) * mm >= 3 } ?? 5000
        let every = [10, 50, 100, 500, 1000, 5000].first { $0 >= step && CGFloat($0) * mm >= 26 } ?? 10000
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10.5), .foregroundColor: ink]
        let start = -half + 12
        var n = 0
        while start + CGFloat(n) * mm <= half - 6 {
            let u = start + CGFloat(n) * mm
            let long = n % (step < 10 ? step * 10 : every) == 0
            let size: CGFloat = long ? 15 : n % (step * 5) == 0 ? 10 : 6
            g.fill(CGRect(x: u - 0.5, y: -w, width: 1, height: size))
            g.fill(CGRect(x: u - 0.5, y: w - size, width: 1, height: size))
            if n % every == 0 {
                (String(format: "%g", Double(n) / 10) as NSString).draw(at: CGPoint(x: u + 3, y: -w + 13), withAttributes: attrs)
            }
            n += step
        }
        let degrees = ((Int((angle * 180 / .pi).rounded()) % 180) + 180) % 180
        ("\(degrees)°  cm" as NSString).draw(at: CGPoint(x: -12, y: w - 30), withAttributes: attrs)
    }
}

/// The whiteboard navigator: a small map of where the board is written on, with the part
/// on screen marked, the zoom level, and a button that brings all of it into view.
final class MinimapView: UIView {
    static let mapSize = CGSize(width: 216, height: 150)

    weak var canvas: CanvasView?
    private let map = MapView()
    private let zoomButton = UIButton(type: .system)
    private var timer: Timer?

    final class MapView: UIView {
        weak var canvas: CanvasView?
        var cells = Set<SIMD2<Int32>>()   // occupied grid cells of the board's content
        var cell = 1.0                    // their size in page points
        var box: Box?                     // the page area the cells cover
        private var fit: (Double, Double, Double, Double, Double)?   // region x0, y0, scale, offset x, y of the last frame

        /// Work out which parts of the board are written on. The map does not draw the ink
        /// itself, which would be illegible at this size: it marks the occupied areas with
        /// small blocks.
        func render() {
            guard let canvas, canvas.doc.pages.indices.contains(canvas.boardAt) else { return }
            let page = canvas.doc.pages[canvas.boardAt]
            let b = page.box
            box = b
            let size = max(b.w / 64, b.h / 44, 1e-6)
            var found = Set<SIMD2<Int32>>()
            for it in page.items {
                if it.kind == "i" || it.kind == "t" {
                    let bb = it.bbox
                    for cx in Int32((bb.x0 - b.x0) / size)...Int32((bb.x1 - b.x0) / size) {
                        for cy in Int32((bb.y0 - b.y0) / size)...Int32((bb.y1 - b.y0) / size) { found.insert(SIMD2(cx, cy)) }
                    }
                } else {
                    let line = it.polyline()
                    guard !line.isEmpty else { continue }
                    for p in line.count > 1 ? Geom.densify(line, size * 0.45) : line {
                        found.insert(SIMD2(Int32((p.x - b.x0) / size), Int32((p.y - b.y0) / size)))
                    }
                }
            }
            cell = size
            cells = found
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard let g = UIGraphicsGetCurrentContext(), let canvas, let view = canvas.viewBox() else { return }
            let w = Double(bounds.width), h = Double(bounds.height)
            // The map covers the content and wherever the view currently is.
            var r = box.map { $0.union(view) } ?? view
            r = r.padded(0.04 * max(r.w, r.h))
            let s = min(w / r.w, h / r.h)
            let ox = (w - r.w * s) / 2, oy = (h - r.h * s) / 2
            fit = (r.x0, r.y0, s, ox, oy)
            if let box, !cells.isEmpty {
                g.setFillColor(UIColor.label.withAlphaComponent(0.55).cgColor)
                let side = max(cell * s + 0.6, 2.0)   // a little overlap, so neighbours read as one block
                for c in cells {
                    g.fill(CGRect(x: ox + (box.x0 + Double(c.x) * cell - r.x0) * s, y: oy + (box.y0 + Double(c.y) * cell - r.y0) * s, width: side, height: side))
                }
            }
            let seen = CGRect(x: ox + (view.x0 - r.x0) * s, y: oy + (view.y0 - r.y0) * s, width: view.w * s, height: view.h * s)
            g.setFillColor(UIColor(red: 0.21, green: 0.52, blue: 0.89, alpha: 0.22).cgColor)
            g.fill(seen)
            g.setStrokeColor(UIColor(red: 0.21, green: 0.52, blue: 0.89, alpha: 0.9).cgColor)
            g.setLineWidth(1.2)
            g.stroke(seen)
        }

        @objc func go(_ g: UIGestureRecognizer) {
            guard let fit, let canvas else { return }
            let p = g.location(in: self)
            canvas.center(at: canvas.boardAt, fit.0 + (Double(p.x) - fit.3) / fit.2, fit.1 + (Double(p.y) - fit.4) / fit.2)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Self.mapSize.width, height: Self.mapSize.height + 35)))
        backgroundColor = Theme.popoverUI
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.withAlphaComponent(0.05).cgColor
        let clip = UIView(frame: bounds)
        clip.layer.cornerRadius = 16
        clip.layer.cornerCurve = .continuous
        clip.clipsToBounds = true
        addSubview(clip)
        map.frame = CGRect(origin: .zero, size: Self.mapSize)
        map.isOpaque = false
        map.backgroundColor = .clear
        map.clipsToBounds = true
        let drag = UIPanGestureRecognizer(target: map, action: #selector(MapView.go(_:)))
        let tap = UITapGestureRecognizer(target: map, action: #selector(MapView.go(_:)))
        map.addGestureRecognizer(drag)
        map.addGestureRecognizer(tap)
        clip.addSubview(map)
        let line = UIColor.label.withAlphaComponent(0.10)
        let across = UIView(frame: CGRect(x: 0, y: Self.mapSize.height, width: bounds.width, height: 1))
        across.backgroundColor = line
        clip.addSubview(across)
        let y = Self.mapSize.height + 1
        zoomButton.frame = CGRect(x: 0, y: y, width: bounds.width - 45, height: 34)
        zoomButton.tintColor = .label
        zoomButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        zoomButton.accessibilityLabel = tr("恢复 100%")
        zoomButton.addAction(UIAction { [weak self] _ in self?.canvas?.setZoom(1) }, for: .touchUpInside)
        clip.addSubview(zoomButton)
        let down = UIView(frame: CGRect(x: bounds.width - 45, y: y, width: 1, height: 34))
        down.backgroundColor = line
        clip.addSubview(down)
        let fit = UIButton(type: .system)
        fit.frame = CGRect(x: bounds.width - 44, y: y, width: 44, height: 34)
        fit.setImage(Lucide.image("fit_all"), for: .normal)
        fit.tintColor = .label
        fit.accessibilityLabel = tr("显示全部内容")
        fit.addAction(UIAction { [weak self] _ in self?.canvas?.fitContent() }, for: .touchUpInside)
        clip.addSubview(fit)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        map.canvas = canvas
    }

    func refresh() {
        guard !isHidden, let canvas else { return }
        map.canvas = canvas
        zoomButton.setTitle("\(Int((canvas.zoom * 100).rounded()))%", for: .normal)
        map.setNeedsDisplay()
    }

    /// The board was drawn on: update the picture shortly, not on every stroke point.
    func contentChanged() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.map.canvas = self?.canvas
            self?.map.render()
            self?.refresh()
        }
    }
}

enum RulerZone { case edge, body }

extension CanvasView {
    // MARK: where the view is

    /// The scroll position or the zoom changed.
    func viewMoved() {
        // Whatever is drawn over the pages has to follow them, the stroke being written included.
        if sel != nil || op != nil || !marks.isEmpty || !laserTrails.isEmpty || laserDot != nil { refreshOverlay() }
        minimap.refresh()
        hoverLayer.isHidden = true
    }

    func placeMinimap() {
        let size = minimap.bounds.size
        minimap.frame = CGRect(x: 14, y: bounds.height - size.height - 14 - safeAreaInsets.bottom, width: size.width, height: size.height)
    }

    /// The part of the current page that is on screen, in page points (not clamped).
    func viewBox() -> Box? {
        let i = currentPageIndex()
        guard slots.indices.contains(i), slots.count == doc.pages.count else { return nil }
        let a = toPage(i, .zero), b = toPage(i, CGPoint(x: bounds.width, y: bounds.height))
        return Box(a.0, a.1, b.0, b.1)
    }

    /// Zoom and scroll so that everything on the current whiteboard is visible.
    func fitContent() {
        let i = currentPageIndex()
        guard doc.pages.indices.contains(i) else { return }
        let box = doc.pages[i].box
        let z = min(bounds.width / box.w, bounds.height / box.h) * 0.92
        scroll.zoomScale = max(scroll.minimumZoomScale, min(1.5, z))
        centerContent()
        center(at: i, (box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2)
        updateVisible()
        refreshOverlay()
    }

    /// Where the view is, in a form that outlasts the editor: the zoom and the point of the
    /// document in the middle of the window.
    func viewMemo() -> [Double]? {
        guard let (page, px, py) = anchorNow(), let i = index(of: page), page.w > 0, page.h > 0 else { return nil }
        return [zoom, Double(i), px / page.w, py / page.h]
    }

    /// Go to the place remembered with viewMemo(); false when there is none to go to.
    func applyMemo() -> Bool {
        guard let m = memo, m.count == 4, m.allSatisfy(\.isFinite), m[0] > 0 else { return false }
        memo = nil
        let i = Int(m[1])
        guard doc.pages.indices.contains(i) else { return false }
        if isBoard && i != boardAt {
            boardAt = i
            relayout()   // comes back here with the memo used up; the lines below then place the view
        }
        let page = doc.pages[i]
        scroll.zoomScale = max(scroll.minimumZoomScale, min(scroll.maximumZoomScale, CGFloat(m[0])))
        centerContent()
        if across && scroll.zoomScale <= scroll.minimumZoomScale * 1.01 {
            scrollToPage(i, animated: false)
        } else {
            center(at: i, m[2] * page.w, m[3] * page.h)
        }
        return true
    }

    // MARK: the input log

    /// Note a pen or touch event in the log, when the settings ask for one.
    func log(_ text: @autoclosure () -> String) {
        guard tools.p.inputLog else { return }
        let line = String(format: "%.3f  %@\n", ProcessInfo.processInfo.systemUptime, text())
        let url = Self.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static var logURL: URL {
        Platform.libraryRoot.appendingPathComponent("input.log")
    }

    func describe(_ t: UITouch) -> String {
        let kind = t.type == .pencil ? "pencil" : t.type == .indirectPointer ? "mouse" : "finger"
        let p = t.location(in: self)
        return String(format: "%@ at %.0f,%.0f", kind, p.x, p.y)
    }

    // MARK: the mark under a hovering pencil

    @objc func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed, op == nil else {
            hoverLayer.isHidden = true
            return
        }
        let p = g.location(in: self)
        hoverAt = p
        if let ruler, ruler.frame.contains(p), rulerZone(p) == .body, tools.tool == "lasso" {
            hoverLayer.isHidden = true
            return
        }
        let tool = tools.tool
        var path = CGMutablePath()
        var width: CGFloat = 1.2
        if tool == "text" || tool == "note" {
            // The text caret.
            path.move(to: CGPoint(x: 0, y: -9)); path.addLine(to: CGPoint(x: 0, y: 9))
            path.move(to: CGPoint(x: -3, y: -9)); path.addLine(to: CGPoint(x: 3, y: -9))
            path.move(to: CGPoint(x: -3, y: 9)); path.addLine(to: CGPoint(x: 3, y: 9))
        } else if tool == "eraser" {
            width = 2.4
            path.move(to: CGPoint(x: -7, y: 0)); path.addLine(to: CGPoint(x: 7, y: 0))
            path.move(to: CGPoint(x: 0, y: -7)); path.addLine(to: CGPoint(x: 0, y: 7))
        } else if tools.p.crosshair {
            path.move(to: CGPoint(x: -10, y: 0)); path.addLine(to: CGPoint(x: -2.5, y: 0))
            path.move(to: CGPoint(x: 2.5, y: 0)); path.addLine(to: CGPoint(x: 10, y: 0))
            path.move(to: CGPoint(x: 0, y: -10)); path.addLine(to: CGPoint(x: 0, y: -2.5))
            path.move(to: CGPoint(x: 0, y: 2.5)); path.addLine(to: CGPoint(x: 0, y: 10))
            path.addEllipse(in: CGRect(x: -0.6, y: -0.6, width: 1.2, height: 1.2))
        } else {
            // Only the centre of the crosshair.
            width = 1
            path.addEllipse(in: CGRect(x: -2.1, y: -2.1, width: 4.2, height: 4.2))
        }
        var ink = UIColor(white: 0.1, alpha: 0.95)
        var edge = ink
        if !tools.p.crosshair, tool == "pen" || tool == "hl" || tool == "shape" {
            // The mark a pen is about to leave: its colour, and its width at this zoom.
            let hl = tool == "hl"
            let d = max(2.5, CGFloat(hl ? tools.hlWidth : tools.penWidth) * CGFloat(zoom))
            path = CGMutablePath()
            path.addEllipse(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
            ink = (hl ? tools.hlColor : tools.penColor).ui.withAlphaComponent(hl ? 0.55 : 1)
            // A thin rim, so that a pale colour still shows on pale paper.
            edge = UIColor(white: 0.1, alpha: 0.35)
            width = 0.5
        }
        hoverLayer.path = path
        hoverLayer.lineWidth = width
        hoverLayer.lineCap = .round
        hoverLayer.strokeColor = edge.cgColor
        hoverLayer.fillColor = tools.p.crosshair || tool == "eraser" || tool == "text" || tool == "note" ? nil : ink.cgColor
        hoverLayer.shadowColor = UIColor.white.cgColor
        hoverLayer.shadowOpacity = 0.9
        hoverLayer.shadowRadius = 0.8
        hoverLayer.shadowOffset = .zero
        hoverLayer.position = p
        hoverLayer.isHidden = false
    }

    // MARK: ruler

    func setRuler(_ on: Bool) {
        if on, ruler == nil {
            let new = RulerView(canvas: self)
            insertSubview(new, belowSubview: selBar)
            ruler = new
        } else if !on {
            ruler?.removeFromSuperview()
            ruler = nil
        }
    }

    /// A view point as (distance along the ruler, distance across it) from its centre.
    private func rulerLocal(_ v: CGPoint) -> (CGFloat, CGFloat)? {
        guard let ruler else { return nil }
        let c = cos(ruler.angle), s = sin(ruler.angle)
        let dx = v.x - ruler.center.x, dy = v.y - ruler.center.y
        return (dx * c + dy * s, -dx * s + dy * c)
    }

    /// Near one of the long edges, on the ruler itself, or nil elsewhere.
    func rulerZone(_ v: CGPoint) -> RulerZone? {
        guard let ruler, let (u, w) = rulerLocal(v) else { return nil }
        if abs(u) > ruler.half + RulerView.snap { return nil }
        if abs(abs(w) - RulerView.halfWidth) <= RulerView.snap { return .edge }
        return abs(w) < RulerView.halfWidth ? .body : nil
    }

    /// The long edge nearest a point, as a point on it and its direction.
    func rulerEdge(_ v: CGPoint) -> (CGPoint, CGVector)? {
        guard let ruler, let (_, w) = rulerLocal(v) else { return nil }
        let c = cos(ruler.angle), s = sin(ruler.angle)
        let side: CGFloat = w >= 0 ? 1 : -1
        return (CGPoint(x: ruler.center.x - s * RulerView.halfWidth * side, y: ruler.center.y + c * RulerView.halfWidth * side), CGVector(dx: c, dy: s))
    }

    func onto(_ line: (CGPoint, CGVector), _ v: CGPoint) -> CGPoint {
        let t = (v.x - line.0.x) * line.1.dx + (v.y - line.0.y) * line.1.dy
        return CGPoint(x: line.0.x + t * line.1.dx, y: line.0.y + t * line.1.dy)
    }

    // MARK: laser pointer

    static let laserHold = 1.0    // a trail stays this long after the last stroke
    static let laserFade = 0.35

    /// Any laser activity keeps what is on screen and restarts the countdown.
    func laserReset() {
        laserTimer?.invalidate()
        laserTimer = nil
        laserAlpha = 1
    }

    func laserExpire() {
        let began = CACurrentMediaTime()
        laserTimer?.invalidate()
        laserTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = (CACurrentMediaTime() - began) / Self.laserFade
            if t >= 1 {
                timer.invalidate()
                self.laserTimer = nil
                self.laserTrails = []
                self.laserAlpha = 1
            } else {
                self.laserAlpha = CGFloat(1 - t)
            }
            self.overlay.setNeedsDisplay()
        }
    }

    func clearLaser() {
        laserReset()
        guard !laserTrails.isEmpty || laserDot != nil else { return }
        laserTrails = []
        laserDot = nil
        overlay.setNeedsDisplay()
    }

    func drawLaser(_ g: CGContext) {
        let color = tools.laserColor
        g.saveGState()
        g.setAlpha(laserAlpha)
        g.setLineCap(.round)
        g.setLineJoin(.round)
        for (page, pts) in laserTrails {
            guard let i = index(of: page), slots.indices.contains(i), let first = pts.first else { continue }
            let t = pageToView(i)
            let line = pts.map { CGPoint(x: $0.x, y: $0.y).applying(t) }
            let path = CGMutablePath()
            path.move(to: line[0])
            if line.count < 3 {
                path.addLine(to: line.count == 2 ? line[1] : CGPoint(x: CGFloat(first.x + 0.01), y: CGFloat(first.y)).applying(t))
            } else {
                // Rounded through the middles of its segments.
                for k in 1..<(line.count - 1) {
                    path.addQuadCurve(to: CGPoint(x: (line[k].x + line[k + 1].x) / 2, y: (line[k].y + line[k + 1].y) / 2), control: line[k])
                }
                path.addLine(to: line[line.count - 1])
            }
            for (width, paint) in [(13.0, color.cg(0.16)), (7.0, color.cg(0.45)), (3.6, color.cg()), (1.3, RGB.white.cg(0.9))] {
                g.addPath(path)
                g.setStrokeColor(paint)
                g.setLineWidth(width)
                g.strokePath()
            }
        }
        if let dot = laserDot, let i = index(of: dot.page), slots.indices.contains(i) {
            let c = CGPoint(x: dot.x, y: dot.y).applying(pageToView(i))
            for (radius, paint) in [(15.0, color.cg(0.14)), (10.0, color.cg(0.3)), (6.0, color.cg()), (2.4, RGB.white.cg(0.9))] {
                g.setFillColor(paint)
                g.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        g.restoreGState()
    }

    // MARK: pictures of the page

    /// The selected area of the page, paper included.
    func selectionImage(scale: Double = 2) -> UIImage? {
        guard let sel else { return nil }
        let page = sel.page
        var b = sel.bbox.padded(6)
        if !page.board { b = Box(max(0, b.x0), max(0, b.y0), min(page.w, b.x1), min(page.h, b.y1)) }
        guard b.w > 0, b.h > 0 else { return nil }
        let k = min(scale, 6000 / max(b.w, b.h))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let snap = page.snap
        return UIGraphicsImageRenderer(size: CGSize(width: max(1, (b.w * k).rounded()), height: max(1, (b.h * k).rounded())), format: format).image { ctx in
            let g = ctx.cgContext
            g.scaleBy(x: k, y: k)
            g.translateBy(x: -b.x0, y: -b.y0)
            renderPage(g, snap)
        }
    }
}
