import UIKit

/// Draws whatever is in flux above the pages: the stroke being written, the lasso, the
/// eraser ring and the selection box. It never takes touches.
final class OverlayView: UIView {
    var drawer: ((CGContext, CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        if let g = UIGraphicsGetCurrentContext() { drawer?(g, rect) }
    }
}

/// Where a page sits in the scrolled content (content units are page points at zoom 1).
struct Slot {
    var frame: CGRect     // the part of the content the page occupies
    var origin: CGPoint   // where the page's own (0, 0) is
    var region: Box       // the same frame in page points: the whole page, or a board's working area
}

/// A page's raster: the visible window of it, at the pixel density it is shown at.
final class Raster {
    let layer = CALayer()
    var window = Box(0, 0, 0, 0)   // page points it covers
    var pageRect = CGRect.zero     // exactly what the bitmap covers, in page points
    var scale: CGFloat = 0         // pixels per page point
    var ctx: CGContext?            // draws in page points
    var bg: CGImage?               // a PDF page's background alone, so that erasing does not render the PDF again
    var pending: (window: Box, scale: CGFloat)?
    var request = 0
    var dirtySince: Box?           // what was painted since the last render was asked for
    var stale = false
}

private struct RenderJob {
    let snap: PageSnap
    let origin: CGPoint
    let window: Box
    let scale: CGFloat
    let hidden: Set<ObjectIdentifier>
}

private struct RenderOut {
    let ctx: CGContext
    let bg: CGImage?
    let pageRect: CGRect
    let frame: CGRect   // in content units
}

final class CanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIEditMenuInteractionDelegate {
    static let maxPixels = 12_000_000.0   // pages bigger than this on screen are cached as a window around the viewport
    static var clip: [Item] = []          // copied items, shared by every open notebook

    let scroll = UIScrollView()
    let content = UIView()
    let overlay = OverlayView()
    let tools: ToolState
    private(set) var doc: Document
    private var listener: UUID?

    var slots: [Slot] = []
    private var backs: [CALayer] = []
    var rasters: [ObjectIdentifier: Raster] = [:]
    private let renderQueue = DispatchQueue(label: "inkpad.render", qos: .userInitiated)
    var lifted = Set<ObjectIdentifier>()   // items lifted off the page while a selection is dragged
    private var zoomed = false
    private var lastSize = CGSize.zero
    private var lastPage = -1
    private var lastPercent = -1
    private var slotW: CGFloat = 0          // side by side: the width each page has to itself
    private var homeZoom: CGFloat = 1       // side by side: the zoom at which one page fills the view
    private var dragStart = CGPoint.zero
    private var dragBase: CGFloat = 0      // side by side: where the view would be if the finger had not moved
    private var dragPage = 0               // the page the drag began on
    private var edgeOver: CGFloat = 0      // how far the finger has pulled a zoomed page past its edge
    private var adjusting = false
    private var pinched = false            // the fingers on the screen have zoomed: what they do is no page turn
    let pageBar = CALayer()                // side by side: the lower scrollbar, for the page in view only
    var pull: CGFloat = 0                   // how far the view is pushed past an end, side by side
    static let pullToAdd: CGFloat = 90
    var onPullAdd: ((Int) -> Void)?

    /// Pages side by side, one at a time (never for a whiteboard).
    var across: Bool { tools.p.paging == "horizontal" && !doc.pages.contains { $0.board } }

    func setPaging() {
        let i = currentPageIndex()
        zoomed = false
        relayout()
        scrollToPage(min(i, slots.count - 1), animated: false)
        applyInputSettings()
    }

    // Tool state; the logic is in CanvasTools.swift.
    var op: Op?
    var sel: Selection?
    var holdTimer: Timer?
    var previousTool = "pen"
    let moveLayer = CALayer()
    let selBar = SelectionBar()
    var strokeGesture: StrokeGesture!
    var tapGesture: UITapGestureRecognizer!
    var pressGesture: UILongPressGestureRecognizer!
    lazy var editMenu = UIEditMenuInteraction(delegate: self)
    var menuAt = CGPoint.zero      // where the long press that asked for a menu was
    var grabReach = 7.0            // how near the selection's edge counts as on it: more for a finger
    var strokeStart: TimeInterval = 0
    var marks: [(Int, Box)] = []   // search hits: (page index, box)
    var markAt = -1                // the hit the search is at
    var boardAt = 0                // which of a whiteboard document's boards is shown
    var memo: [Double]?            // a remembered view to open at: zoom, page, x and y as shares of the page
    var laserTrails: [(page: Page, pts: [Pt])] = []
    var laserDot: (page: Page, x: Double, y: Double)?
    var laserAlpha: CGFloat = 1
    var laserTimer: Timer?         // counts down to the fade, then drives it
    var ruler: RulerView?
    let minimap = MinimapView()
    let hoverLayer = CAShapeLayer()
    var mouseP = 0.45              // a mouse has no pressure: the line thins with speed instead
    var mouseLast = CGPoint.zero
    var penLast: TimeInterval = 0
    var forceFirst = 0.0           // the force a stroke began with, and whether it has changed since
    var forceVaries = false
    var forceCount = 0
    static var penForce = true     // the pencil in use tells how hard it is pressed
    var toolRing: PencilPalette?
    var hoverAt = CGPoint(x: CGFloat.nan, y: CGFloat.nan)   // where the pencil was last seen above the page
    static var hasPen = false      // a pencil has been used since the app started

    var initialPage = 0            // the page to show when the notebook first appears
    var onPage: ((Int) -> Void)?
    var onZoom: ((Int) -> Void)?
    var onToast: ((String) -> Void)?
    var onSelection: (() -> Void)?
    var onSaveImage: ((UIImage) -> Void)?

    init(doc: Document, tools: ToolState) {
        self.doc = doc
        self.tools = tools
        super.init(frame: .zero)
        backgroundColor = Theme.canvasUI
        clipsToBounds = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.bouncesZoom = false   // stop at the limit rather than overshoot and spring back
        scroll.alwaysBounceVertical = true
        scroll.backgroundColor = .clear
        scroll.accessibilityIdentifier = "canvas"
        addSubview(scroll)
        scroll.addSubview(content)
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.drawer = { [weak self] g, rect in self?.drawOverlay(g, rect) }
        addSubview(overlay)
        moveLayer.anchorPoint = .zero
        moveLayer.isHidden = true
        overlay.layer.addSublayer(moveLayer)
        selBar.isHidden = true
        addSubview(selBar)
        minimap.canvas = self
        minimap.isHidden = true
        addSubview(minimap)
        hoverLayer.isHidden = true
        hoverLayer.actions = ["position": NSNull(), "path": NSNull(), "hidden": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer.addSublayer(hoverLayer)
        pageBar.backgroundColor = UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 0.75).cgColor
        pageBar.cornerRadius = 2.5
        pageBar.isHidden = true
        pageBar.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer.addSublayer(pageBar)
        setUpInput()
        listener = doc.listen { [weak self] in self?.docEvent($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let listener { doc.listeners[listener] = nil }
    }

    /// Show another document (the same notebook, loaded again after a sync changed it).
    func setDocument(_ new: Document) {
        cancelOp()
        clearSelection()
        clearLaser()
        marks = []
        markAt = -1
        if let listener { doc.listeners[listener] = nil }
        doc = new
        listener = new.listen { [weak self] in self?.docEvent($0) }
        dropRasters()
        relayout()
    }

    private var pixelScale: CGFloat { (window?.screen.scale ?? UIScreen.main.scale) }
    var zoom: Double { Double(scroll.zoomScale) }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastSize else { return }
        lastSize = bounds.size
        regainScrolling()   // the window was resized, perhaps after being moved
        placeMinimap()
        ruler?.resize()
        if slots.isEmpty || across {
            let i = slots.isEmpty ? -1 : currentPageIndex()
            relayout()
            if i >= 0 { scrollToPage(min(i, slots.count - 1), animated: false) }
        } else {
            let anchor = anchorNow()
            updateZoomLimits()
            centerContent()
            if let anchor { restore(anchor) }
            updateVisible()
            refreshOverlay()
        }
    }

    private func dropRasters() {
        for r in rasters.values { r.layer.removeFromSuperlayer() }
        rasters = [:]
    }

    func index(of page: Page) -> Int? { doc.pages.firstIndex { $0 === page } }

    func relayout() {
        guard bounds.width > 0 else { return }
        boardAt = max(0, min(doc.pages.count - 1, boardAt))
        let anchor = zoomed ? anchorNow() : nil
        let regions = doc.pages.map { $0.board ? $0.box.padded(1500) : Box(0, 0, $0.w, $0.h) }
        let margin = 20.0, gap = 14.0
        var width = (regions.map(\.w).max() ?? 595) + 2 * margin
        var height = 0.0
        if across {
            // One page at a time: each has a slot as wide as the window at the "home" zoom.
            let ws = regions.map(\.w).sorted(), hs = regions.map(\.h).sorted()
            let rw = ws[ws.count / 2], rh = hs[hs.count / 2]
            homeZoom = max(0.05, min((bounds.width - 48) / rw, (bounds.height - Self.topInset - Self.bottomInset - 16) / rh, 1.35))
            slotW = max(bounds.width / homeZoom, (ws.last ?? rw) + 48)
            height = (hs.last ?? rh)
            width = slotW * Double(regions.count)
            slots = regions.enumerated().map { i, r in
                let frame = CGRect(x: slotW * Double(i) + (slotW - r.w) / 2, y: (height - r.h) / 2, width: r.w, height: r.h)
                return Slot(frame: frame, origin: CGPoint(x: frame.minX - r.x0, y: frame.minY - r.y0), region: r)
            }
        } else if isBoard {
            // One board at a time: it has the whole view, and the others wait out of sight.
            let away = CGPoint(x: -1e7, y: -1e7)
            width = regions[boardAt].w + 2 * margin
            height = regions[boardAt].h + 16
            slots = regions.enumerated().map { i, r in
                guard i == boardAt else { return Slot(frame: CGRect(origin: away, size: .zero), origin: away, region: r) }
                let frame = CGRect(x: margin, y: 8, width: r.w, height: r.h)
                return Slot(frame: frame, origin: CGPoint(x: frame.minX - r.x0, y: frame.minY - r.y0), region: r)
            }
        } else {
            var y = 8.0
            slots = regions.map { r in
                let frame = CGRect(x: (width - r.w) / 2, y: y, width: r.w, height: r.h)
                y += r.h + gap
                return Slot(frame: frame, origin: CGPoint(x: frame.minX - r.x0, y: frame.minY - r.y0), region: r)
            }
            height = y - gap + 8
        }
        scroll.alwaysBounceHorizontal = across
        scroll.alwaysBounceVertical = !across
        scroll.decelerationRate = across ? .fast : .normal
        let z = scroll.zoomScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        content.center = CGPoint(x: width * z / 2, y: height * z / 2)
        scroll.contentSize = CGSize(width: width * z, height: height * z)
        for layer in backs { layer.removeFromSuperlayer() }
        backs = zip(doc.pages, slots).map { page, slot in
            let layer = CALayer()
            layer.frame = slot.frame
            layer.backgroundColor = (page.pdf == nil ? page.color : RGB.white).cg()
            if !page.board {
                layer.shadowColor = UIColor.black.cgColor
                layer.shadowOpacity = 0.16
                layer.shadowRadius = 2.5
                layer.shadowOffset = CGSize(width: 0, height: 1)
                layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
            }
            content.layer.insertSublayer(layer, at: 0)
            return layer
        }
        // Rasters of pages that are still here move with their page and are rendered again.
        let alive = Dictionary(uniqueKeysWithValues: zip(doc.pages, slots).map { (ObjectIdentifier($0.0), $0.1) })
        for (key, r) in rasters {
            if let slot = alive[key] {
                r.layer.frame = r.pageRect.offsetBy(dx: slot.origin.x, dy: slot.origin.y)
                r.stale = true
                r.request += 1
                r.pending = nil
            } else {
                r.layer.removeFromSuperlayer()
                rasters[key] = nil
            }
        }
        CATransaction.commit()
        updateZoomLimits()
        centerContent()
        if let anchor { restore(anchor) }
        updateVisible()
        refreshOverlay()
        notePage()
        minimap.isHidden = !isBoard
        if isBoard { minimap.contentChanged() }
    }

    var isBoard: Bool { doc.pages.first?.board ?? false }

    func updateZoomLimits() {
        guard let first = slots.first, content.bounds.width > 0 else { return }
        let fit = across ? homeZoom : bounds.width / content.bounds.width
        if isBoard {
            scroll.minimumZoomScale = min(fit, bounds.height / content.bounds.height, 1) * 0.8
        } else {
            scroll.minimumZoomScale = across ? homeZoom : min(fit, bounds.height / (first.frame.height + 40), 1) * 0.5
        }
        // The limit from the settings, counted as on the desktop: 100% is one point per point.
        scroll.maximumZoomScale = max(2, CGFloat(tools.p.maxZoom))
        if zoomed && scroll.zoomScale > scroll.maximumZoomScale { scroll.zoomScale = scroll.maximumZoomScale }
        if !zoomed {
            zoomed = true
            if applyMemo() {
            } else if isBoard {
                // A board opens at its natural size, or smaller when that shows all of it.
                let box = doc.pages[boardAt].box
                let z = min(bounds.width / box.w, bounds.height / box.h) * 0.9
                scroll.zoomScale = max(scroll.minimumZoomScale, min(1, z))
                centerContent()
                center(at: boardAt, (box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2)
            } else {
                // Fitted to the width, but not blown up past a comfortable size on a wide screen.
                scroll.zoomScale = max(scroll.minimumZoomScale, min(scroll.maximumZoomScale, fit, 1.35))
                centerContent()
                scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
                if initialPage > 0 { scrollToPage(min(initialPage, slots.count - 1), animated: false) }
            }
        } else if scroll.zoomScale < scroll.minimumZoomScale {
            scroll.zoomScale = scroll.minimumZoomScale
        }
    }

    /// Content smaller than the view sits in the middle of it.
    func centerContent() {
        let size = scroll.contentSize
        // Room at the top for the floating bars and at the bottom for the status pill, as
        // the desktop leaves; what is still smaller than the view is centred in the rest.
        let ix = max(0, (bounds.width - size.width) / 2)
        let iy = max(0, (bounds.height - Self.topInset - Self.bottomInset - size.height) / 2)
        let inset = UIEdgeInsets(top: iy + Self.topInset, left: ix, bottom: iy + Self.bottomInset, right: ix)
        if scroll.contentInset != inset { scroll.contentInset = inset }
    }

    static let topInset: CGFloat = 58
    static let bottomInset: CGFloat = 40

    func anchorNow() -> (Page, Double, Double)? {
        guard !slots.isEmpty else { return nil }
        let c = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: content)
        let i = pageIndex(nearest: c)
        guard doc.pages.indices.contains(i) else { return nil }
        return (doc.pages[i], Double(c.x - slots[i].origin.x), Double(c.y - slots[i].origin.y))
    }

    func restore(_ anchor: (Page, Double, Double)) {
        guard let i = index(of: anchor.0), slots.indices.contains(i) else { return }
        center(at: i, anchor.1, anchor.2)
    }

    func clamped(_ offset: CGPoint) -> CGPoint {
        let inset = scroll.contentInset, size = scroll.contentSize
        let maxX = max(-inset.left, size.width - bounds.width + inset.right)
        let maxY = max(-inset.top, size.height - bounds.height + inset.bottom)
        return CGPoint(x: min(max(offset.x, -inset.left), maxX), y: min(max(offset.y, -inset.top), maxY))
    }

    /// Put a point of a page in the middle of the view.
    func center(at i: Int, _ px: Double, _ py: Double, animated: Bool = false) {
        guard slots.indices.contains(i) else { return }
        let z = scroll.zoomScale
        let c = CGPoint(x: (slots[i].origin.x + px) * z, y: (slots[i].origin.y + py) * z)
        scroll.setContentOffset(clamped(CGPoint(x: c.x - bounds.width / 2, y: c.y - bounds.height / 2)), animated: animated)
    }

    func scrollToPage(_ i: Int, animated: Bool = true) {
        guard slots.indices.contains(i) else { return }
        if isBoard {
            if i != boardAt {
                cancelOp()
                clearSelection()
                boardAt = i
                zoomed = false
                relayout()
            }
            return
        }
        let z = scroll.zoomScale
        let frame = slots[i].frame
        if across {
            let x = span(i).lo   // the page's near edge when it is zoomed in past the window
            let y = scroll.zoomScale <= homeZoom * 1.01 ? -scroll.contentInset.top : scroll.contentOffset.y
            scroll.setContentOffset(clamped(CGPoint(x: x, y: y)), animated: animated)
            return
        }
        let x = scroll.contentSize.width <= bounds.width ? scroll.contentOffset.x : (frame.midX * z - bounds.width / 2)
        scroll.setContentOffset(clamped(CGPoint(x: x, y: frame.minY * z - scroll.contentInset.top)), animated: animated)
    }

    func fitWidth() {
        guard content.bounds.width > 0 else { return }
        let anchor = anchorNow()
        scroll.setZoomScale(max(scroll.minimumZoomScale, bounds.width / content.bounds.width), animated: false)
        centerContent()
        if let anchor { restore(anchor) }
        updateVisible()
        notePage()
    }

    private func pageIndex(nearest c: CGPoint) -> Int {
        if isBoard { return boardAt }
        if across && slotW > 0 { return max(0, min(slots.count - 1, Int(c.x / slotW))) }
        var best = 0
        var dist = CGFloat.infinity
        for (i, slot) in slots.enumerated() {
            let d = c.y < slot.frame.minY ? slot.frame.minY - c.y : c.y > slot.frame.maxY ? c.y - slot.frame.maxY : 0
            if d < dist {
                dist = d
                best = i
            }
        }
        return best
    }

    func currentPageIndex() -> Int {
        guard !slots.isEmpty else { return 0 }
        return pageIndex(nearest: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: content))
    }

    private func notePage() {
        let i = currentPageIndex()
        if i != lastPage {
            lastPage = i
            onPage?(i)
        }
        let percent = Int((zoom * 100).rounded())
        if percent != lastPercent {
            lastPercent = percent
            onZoom?(percent)
        }
    }

    func zoomBy(_ factor: CGFloat) { setZoom(scroll.zoomScale * factor) }

    func setZoom(_ z: CGFloat) {
        let anchor = anchorNow()
        scroll.zoomScale = min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, z))
        centerContent()
        if let anchor { restore(anchor) }
        settleAcross(animated: false)
        updateVisible()
        refreshOverlay()
        notePage()
    }

    // MARK: side by side

    static let side: CGFloat = 20   // the margin kept beside a page that is zoomed in

    /// Side by side: the scroll positions between which page i fills the window. They are one
    /// and the same when the whole page fits.
    func span(_ i: Int) -> (lo: CGFloat, hi: CGFloat) {
        let z = scroll.zoomScale, frame = slots[i].frame
        let extent = frame.width * z + 2 * Self.side
        if extent <= bounds.width + 1 {
            let x = frame.midX * z - bounds.width / 2
            return (x, x)
        }
        let lo = frame.minX * z - Self.side
        return (lo, lo + extent - bounds.width)
    }

    /// Zoomed in, the view belongs to one page and never rests across two.
    func settleAcross(animated: Bool) {
        guard across, !slots.isEmpty, !scroll.isTracking else { return }
        let i = currentPageIndex()
        let (lo, hi) = span(i)
        let x = scroll.contentOffset.x
        if x < lo - 0.5 || x > hi + 0.5 {
            scroll.setContentOffset(CGPoint(x: max(lo, min(hi, x)), y: scroll.contentOffset.y), animated: animated)
        }
        placePageBar()
    }

    /// The lower scrollbar covers the page in view only, and shows when that page is wider
    /// than the window.
    func placePageBar() {
        guard across, tools.p.scrollbars, !slots.isEmpty else {
            pageBar.isHidden = true
            return
        }
        let i = currentPageIndex()
        let (lo, hi) = span(i)
        guard hi > lo + 1 else {
            pageBar.isHidden = true
            return
        }
        let view = bounds.width, extent = hi - lo + view
        let track = view - 16
        let handle = max(40, track * view / extent)
        let at = 8 + (track - handle) * max(0, min(1, (scroll.contentOffset.x - lo) / (hi - lo)))
        pageBar.frame = CGRect(x: at, y: bounds.height - 9, width: handle, height: 5)
        pageBar.isHidden = false
    }

    // MARK: coordinates

    /// Page points to view points, for page i.
    func pageToView(_ i: Int) -> CGAffineTransform {
        let o = content.convert(CGPoint.zero, to: self)
        let z = scroll.zoomScale
        return CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: o.x + slots[i].origin.x * z, ty: o.y + slots[i].origin.y * z)
    }

    func toPage(_ i: Int, _ v: CGPoint) -> (Double, Double) {
        let c = convert(v, to: content)
        return (Double(c.x - slots[i].origin.x), Double(c.y - slots[i].origin.y))
    }

    /// The page under a view point and the point on it, or nil off the paper.
    func locate(_ v: CGPoint) -> (Int, Double, Double)? {
        let c = convert(v, to: content)
        guard let i = slots.firstIndex(where: { $0.frame.contains(c) }) else { return nil }
        return (i, Double(c.x - slots[i].origin.x), Double(c.y - slots[i].origin.y))
    }

    func viewRect(_ i: Int, _ box: Box) -> CGRect { box.rect.applying(pageToView(i)) }

    // MARK: scrolling and zooming

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStart = scrollView.contentOffset
        dragBase = scrollView.contentOffset.x + scrollView.panGestureRecognizer.translation(in: self).x
        dragPage = slots.isEmpty ? 0 : currentPageIndex()
        edgeOver = 0
        let pinch = scrollView.pinchGestureRecognizer?.state
        pinched = scrollView.isZooming || pinch == .began || pinch == .changed
        hidePalette()
    }

    /// Whether the drag began on a page that is zoomed in past the window.
    private var insidePage: Bool {
        guard across, slots.indices.contains(dragPage) else { return false }
        let s = span(dragPage)
        return s.hi > s.lo + 1
    }

    /// Side by side, a drag comes to rest on one whole page: the next one when it went far
    /// or fast enough. Inside a page that is zoomed in the view stops at the page's edge;
    /// pulled far enough past it, the page turns.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard across, slots.indices.contains(dragPage) else { return }
        if pinched || scrollView.isZooming {
            // Zooming moves the view too, and none of that is a pull at the page: it stays with
            // the page that is in the middle of the window.
            pinched = false
            edgeOver = 0
            targetContentOffset.pointee = scrollView.contentOffset
            DispatchQueue.main.async { [weak self] in self?.settleAcross(animated: true) }
            return
        }
        let i = dragPage
        let (lo, hi) = span(i)
        if hi > lo + 1 {
            let over = edgeOver
            edgeOver = 0
            if over == 0 {
                targetContentOffset.pointee.x = max(lo, min(hi, targetContentOffset.pointee.x))
                return
            }
            // Let go past the edge of a zoomed page: far enough turns it, less springs back.
            let j = i + (over > 0 ? 1 : -1)
            var x = over > 0 ? hi : lo
            if abs(over) > max(110, 0.22 * bounds.width), slots.indices.contains(j) {
                x = j > i ? span(j).lo : span(j).hi
            }
            targetContentOffset.pointee = scrollView.contentOffset
            let y = scrollView.contentOffset.y
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.scroll.isTracking else { return }
                self.scroll.setContentOffset(CGPoint(x: x, y: y), animated: true)
            }
            return
        }
        guard !scrollView.isZooming else { return }
        let moved = scrollView.contentOffset.x - dragStart.x
        var to = i
        if abs(moved) > 0.18 * bounds.width || (abs(velocity.x) > 0.4 && velocity.x * moved > 0) { to += moved > 0 ? 1 : -1 }
        to = max(0, min(slots.count - 1, to))
        targetContentOffset.pointee.x = span(to).lo
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // The pull was let go: far enough makes a page, otherwise it just springs back.
        let was = pull
        pull = 0
        if was != 0 { refreshOverlay() }
        if abs(was) >= Self.pullToAdd { onPullAdd?(was > 0 ? 1 : -1) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if across && !adjusting && !pinched && !scrollView.isZooming && (scrollView.isTracking || scrollView.isDecelerating) && insidePage {
            // Zoomed in, a finger moves about inside its page. Past the edge the page gives only
            // a little: it takes a long, deliberate pull to turn to the next one.
            let (lo, hi) = span(dragPage)
            var x = scrollView.contentOffset.x
            if scrollView.isTracking && scrollView.panGestureRecognizer.numberOfTouches > 0 {
                let want = dragBase - scrollView.panGestureRecognizer.translation(in: self).x
                edgeOver = want > hi ? want - hi : want < lo ? want - lo : 0
                x = max(lo, min(hi, want)) + 0.4 * edgeOver
            } else if scrollView.isDecelerating {
                x = max(lo, min(hi, x))   // gliding stops at the page's edge
            }
            if abs(x - scrollView.contentOffset.x) > 0.01 {
                adjusting = true
                scrollView.contentOffset.x = x
                adjusting = false
            }
        } else if across && scrollView.isDragging && !pinched && !insidePage {
            let x = scrollView.contentOffset.x
            let maxX = scrollView.contentSize.width - bounds.width + scrollView.contentInset.right
            let over = x > maxX ? x - maxX : x < -scrollView.contentInset.left ? x + scrollView.contentInset.left : 0
            if over != pull {
                pull = over
                refreshOverlay()
            }
        }
        updateVisible()
        notePage()
        viewMoved()
        placePageBar()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        pinched = true
        edgeOver = 0
        if pull != 0 {
            pull = 0
            refreshOverlay()
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateVisible()
        notePage()
        viewMoved()
        ruler?.setNeedsDisplay()   // its scale is the page's own
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if !scrollView.isDragging { pinched = false }
        settleAcross(animated: true)
        updateVisible()
        refreshOverlay()
    }

    func refreshOverlay() {
        overlay.setNeedsDisplay()
        placeSelBar()
    }

    // MARK: rasters

    /// Make sure every page in view has a raster that covers what is seen of it, at the
    /// current zoom, and let go of the ones far away.
    func updateVisible() {
        guard !slots.isEmpty, bounds.width > 0, slots.count == doc.pages.count else { return }
        let s = scroll.zoomScale * pixelScale
        let vis = convert(bounds, to: content)
        let near = vis.insetBy(dx: -vis.width * 0.25, dy: -vis.height * 0.6)
        let zooming = scroll.isZooming || scroll.isZoomBouncing
        var keep = Set<ObjectIdentifier>()
        for (i, slot) in slots.enumerated() where slot.frame.intersects(near) {
            let page = doc.pages[i]
            let key = ObjectIdentifier(page)
            keep.insert(key)
            func toPage(_ r: CGRect) -> Box {
                Box(Double(r.minX - slot.origin.x), Double(r.minY - slot.origin.y), Double(r.maxX - slot.origin.x), Double(r.maxY - slot.origin.y))
            }
            let seen = vis.intersection(slot.frame)
            var window = slot.region
            if Double(slot.frame.width * s * slot.frame.height * s) > Self.maxPixels {
                // Too big to keep whole: what is seen, and as much around it as the budget allows.
                var r = seen.isNull ? near.intersection(slot.frame) : seen
                let budget = Self.maxPixels / Double(s * s)
                let grow = min(0.6, max(0, (sqrt(budget / max(1, Double(r.width * r.height))) - 1) / 2))
                r = r.insetBy(dx: -r.width * grow, dy: -r.height * grow).intersection(slot.frame)
                window = toPage(r)
            }
            let need = seen.isNull || seen.isEmpty ? nil : toPage(seen.insetBy(dx: 0.5, dy: 0.5))
            let r = rasters[key] ?? {
                let made = Raster()
                made.layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
                made.layer.zPosition = 1
                content.layer.addSublayer(made.layer)
                rasters[key] = made
                return made
            }()
            func covers(_ w: Box) -> Bool {
                guard let need else { return true }
                return w.x0 <= need.x0 && w.y0 <= need.y0 && w.x1 >= need.x1 && w.y1 >= need.y1
            }
            let good = r.ctx != nil && !r.stale && covers(r.window) && (zooming || abs(r.scale - s) < 0.001)
            if good { continue }
            if let p = r.pending, covers(p.window), zooming || abs(p.scale - s) < 0.001 { continue }
            render(page, slot, r, window, s)
        }
        for (key, r) in rasters where !keep.contains(key) {
            r.layer.removeFromSuperlayer()
            rasters[key] = nil
        }
    }

    private func render(_ page: Page, _ slot: Slot, _ r: Raster, _ window: Box, _ s: CGFloat) {
        r.request += 1
        r.pending = (window, s)
        r.dirtySince = nil
        let id = r.request
        let key = ObjectIdentifier(page)
        let job = RenderJob(snap: page.snap, origin: slot.origin, window: window, scale: s, hidden: lifted)
        renderQueue.async { [weak self] in
            let out = Self.rasterise(job)
            DispatchQueue.main.async {
                guard let self, let r = self.rasters[key], r.request == id else { return }
                r.pending = nil
                guard let out else { return }
                r.ctx = out.ctx
                r.bg = out.bg
                r.window = window
                r.pageRect = out.pageRect
                r.scale = s
                r.stale = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // The page may have moved (a board that grew) while this was being drawn.
                let origin = self.index(of: page).map { self.slots[$0].origin } ?? job.origin
                r.layer.frame = out.pageRect.offsetBy(dx: origin.x, dy: origin.y)
                if let dirty = r.dirtySince {
                    // Edits made meanwhile are not in this picture yet.
                    r.dirtySince = nil
                    self.repaint(page, dirty)
                } else {
                    r.layer.contents = out.ctx.makeImage()
                }
                CATransaction.commit()
            }
        }
    }

    private static func rasterise(_ job: RenderJob) -> RenderOut? {
        let s = Double(job.scale), ox = Double(job.origin.x), oy = Double(job.origin.y)
        // Pixels are counted from the content's origin, so that rasters land on the screen's pixel grid.
        let x0 = Int(floor((ox + job.window.x0) * s)), y0 = Int(floor((oy + job.window.y0) * s))
        let x1 = Int(ceil((ox + job.window.x1) * s)), y1 = Int(ceil((oy + job.window.y1) * s))
        let w = max(1, x1 - x0), h = max(1, y1 - y0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
        ctx.scaleBy(x: job.scale, y: job.scale)
        ctx.translateBy(x: job.origin.x, y: job.origin.y)
        let snap = job.snap
        renderBackground(ctx, snap, job.window)
        let bg = snap.pdf != nil ? ctx.makeImage() : nil
        ctx.saveGState()
        if !snap.board { ctx.clip(to: CGRect(x: 0, y: 0, width: snap.w, height: snap.h)) }
        renderItems(ctx, snap, job.window, hidden: job.hidden)
        ctx.restoreGState()
        let frame = CGRect(x: Double(x0) / s, y: Double(y0) / s, width: Double(w) / s, height: Double(h) / s)
        return RenderOut(ctx: ctx, bg: bg, pageRect: frame.offsetBy(dx: -job.origin.x, dy: -job.origin.y), frame: frame)
    }

    /// Draw newly added items on top of what the page's raster already shows.
    private func paintAdded(_ page: Page, _ items: [Item]) {
        guard let r = rasters[ObjectIdentifier(page)] else { return }
        var box: Box?
        for it in items { box = union(box, it.bbox) }
        r.dirtySince = union(r.dirtySince, box)
        guard let ctx = r.ctx else { return }
        ctx.saveGState()
        if !page.board { ctx.clip(to: CGRect(x: 0, y: 0, width: page.w, height: page.h)) }
        let env = DrawEnv(onDark: page.onDark)
        for it in items where it.bbox.intersects(r.window) { it.draw(ctx, env) }
        ctx.restoreGState()
        setContents(r, ctx)
    }

    private func setContents(_ r: Raster, _ ctx: CGContext) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        r.layer.contents = ctx.makeImage()
        CATransaction.commit()
    }

    /// Draw one area of a page again: background, then every item that reaches into it.
    func repaint(_ page: Page, _ rect: Box?) {
        guard let r = rasters[ObjectIdentifier(page)] else { return }
        guard let ctx = r.ctx else {
            r.dirtySince = union(r.dirtySince, rect ?? r.window)
            return
        }
        let wanted = (rect ?? r.window).padded(1)
        let area = Box(max(wanted.x0, r.window.x0 - 1), max(wanted.y0, r.window.y0 - 1), min(wanted.x1, r.window.x1 + 1), min(wanted.y1, r.window.y1 + 1))
        r.dirtySince = union(r.dirtySince, wanted)
        guard area.x1 > area.x0, area.y1 > area.y0 else { return }
        let snap = page.snap
        ctx.saveGState()
        ctx.clip(to: area.rect)
        if let bg = r.bg {
            UIGraphicsPushContext(ctx)
            ctx.interpolationQuality = .none
            UIImage(cgImage: bg).draw(in: r.pageRect, blendMode: .copy, alpha: 1)
            UIGraphicsPopContext()
        } else {
            renderBackground(ctx, snap, area)
        }
        if !snap.board { ctx.clip(to: CGRect(x: 0, y: 0, width: snap.w, height: snap.h)) }
        renderItems(ctx, snap, area, hidden: lifted)
        ctx.restoreGState()
        setContents(r, ctx)
    }

    // MARK: document events

    private func docEvent(_ event: DocEvent) {
        if isBoard { minimap.contentChanged() }
        switch event {
        case .added(let page, let items):
            paintAdded(page, items)
            growBoard(page)
        case .dirty(let page, let rect):
            if rect == nil {
                if let r = rasters[ObjectIdentifier(page)] {
                    r.stale = true
                    r.request += 1
                    r.pending = nil
                }
                updateVisible()
            } else {
                repaint(page, rect)
            }
            growBoard(page)
        case .pages:
            cancelOp()
            clearSelection()
            relayout()
        default:
            break
        }
    }

    /// A board's working area follows its content: writing near the edge makes room.
    private func growBoard(_ page: Page) {
        guard page.board, let i = index(of: page), slots.indices.contains(i) else { return }
        let box = page.box, region = slots[i].region.padded(-500)
        if box.x0 < region.x0 || box.y0 < region.y0 || box.x1 > region.x1 || box.y1 > region.y1 { relayout() }
    }

    func undo() {
        cancelOp()
        clearSelection()
        doc.undo()
    }

    func redo() {
        cancelOp()
        clearSelection()
        doc.redo()
    }

    // MARK: search marks

    func setMarks(_ found: [(Int, Box)], current: Int) {
        marks = found
        markAt = found.indices.contains(current) ? current : -1
        if found.indices.contains(current) {
            let (i, box) = found[current]
            if isBoard || across { scrollToPage(i, animated: false) }
            center(at: i, (box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2, animated: !across)
        }
        refreshOverlay()
    }
}
