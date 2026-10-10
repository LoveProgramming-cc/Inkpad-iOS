import UIKit
import PDFKit

let paperSizes: [(String, (Double, Double))] = [("A4", (595.0, 842.0)), ("A5", (420.0, 595.0)), ("A3", (842.0, 1191.0)),
                                                ("B5", (499.0, 709.0)), ("Letter", (612.0, 792.0))]
let paperColors: [(String, RGB)] = [("白色纸张", RGB(1.0, 1.0, 1.0)), ("黄色纸张", RGB(0.976, 0.965, 0.902)),
                                    ("深色纸张", RGB(0.13, 0.13, 0.15))]
let paperKinds: [(String, [(String, String)])] = [
    ("基本样式", [("blank", "空白"), ("dots", "点阵纸"), ("ruled", "窄行距"), ("wide", "宽行距"), ("grid", "方格纸")]),
    ("书写用纸", [("cornell", "康奈尔"), ("legal", "拍纸簿"), ("col2", "双栏"), ("col3", "三栏")]),
    ("日程与计划", [("todo", "待办清单"), ("weekly", "周计划")]),
    ("音乐与棋类", [("staff", "五线谱"), ("go", "围棋棋谱")]),
]
let boardPaperKinds: [(String, String)] = [("blank", "空白"), ("dots", "点阵纸"), ("ruled", "窄行距"), ("wide", "宽行距"), ("grid", "方格纸")]

/// A whiteboard has no edges at all: its items may lie anywhere, at negative coordinates
/// too, and the canvas shows whatever part is looked at. The size is only nominal; it
/// gives a new board's first strokes coordinates of a comfortable magnitude.
let boardSize = (1e8, 1e8)

struct PageTemplate: Equatable {
    var w = 595.0
    var h = 842.0
    var paper = "blank"
    var color = RGB.white
    var board = false

    var json: [String: Any] { ["w": w, "h": h, "paper": paper, "color": color.list] }

    init(w: Double = 595, h: Double = 842, paper: String = "blank", color: RGB = .white, board: Bool = false) {
        self.w = w; self.h = h; self.paper = paper; self.color = color; self.board = board
    }

    init(json: [String: Any]) {
        self.init(w: num(json["w"], 595), h: num(json["h"], 842), paper: json["paper"] as? String ?? "blank",
                  color: RGB(json: json["color"], default: .white))
    }
}

/// An embedded PDF whose pages serve as backgrounds.
final class PdfDoc {
    let data: Data
    /// What two copies of the same PDF have in common. A notebook holds a PDF once however many
    /// times it was imported into it, or came into it with pages merged from another device.
    lazy var key = "\(data.count)/\(ZipWriter.crc(data))"
    let nPages: Int
    private let doc: PDFDocument
    private var sizes: [Int: (Double, Double)] = [:]
    /// PDFKit documents are not safe to draw from two threads at once.
    private static let lock = NSRecursiveLock()

    init(_ data: Data) throws {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { throw ZipError(tr("PDF 无法打开")) }
        self.data = data
        self.doc = doc
        nPages = doc.pageCount
    }

    func pageSize(_ index: Int) -> (Double, Double) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let size = sizes[index] { return size }
        guard let page = doc.page(at: index) else { return (595, 842) }
        let box = page.bounds(for: .cropBox)
        let turned = (page.rotation / 90) % 2 != 0
        let size = turned ? (Double(box.height), Double(box.width)) : (Double(box.width), Double(box.height))
        sizes[index] = size
        return size
    }

    /// Draw a page at the context's current transform, one unit per point, top left at the origin.
    func render(_ index: Int, _ g: CGContext) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let page = doc.page(at: index) else { return }
        let h = pageSize(index).1
        g.saveGState()
        g.translateBy(x: 0, y: h)
        g.scaleBy(x: 1, y: -1)
        page.draw(with: .cropBox, to: g)
        g.restoreGState()
    }

    /// Where text occurs on a page: boxes in points, measured from the top left.
    func find(_ index: Int, _ text: String) -> [Box] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let page = doc.page(at: index) else { return [] }
        let h = pageSize(index).1
        let crop = page.bounds(for: .cropBox)
        return doc.findString(text, withOptions: [.caseInsensitive]).compactMap { sel in
            guard sel.pages.first == page else { return nil }
            let r = sel.bounds(for: page)
            guard page.rotation % 360 == 0 else { return nil }
            return Box(Double(r.minX - crop.minX), h - Double(r.maxY - crop.minY), Double(r.maxX - crop.minX), h - Double(r.minY - crop.minY))
        }
    }
}

final class Page {
    var w: Double
    var h: Double
    var paper: String
    var color: RGB
    var id = newID()
    var rev = 0                 // counts changes to the items, so an unchanged page is not serialised again
    var gone = Set<String>()    // ids of items removed from this page, kept so that a sync can tell
    var blob: (rev: Int, data: Data)?
    var board: Bool             // a whiteboard: one very large page, shown and exported cropped to its content
    var pdf: PdfDoc?
    var pdfPage = 0
    var rot = 0                 // quarter turns applied to the PDF background
    var bookmark = false
    var outline: String?        // outline title, if the page is in the outline
    var items: [Item] = []
    var mt = 0.0                // when the settings above were last changed, for merging two versions
    var seen: String?           // ...and what they were when that was last looked at

    /// The page's settings: what is kept in document.json about it, apart from what is drawn on it.
    var sign: String {
        "\(w)/\(h)/\(paper)/\(color.list)/\(board)/\(pdf?.key ?? "-")/\(pdfPage)/\(rot)/\(bookmark)/\(outline ?? "")"
    }

    func takeSettings(of other: Page) {
        w = other.w; h = other.h; paper = other.paper; color = other.color; board = other.board
        pdf = other.pdf; pdfPage = other.pdfPage; rot = other.rot; bookmark = other.bookmark; outline = other.outline
        mt = other.mt
        seen = sign
    }

    init(_ w: Double = 595, _ h: Double = 842, paper: String = "blank", pdf: PdfDoc? = nil, pdfPage: Int = 0,
         color: RGB = .white, board: Bool = false) {
        self.w = w; self.h = h; self.paper = paper; self.pdf = pdf; self.pdfPage = pdfPage; self.color = color; self.board = board
    }

    convenience init(template t: PageTemplate) {
        if t.board {
            self.init(boardSize.0, boardSize.1, paper: t.paper, color: t.color, board: true)
        } else {
            self.init(t.w, t.h, paper: t.paper, color: t.color)
        }
    }

    var template: PageTemplate { PageTemplate(w: w, h: h, paper: paper, color: color, board: board) }

    func blankLike() -> Page { Page(w, h, paper: paper, color: color, board: board) }

    func clone() -> Page {
        let page = Page(w, h, paper: paper, pdf: pdf, pdfPage: pdfPage, color: color, board: board)
        page.rot = rot
        page.items = items.map { $0.transformed(1, 0, 0, 0, 0) }
        return page
    }

    /// A copy turned k quarter turns clockwise, content included.
    func rotated(_ k: Int) -> Page {
        let (nw, nh) = k % 2 != 0 ? (h, w) : (w, h)
        let page = Page(nw, nh, paper: paper, pdf: pdf, pdfPage: pdfPage, color: color, board: board)
        page.rot = (rot + k) % 4
        page.bookmark = bookmark
        page.outline = outline
        page.items = items.map { $0.rotated(k, w, h) }
        return page
    }

    /// The part of a page worth showing: all of it, or a whiteboard's content.
    var box: Box { Self.box(board: board, w: w, h: h, items: items) }

    static func box(board: Bool, w: Double, h: Double, items: [Item]) -> Box {
        if !board { return Box(0, 0, w, h) }
        var box: Box?
        for it in items { box = union(box, it.bbox) }
        guard let box else { return Box(w / 2 - 400, h / 2 - 300, w / 2 + 400, h / 2 + 300) }
        // Pad, and keep a sensible minimum size and shape.
        let cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2
        let bw = max(box.w + 80, 400), bh = max(box.h + 80, 300)
        return Box(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)
    }

    /// Whether ink is about to be drawn on dark paper.
    var onDark: Bool { pdf == nil && color.luma < 0.45 }

    /// What a renderer needs, safe to hand to another thread.
    var snap: PageSnap {
        PageSnap(w: w, h: h, paper: paper, color: color, board: board, pdf: pdf, pdfPage: pdfPage, rot: rot, items: items)
    }
}

struct PageSnap {
    let w: Double, h: Double
    let paper: String
    let color: RGB
    let board: Bool
    let pdf: PdfDoc?
    let pdfPage: Int
    let rot: Int
    let items: [Item]

    var box: Box { Page.box(board: board, w: w, h: h, items: items) }
    var onDark: Bool { pdf == nil && color.luma < 0.45 }
}

// MARK: paper

private func rule(_ c: RGB, strong: Bool = false) -> RGB {
    if (c.r + c.g + c.b) / 3 > 0.5 {
        let k = strong ? 0.72 : 1.0
        return RGB(c.r * 0.80 * k, c.g * 0.84 * k, c.b * 0.90 * k)
    }
    let lift = strong ? 0.38 : 0.2
    return RGB(min(1, c.r + lift), min(1, c.g + lift), min(1, c.b + lift))
}

private func hlines(_ g: CGContext, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ step: Double, top: Double? = nil) {
    var y = y0
    if let top, top > y0 { y = y0 + ceil((top - y0) / step) * step }
    while y <= y1 {
        g.move(to: CGPoint(x: x0, y: y))
        g.addLine(to: CGPoint(x: x1, y: y))
        y += step
    }
}

private func perPixel(_ g: CGContext) -> Double {
    let m = g.ctm
    let det = abs(m.a * m.d - m.b * m.c)
    return det > 0 ? Double(1 / sqrt(det)) : 1
}

/// A whiteboard's background over box. The board has no edges, so the pattern simply
/// continues wherever it is looked at, negative coordinates included.
private func boardPaper(_ g: CGContext, _ page: PageSnap, _ box: Box) {
    g.setFillColor(page.color.cg())
    g.fill(box.rect)
    let kind = page.paper
    if kind == "blank" { return }
    var pitch = ["dots": 20.0, "grid": 20.0, "wide": 32.0][kind] ?? 22.0
    // Seen from far away the pattern would be millions of marks closer together than a
    // pixel: thin the dots out, and leave rulings off altogether.
    let pp = perPixel(g)
    var scale = 1.0
    if pitch / pp < 6 {
        if kind != "dots" { return }
        scale = pow(2, ceil(log2(6 * pp / pitch)))
        pitch *= scale
    }
    g.saveGState()
    g.clip(to: box.rect)
    g.setLineCap(.butt)
    g.setStrokeColor(rule(page.color).cg())
    g.setFillColor(rule(page.color).cg())
    g.setLineWidth(0.5)
    let fx = floor(box.x0 / pitch) * pitch, fy = floor(box.y0 / pitch) * pitch
    if kind == "dots" {
        let size = 1.6 * scale
        var y = fy
        while y < box.y1 + 1 {
            var x = fx
            while x < box.x1 + 1 {
                g.addRect(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
                x += pitch
            }
            y += pitch
        }
        g.fillPath()
    } else {
        var y = fy
        while y < box.y1 + 1 {
            g.move(to: CGPoint(x: box.x0, y: y))
            g.addLine(to: CGPoint(x: box.x1, y: y))
            y += pitch
        }
        if kind == "grid" {
            var x = fx
            while x < box.x1 + 1 {
                g.move(to: CGPoint(x: x, y: box.y0))
                g.addLine(to: CGPoint(x: x, y: box.y1))
                x += pitch
            }
        }
        g.strokePath()
    }
    g.restoreGState()
}

/// Paint the paper; box limits the work to one area of the page.
func drawPaper(_ g: CGContext, _ page: PageSnap, _ area: Box? = nil) {
    if page.board {
        boardPaper(g, page, area ?? page.box)
        return
    }
    let w = page.w, h = page.h, kind = page.paper
    let a = area ?? Box(0, 0, w, h)
    let bx0 = max(0, a.x0), by0 = max(0, a.y0), bx1 = min(w, a.x1), by1 = min(h, a.y1)
    guard bx1 > bx0, by1 > by0 else { return }
    let clip = CGRect(x: bx0, y: by0, width: bx1 - bx0, height: by1 - by0)
    g.setFillColor(page.color.cg())
    g.fill(clip)
    if kind == "blank" { return }
    let pitch = 20.0
    g.saveGState()
    g.clip(to: clip)
    g.setLineCap(.butt)
    let soft = rule(page.color).cg(), strong = rule(page.color, strong: true).cg()
    g.setStrokeColor(soft)
    g.setFillColor(soft)
    g.setLineWidth(0.5)
    switch kind {
    case "dots":
        let size = 1.2
        var y = max(pitch, floor(by0 / pitch) * pitch)
        while y < by1 + 1 {
            var x = max(pitch, floor(bx0 / pitch) * pitch)
            while x < bx1 + 1 {
                g.addRect(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
                x += pitch
            }
            y += pitch
        }
        g.fillPath()
    case "grid":
        hlines(g, bx0, bx1, 20, by1, 20, top: by0)
        var x = max(20.0, floor(bx0 / 20) * 20)
        while x < bx1 + 1 {
            g.move(to: CGPoint(x: x, y: by0))
            g.addLine(to: CGPoint(x: x, y: by1))
            x += 20
        }
        g.strokePath()
    case "cornell":
        let top = h * 0.09, cue = w * 0.28, bottom = h * 0.80
        hlines(g, 0, w, top + 22, bottom - 4, 22)
        g.strokePath()
        g.setStrokeColor(strong)
        g.setLineWidth(0.9)
        hlines(g, 0, w, top, top, 1)
        hlines(g, 0, w, bottom, bottom, 1)
        g.move(to: CGPoint(x: cue, y: top))
        g.addLine(to: CGPoint(x: cue, y: bottom))
        g.strokePath()
    case "todo":
        var y = 92.0
        while y < h - 36 {
            g.addRect(CGRect(x: 36, y: y - 11, width: 10, height: 10))
            g.move(to: CGPoint(x: 56, y: y))
            g.addLine(to: CGPoint(x: w - 36, y: y))
            y += 28
        }
        g.strokePath()
        g.setStrokeColor(strong)
        g.setLineWidth(0.9)
        hlines(g, 36, w - 36, 60, 60, 1)
        g.strokePath()
    case "weekly":
        let m = 30.0, top = 56.0
        let cw = (w - 2 * m) / 2, ch = (h - top - m) / 4
        g.setStrokeColor(strong)
        g.setLineWidth(0.8)
        let ink = rule(page.color, strong: true).ui
        for (n, name) in ["周一", "周二", "周三", "周四", "周五", "周六", "周日", "备注"].enumerated() {
            let x = m + Double(n % 2) * cw, y = top + Double(n / 2) * ch
            g.stroke(CGRect(x: x, y: y, width: cw, height: ch))
            TextLayout.show(g, x + 6, y + 5, tr(name), 9, 0, ink)
        }
    case "staff":
        // Music manuscript: staves of five lines.
        g.setStrokeColor(strong)
        g.setLineWidth(0.6)
        let gap = 7.0, step = 7.0 * 4 + 38
        var y = 78.0
        while y + gap * 4 < h - 44 {
            for i in 0..<5 {
                g.move(to: CGPoint(x: 42, y: y + Double(i) * gap))
                g.addLine(to: CGPoint(x: w - 42, y: y + Double(i) * gap))
            }
            g.move(to: CGPoint(x: 42, y: y))
            g.addLine(to: CGPoint(x: 42, y: y + gap * 4))
            g.move(to: CGPoint(x: w - 42, y: y))
            g.addLine(to: CGPoint(x: w - 42, y: y + gap * 4))
            y += step
        }
        g.strokePath()
    case "go":
        // A 19 x 19 goban with star points, and lines underneath for commentary.
        let side = min(w - 80, (h - 130) * 0.74)
        let cell = side / 18
        let x0 = (w - side) / 2, y0 = 64.0
        g.setStrokeColor(strong)
        g.setFillColor(strong)
        g.setLineWidth(0.55)
        for i in 0..<19 {
            g.move(to: CGPoint(x: x0 + Double(i) * cell, y: y0))
            g.addLine(to: CGPoint(x: x0 + Double(i) * cell, y: y0 + side))
            g.move(to: CGPoint(x: x0, y: y0 + Double(i) * cell))
            g.addLine(to: CGPoint(x: x0 + side, y: y0 + Double(i) * cell))
        }
        g.strokePath()
        g.setLineWidth(1.3)
        g.stroke(CGRect(x: x0, y: y0, width: side, height: side))
        let r = max(1.3, cell * 0.11)
        for i in [3, 9, 15] {
            for j in [3, 9, 15] {
                g.fillEllipse(in: CGRect(x: x0 + Double(i) * cell - r, y: y0 + Double(j) * cell - r, width: 2 * r, height: 2 * r))
            }
        }
        g.setStrokeColor(soft)
        g.setLineWidth(0.5)
        hlines(g, x0, x0 + side, y0 + side + 34, h - 30, 22)
        g.strokePath()
    default:
        let wide = kind == "wide"
        let first = kind == "legal" ? 70.0 : 50.0
        hlines(g, bx0, bx1, first, min(h - 8, by1), wide ? 32 : 22, top: by0)
        g.strokePath()
        if kind == "legal" {
            g.setStrokeColor(RGB(0.86, 0.42, 0.42).cg())
            g.setLineWidth(0.7)
            for x in [w * 0.13, w * 0.13 + 3] {
                g.move(to: CGPoint(x: x, y: 0))
                g.addLine(to: CGPoint(x: x, y: h))
            }
            g.strokePath()
        } else if kind == "col2" || kind == "col3" {
            let n = kind == "col2" ? 2 : 3
            g.setStrokeColor(strong)
            g.setLineWidth(0.8)
            for i in 1..<n {
                g.move(to: CGPoint(x: w * Double(i) / Double(n), y: 36))
                g.addLine(to: CGPoint(x: w * Double(i) / Double(n), y: h - 24))
            }
            g.strokePath()
        }
    }
    g.restoreGState()
}

/// Draw the page's PDF background, honouring its rotation.
func renderPdfBackground(_ g: CGContext, _ page: PageSnap) {
    guard let pdf = page.pdf else { return }
    let (ow, oh) = pdf.pageSize(page.pdfPage)
    let k = page.rot % 4
    g.saveGState()
    switch k {
    case 1: g.translateBy(x: oh, y: 0)
    case 2: g.translateBy(x: ow, y: oh)
    case 3: g.translateBy(x: 0, y: ow)
    default: break
    }
    if k != 0 { g.rotate(by: CGFloat(k) * .pi / 2) }
    pdf.render(page.pdfPage, g)
    g.restoreGState()
}

/// The paper or PDF under the ink, limited to one area.
func renderBackground(_ g: CGContext, _ page: PageSnap, _ area: Box? = nil, printing: Bool = false) {
    if page.pdf == nil {
        drawPaper(g, page, area)
    } else {
        g.saveGState()
        if let area { g.clip(to: area.rect) }
        if !printing {
            g.setFillColor(RGB.white.cg())
            g.fill(CGRect(x: 0, y: 0, width: page.w, height: page.h))
        }
        renderPdfBackground(g, page)
        g.restoreGState()
    }
}

/// Draw the items that reach into an area (all of them without one).
func renderItems(_ g: CGContext, _ page: PageSnap, _ area: Box? = nil, hidden: Set<ObjectIdentifier> = [],
                 paper: Bool = true, vector: Bool = false) {
    // Without paper there is nothing underneath to multiply with.
    let env = DrawEnv(onDark: page.onDark || !paper, vector: vector)
    for it in page.items {
        if let area, !it.bbox.intersects(area) { continue }
        if !hidden.isEmpty && hidden.contains(ObjectIdentifier(it)) { continue }
        it.draw(g, env)
    }
}

/// Draw background and items; the context is in page points.
func renderPage(_ g: CGContext, _ page: PageSnap, printing: Bool = false, paper: Bool = true, ink: Bool = true) {
    let box = page.box
    if paper { renderBackground(g, page, box, printing: printing) }
    g.clip(to: box.rect)
    if ink { renderItems(g, page, nil, paper: paper, vector: printing) }
}

/// Raster of a page (a whiteboard's content); size letterboxes it into fixed pixels.
func pageImage(_ page: PageSnap, scale: Double, size: (Int, Int)? = nil, paper: Bool = true, ink: Bool = true) -> UIImage {
    let b = page.box
    var w: Int, h: Int
    var sx: Double, sy: Double, dx = 0.0, dy = 0.0
    if let size {
        (w, h) = size
        sx = min(Double(w) / b.w, Double(h) / b.h)
        sy = sx
        dx = (Double(w) - b.w * sx) / 2
        dy = (Double(h) - b.h * sy) / 2
    } else {
        // An image has to stay a size that fits in memory, however far a whiteboard sprawls.
        let s = min(scale, 8000 / max(b.w, b.h))
        w = max(1, Int((b.w * s).rounded()))
        h = max(1, Int((b.h * s).rounded()))
        sx = Double(w) / b.w
        sy = Double(h) / b.h
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
        let g = ctx.cgContext
        if size != nil {
            g.setFillColor(page.color.cg())
            g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        g.translateBy(x: dx, y: dy)
        g.scaleBy(x: sx, y: sy)
        g.translateBy(x: -b.x0, y: -b.y0)
        renderPage(g, page, paper: paper, ink: ink)
    }
}

/// Boxes on a page where query occurs: in its text boxes and notes, and in the PDF under it.
func findText(_ page: Page, _ query: String) -> [Box] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    if q.isEmpty { return [] }
    var out: [Box] = []
    if let pdf = page.pdf {
        let (ow, oh) = pdf.pageSize(page.pdfPage)
        out += pdf.find(page.pdfPage, q).map { rotBox(page.rot % 4, ow, oh, $0) }
    }
    out += page.items.compactMap { ($0 as? TextItem).flatMap { $0.text.lowercased().contains(q) ? $0.bbox : nil } }
    return out
}
