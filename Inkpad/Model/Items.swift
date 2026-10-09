import UIKit

/// The things that lie on a page. Units are PDF points. Every item draws itself onto a
/// CoreGraphics context whose origin is the top left (a UIKit-style context), so the screen
/// cache, thumbnails, PNG export and vector PDF export share one code path.

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ list: [Double]) {
        self.init(list.count > 0 ? list[0] : 0, list.count > 1 ? list[1] : 0, list.count > 2 ? list[2] : 0)
    }

    init(json: Any?, default fallback: RGB = RGB(0, 0, 0)) {
        if let a = json as? [Any], a.count >= 3 { self.init(a.map { num($0) }) } else { self = fallback }
    }

    var list: [Double] { [r, g, b] }
    var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    func cg(_ alpha: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    func scaled(_ k: Double) -> RGB { RGB(r * k, g * k, b * k) }

    static let white = RGB(1, 1, 1)
    static let black = RGB(0, 0, 0)
}

func num(_ value: Any?, _ fallback: Double = 0) -> Double {
    (value as? NSNumber)?.doubleValue ?? fallback
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

func newID() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
}

struct DrawEnv {
    var onDark = false   // the paper is dark: a marker cannot darken it
    var vector = false   // PDF export: keep every detail
}

protocol Item: AnyObject {
    /// Permanent id. Syncing merges two versions of a page by these, so an item keeps its
    /// id for as long as it is the same object.
    var id: String { get set }
    var kind: String { get }
    var bbox: Box { get }
    func draw(_ g: CGContext, _ env: DrawEnv)
    func polyline() -> [Pt]
    func sample() -> [Pt]
    func hit(_ x: Double, _ y: Double, _ r: Double) -> Bool
    func transformed(_ s: Double, _ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Item
    func rotated(_ k: Int, _ w: Double, _ h: Double) -> Item
    func toJSON(_ ctx: SaveCtx) -> [String: Any]
}

/// Rotate a point with its w x h page by k quarter turns clockwise.
func rotPt(_ k: Int, _ w: Double, _ h: Double, _ x: Double, _ y: Double) -> (Double, Double) {
    switch k {
    case 1: return (h - y, x)
    case 2: return (w - x, h - y)
    case 3: return (y, w - x)
    default: return (x, y)
    }
}

func rotBox(_ k: Int, _ w: Double, _ h: Double, _ box: Box) -> Box {
    let a = rotPt(k, w, h, box.x0, box.y0), b = rotPt(k, w, h, box.x1, box.y1)
    return Box(min(a.0, b.0), min(a.1, b.1), max(a.0, b.0), max(a.1, b.1))
}

/// Quadratic midpoint smoothing through the sampled points.
private func smoothPath(_ g: CGContext, _ pts: [Pt]) {
    var px = pts[0].x, py = pts[0].y
    g.move(to: CGPoint(x: px, y: py))
    let n = pts.count
    if n > 2 {
        for i in 1..<(n - 1) {
            let cx = pts[i].x, cy = pts[i].y
            let mx = (cx + pts[i + 1].x) / 2, my = (cy + pts[i + 1].y) / 2
            g.addCurve(to: CGPoint(x: mx, y: my),
                       control1: CGPoint(x: px + (cx - px) * 2 / 3, y: py + (cy - py) * 2 / 3),
                       control2: CGPoint(x: mx + (cx - mx) * 2 / 3, y: my + (cy - my) * 2 / 3))
            px = mx; py = my
        }
    }
    // A path that goes nowhere draws nothing; a hair's breadth makes it a dot.
    let last = pts[n - 1]
    let still = n == 1 || (n == 2 && last.x == pts[0].x && last.y == pts[0].y)
    g.addLine(to: CGPoint(x: last.x + (still ? 0.001 : 0), y: last.y))
}

/// Split a polyline into the 'pen down' runs of a dash pattern (on == 0 gives dots).
private func dashRuns(_ pts: [Pt], _ on: Double, _ off: Double) -> [[Pt]] {
    var runs: [[Pt]] = []
    var run = [pts[0]]
    var drawing = true
    var left = on
    var a = pts[0]
    for b in pts.dropFirst() {
        let seg = hypot(b.x - a.x, b.y - a.y)
        var pos = 0.0
        while seg - pos > left {
            pos += left
            let t = pos / seg
            let q = Pt(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, p: a.p + (b.p - a.p) * t)
            if drawing {
                run.append(q)
                runs.append(run)
                run = []
            } else {
                run = [q]
            }
            drawing.toggle()
            left = drawing ? on : off
        }
        left -= seg - pos
        if drawing { run.append(b) }
        a = b
    }
    if drawing && !run.isEmpty { runs.append(run) }
    return runs
}

let hlAlpha = 0.4

final class Stroke: Item {
    let kind = "s"
    var id = newID()
    var tool: String      // 'ball' | 'fountain' | 'brush' | 'hl' | 'tape'
    var open = false      // a tape that has been lifted: it shows what it covers
    var color: RGB
    var width: Double
    var sens: Double      // pressure sensitivity, 1.0 is the default response
    var dash: Int         // 0 solid, 1 dashed, 2 dotted
    var pts: [Pt]
    private(set) var bbox = Box(0, 0, 0, 0)

    init(_ tool: String, _ color: RGB, _ width: Double, _ pts: [Pt] = [], sens: Double = 1.0, dash: Int = 0) {
        self.tool = tool; self.color = color; self.width = width; self.pts = pts; self.sens = sens; self.dash = dash
        if !pts.isEmpty { updateBBox() }
    }

    func wAt(_ p: Double) -> Double {
        if tool == "fountain" { return width * max(0.15, 1 + sens * 1.2 * (p - 0.5)) }
        if tool == "brush" { return width * max(0.12, 1.4 + sens * 2.2 * (p - 0.5)) }
        return width
    }

    func pad() -> Double { wAt(1.0) / 2 + 1 }

    func updateBBox() { bbox = Geom.bbox(pts, pad: pad()) }

    func draw(_ g: CGContext, _ env: DrawEnv) {
        guard !pts.isEmpty else { return }
        g.setLineCap(.round)
        g.setLineJoin(.round)
        if tool == "tape" {
            // Tape covers what is under it; lifted, only a trace of it is left.
            g.setStrokeColor(color.cg(open ? 0.16 : 1.0))
            g.setLineWidth(width)
            smoothPath(g, pts)
            g.strokePath()
            return
        }
        let hl = tool == "hl"
        if hl {
            g.saveGState()
            // Multiplying darkens, which is what a marker does on light paper but
            // would make it invisible on a dark one.
            if !env.onDark { g.setBlendMode(.multiply) }
            g.setStrokeColor(color.cg(hlAlpha))
            g.setFillColor(color.cg(hlAlpha))
        } else {
            g.setStrokeColor(color.cg())
            g.setFillColor(color.cg())
        }
        let m = g.ctm
        let det = abs(m.a * m.d - m.b * m.c)
        let perPixel = det > 0 ? 1 / sqrt(det) : 1
        if perPixel > 1.5 && !env.vector {
            // Seen from far away: no pressure detail and no points closer together than a pixel,
            // and never thinner than a hairline, so the stroke stays visible and cheap to draw.
            let step2 = perPixel * perPixel
            var lx = pts[0].x, ly = pts[0].y
            g.move(to: CGPoint(x: lx, y: ly))
            if pts.count > 2 {
                for p in pts[1..<(pts.count - 1)] where (p.x - lx) * (p.x - lx) + (p.y - ly) * (p.y - ly) >= step2 {
                    g.addLine(to: CGPoint(x: p.x, y: p.y))
                    lx = p.x; ly = p.y
                }
            }
            g.addLine(to: CGPoint(x: pts[pts.count - 1].x + 0.001, y: pts[pts.count - 1].y))
            g.setLineWidth(max(width, perPixel * 0.9))
            g.strokePath()
        } else if dash != 0 && pts.count > 1 {
            let w = width
            let (on, off) = dash == 1 ? (max(3.0 * w, 2.5), max(2.6 * w, 3.0)) : (0.0, max(2.4 * w, 2.5))
            for run in dashRuns(pts, on, off) where !run.isEmpty { drawRun(g, run) }
        } else {
            drawRun(g, pts)
        }
        if hl { g.restoreGState() }
    }

    private func drawRun(_ g: CGContext, _ pts: [Pt]) {
        let n = pts.count
        if n == 1 {
            let r = wAt(pts[0].p) / 2
            g.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
        } else if tool == "hl" || tool == "ball" {
            g.setLineWidth(width)
            smoothPath(g, pts)
            g.strokePath()
        } else {
            // Pressure-sensitive: one short segment per sample, each its own width.
            var px = pts[0].x, py = pts[0].y, pp = pts[0].p
            for i in 1..<n {
                let c = pts[i]
                g.move(to: CGPoint(x: px, y: py))
                var mx = c.x, my = c.y
                if i < n - 1 {
                    mx = (c.x + pts[i + 1].x) / 2; my = (c.y + pts[i + 1].y) / 2
                    g.addCurve(to: CGPoint(x: mx, y: my),
                               control1: CGPoint(x: px + (c.x - px) * 2 / 3, y: py + (c.y - py) * 2 / 3),
                               control2: CGPoint(x: mx + (c.x - mx) * 2 / 3, y: my + (c.y - my) * 2 / 3))
                } else {
                    g.addLine(to: CGPoint(x: c.x, y: c.y))
                }
                g.setLineWidth((wAt(pp) + wAt(c.p)) / 2)
                g.strokePath()
                px = mx; py = my; pp = c.p
            }
        }
    }

    func polyline() -> [Pt] { pts }
    func sample() -> [Pt] { Geom.decimate(pts, 40) }
    func hit(_ x: Double, _ y: Double, _ r: Double) -> Bool { Geom.polylineHit(pts, x, y, r + width / 2) }

    func transformed(_ s: Double, _ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Item {
        let moved = pts.map { Pt(x: ox + ($0.x - ox) * s + dx, y: oy + ($0.y - oy) * s + dy, p: $0.p) }
        let new = Stroke(tool, color, width * s, moved, sens: sens, dash: dash)
        new.open = open
        return new
    }

    func rotated(_ k: Int, _ w: Double, _ h: Double) -> Item {
        Stroke(tool, color, width, pts.map { p in
            let q = rotPt(k, w, h, p.x, p.y)
            return Pt(x: q.0, y: q.1, p: p.p)
        }, sens: sens, dash: dash)
    }

    func toJSON(_ ctx: SaveCtx) -> [String: Any] {
        var d: [String: Any] = ["k": "s", "t": tool, "c": color.list, "w": width, "ps": sens, "d": dash,
                                "q": packPoints(pts)]
        if open { d["o"] = true }
        return d
    }

    static func fromJSON(_ d: [String: Any]) -> Stroke {
        var pts: [Pt] = []
        if let q = d["q"] as? String {
            pts = unpackPoints(q)
        } else if let f = d["p"] as? [Any] {   // files from before version 3 list the numbers
            var i = 0
            while i + 2 < f.count {
                pts.append(Pt(x: num(f[i]), y: num(f[i + 1]), p: num(f[i + 2])))
                i += 3
            }
        }
        let stroke = Stroke(d["t"] as? String ?? "ball", RGB(json: d["c"]), num(d["w"], 1), pts,
                            sens: num(d["ps"], 1.0), dash: Int(num(d["d"])))
        stroke.open = (d["o"] as? Bool) ?? false
        return stroke
    }
}

final class Shape: Item {
    let kind = "h"
    var id = newID()
    var shape: String   // 'line' | 'arrow' | 'rect' | 'ellipse'
    var x0: Double, y0: Double, x1: Double, y1: Double
    var color: RGB
    var width: Double
    private(set) var bbox = Box(0, 0, 0, 0)

    init(_ shape: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ color: RGB, _ width: Double) {
        self.shape = shape; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.color = color; self.width = width
        updateBBox()
    }

    func updateBBox() {
        let pad = width / 2 + (shape == "arrow" ? max(8.0, width * 4) : 1)
        bbox = Box(min(x0, x1) - pad, min(y0, y1) - pad, max(x0, x1) + pad, max(y0, y1) + pad)
    }

    func draw(_ g: CGContext, _ env: DrawEnv) {
        g.setStrokeColor(color.cg())
        g.setLineWidth(width)
        g.setLineCap(.round)
        g.setLineJoin(.round)
        if shape == "rect" {
            g.addRect(CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
        } else if shape == "ellipse" {
            let rx = abs(x1 - x0) / 2, ry = abs(y1 - y0) / 2
            if rx > 0.01 && ry > 0.01 {
                g.addEllipse(in: CGRect(x: min(x0, x1), y: min(y0, y1), width: 2 * rx, height: 2 * ry))
            }
        } else {
            g.move(to: CGPoint(x: x0, y: y0))
            g.addLine(to: CGPoint(x: x1, y: y1))
            if shape == "arrow" {
                let a = atan2(y1 - y0, x1 - x0)
                let head = max(8.0, width * 4)
                for da in [2.6, -2.6] {
                    g.move(to: CGPoint(x: x1, y: y1))
                    g.addLine(to: CGPoint(x: x1 + head * cos(a + da), y: y1 + head * sin(a + da)))
                }
            }
        }
        g.strokePath()
    }

    func polyline() -> [Pt] {
        if shape == "ellipse" {
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = abs(x1 - x0) / 2, ry = abs(y1 - y0) / 2
            return (0...40).map { Pt(x: cx + rx * cos(2 * .pi * Double($0) / 40), y: cy + ry * sin(2 * .pi * Double($0) / 40)) }
        }
        let corners: [(Double, Double)] = shape == "rect" ? [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)] : [(x0, y0), (x1, y1)]
        var out: [Pt] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for i in 0..<10 {
                out.append(Pt(x: a.0 + (b.0 - a.0) * Double(i) / 10, y: a.1 + (b.1 - a.1) * Double(i) / 10))
            }
        }
        out.append(Pt(x: corners.last!.0, y: corners.last!.1))
        return out
    }

    func sample() -> [Pt] { polyline() }
    func hit(_ x: Double, _ y: Double, _ r: Double) -> Bool { Geom.polylineHit(polyline(), x, y, r + width / 2) }

    func transformed(_ s: Double, _ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Item {
        Shape(shape, ox + (x0 - ox) * s + dx, oy + (y0 - oy) * s + dy, ox + (x1 - ox) * s + dx, oy + (y1 - oy) * s + dy,
              color, width * s)
    }

    func rotated(_ k: Int, _ w: Double, _ h: Double) -> Item {
        let a = rotPt(k, w, h, x0, y0), b = rotPt(k, w, h, x1, y1)
        return Shape(shape, a.0, a.1, b.0, b.1, color, width)
    }

    func toJSON(_ ctx: SaveCtx) -> [String: Any] {
        ["k": "h", "t": shape, "c": color.list, "w": width, "r": [x0, y0, x1, y1].map(round2)]
    }

    static func fromJSON(_ d: [String: Any]) -> Shape {
        let r = (d["r"] as? [Any] ?? []).map { num($0) } + [0, 0, 0, 0]
        return Shape(d["t"] as? String ?? "line", r[0], r[1], r[2], r[3], RGB(json: d["c"]), num(d["w"], 1))
    }
}

enum TextLayout {
    private static func attributes(_ size: Double, _ color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color]
    }

    static func measure(_ text: String, _ size: Double, _ wrap: Double) -> (Double, Double) {
        let limit = CGSize(width: wrap > 0 ? wrap : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let r = (text as NSString).boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: attributes(size, .black), context: nil)
        return (Double(ceil(r.width)), Double(ceil(r.height)))
    }

    static func show(_ g: CGContext, _ x: Double, _ y: Double, _ text: String, _ size: Double, _ wrap: Double, _ color: UIColor) {
        UIGraphicsPushContext(g)
        let limit = CGSize(width: wrap > 0 ? wrap : 100_000, height: 100_000)
        (text as NSString).draw(with: CGRect(origin: CGPoint(x: x, y: y), size: limit),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes(size, color), context: nil)
        UIGraphicsPopContext()
    }
}

final class TextItem: Item {
    let kind = "t"
    var id = newID()
    var x: Double, y: Double
    var text: String
    var size: Double
    var color: RGB
    var wrap: Double
    var bg: RGB?   // a sticky note: the text sits on a coloured slip of this colour
    private(set) var bbox = Box(0, 0, 0, 0)

    init(_ x: Double, _ y: Double, _ text: String, _ size: Double, _ color: RGB, wrap: Double = 0, bg: RGB? = nil) {
        self.x = x; self.y = y; self.text = text; self.size = size; self.color = color; self.wrap = wrap; self.bg = bg
        updateBBox()
    }

    func updateBBox() {
        var (w, h) = TextLayout.measure(text, size, wrap)
        let pad = bg != nil ? size * 0.7 : 2
        if bg != nil && wrap > 0 { w = max(w, wrap) }   // a note keeps its width however little is written on it
        h = max(h, size)
        bbox = Box(x - pad, y - pad, x + w + pad, y + h + pad)
    }

    func draw(_ g: CGContext, _ env: DrawEnv) {
        if let bg {
            let b = bbox
            let fold = min(size * 0.9, b.w / 4, b.h / 4)
            g.move(to: CGPoint(x: b.x0, y: b.y0))
            g.addLine(to: CGPoint(x: b.x1, y: b.y0))
            g.addLine(to: CGPoint(x: b.x1, y: b.y1 - fold))
            g.addLine(to: CGPoint(x: b.x1 - fold, y: b.y1))
            g.addLine(to: CGPoint(x: b.x0, y: b.y1))
            g.closePath()
            g.setFillColor(bg.cg())
            g.fillPath()
            g.move(to: CGPoint(x: b.x1, y: b.y1 - fold))
            g.addLine(to: CGPoint(x: b.x1 - fold, y: b.y1 - fold))
            g.addLine(to: CGPoint(x: b.x1 - fold, y: b.y1))
            g.closePath()
            g.setFillColor(bg.scaled(0.86).cg())
            g.fillPath()
        }
        TextLayout.show(g, x, y, text, size, wrap, color.ui)
    }

    func polyline() -> [Pt] { boxOutline(bbox) }
    func sample() -> [Pt] { boxSample(bbox) }
    func hit(_ x: Double, _ y: Double, _ r: Double) -> Bool { false }

    func transformed(_ s: Double, _ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Item {
        TextItem(ox + (x - ox) * s + dx, oy + (y - oy) * s + dy, text, size * s, color, wrap: wrap * s, bg: bg)
    }

    func rotated(_ k: Int, _ w: Double, _ h: Double) -> Item {
        let box = rotBox(k, w, h, bbox)
        let pad = x - bbox.x0
        return TextItem(box.x0 + pad, box.y0 + pad, text, size, color, wrap: wrap, bg: bg)
    }

    func toJSON(_ ctx: SaveCtx) -> [String: Any] {
        var d: [String: Any] = ["k": "t", "x": round2(x), "y": round2(y), "s": text, "z": size, "c": color.list, "wr": wrap]
        if let bg { d["bg"] = bg.list }
        return d
    }

    static func fromJSON(_ d: [String: Any]) -> TextItem {
        TextItem(num(d["x"]), num(d["y"]), d["s"] as? String ?? "", num(d["z"], 12), RGB(json: d["c"]),
                 wrap: num(d["wr"]), bg: (d["bg"] as? [Any]).map { RGB(json: $0) })
    }
}

private func boxOutline(_ b: Box) -> [Pt] {
    [Pt(x: b.x0, y: b.y0), Pt(x: b.x1, y: b.y0), Pt(x: b.x1, y: b.y1), Pt(x: b.x0, y: b.y1), Pt(x: b.x0, y: b.y0)]
}

private func boxSample(_ b: Box) -> [Pt] {
    [Pt(x: b.x0, y: b.y0), Pt(x: b.x1, y: b.y0), Pt(x: b.x1, y: b.y1), Pt(x: b.x0, y: b.y1),
     Pt(x: (b.x0 + b.x1) / 2, y: (b.y0 + b.y1) / 2)]
}

/// PNG bytes shared by every copy of a picture, decoded once.
final class ImageData {
    let data: Data
    private var decoded: UIImage?
    private let lock = NSLock()

    init(_ data: Data) { self.data = data }

    var image: UIImage? {
        lock.lock(); defer { lock.unlock() }
        if decoded == nil { decoded = UIImage(data: data) }
        return decoded
    }
}

final class ImageItem: Item {
    let kind = "i"
    var id = newID()
    var x: Double, y: Double, w: Double, h: Double
    let source: ImageData
    var bbox: Box { Box(x, y, x + w, y + h) }

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ source: ImageData) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.source = source
    }

    func draw(_ g: CGContext, _ env: DrawEnv) {
        guard let image = source.image else { return }
        UIGraphicsPushContext(g)
        image.draw(in: CGRect(x: x, y: y, width: w, height: h))
        UIGraphicsPopContext()
    }

    func polyline() -> [Pt] { boxOutline(bbox) }
    func sample() -> [Pt] { boxSample(bbox) }
    func hit(_ x: Double, _ y: Double, _ r: Double) -> Bool { false }

    func transformed(_ s: Double, _ ox: Double, _ oy: Double, _ dx: Double, _ dy: Double) -> Item {
        ImageItem(ox + (x - ox) * s + dx, oy + (y - oy) * s + dy, w * s, h * s, source)
    }

    func rotated(_ k: Int, _ pw: Double, _ ph: Double) -> Item {
        let box = rotBox(k, pw, ph, bbox)
        guard let image = source.image, let cg = image.cgImage, k % 4 != 0 else {
            return ImageItem(box.x0, box.y0, box.w, box.h, source)
        }
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let size = k % 2 == 1 ? CGSize(width: sh, height: sw) : CGSize(width: sw, height: sh)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let turned = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            switch k % 4 {
            case 1: g.translateBy(x: sh, y: 0)
            case 2: g.translateBy(x: sw, y: sh)
            default: g.translateBy(x: 0, y: sw)
            }
            g.rotate(by: CGFloat(k % 4) * .pi / 2)
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: sw, height: sh))
        }
        return ImageItem(box.x0, box.y0, box.w, box.h, ImageData(turned.pngData() ?? source.data))
    }

    func toJSON(_ ctx: SaveCtx) -> [String: Any] {
        ["k": "i", "r": [x, y, w, h].map(round2), "img": ctx.image(source)]
    }

    static func fromJSON(_ d: [String: Any], _ images: [ImageData]) -> ImageItem? {
        let r = (d["r"] as? [Any] ?? []).map { num($0) } + [0, 0, 0, 0]
        let n = Int(num(d["img"], -1))
        guard images.indices.contains(n) else { return nil }
        return ImageItem(r[0], r[1], r[2], r[3], images[n])
    }
}

final class SaveCtx {
    private(set) var images: [ImageData] = []
    private var seen: [ObjectIdentifier: Int] = [:]

    func image(_ source: ImageData) -> Int {
        if let n = seen[ObjectIdentifier(source)] { return n }
        seen[ObjectIdentifier(source)] = images.count
        images.append(source)
        return images.count - 1
    }
}

func itemFromJSON(_ d: [String: Any], _ images: [ImageData]) -> Item? {
    switch d["k"] as? String {
    case "s": return Stroke.fromJSON(d)
    case "h": return Shape.fromJSON(d)
    case "t": return TextItem.fromJSON(d)
    case "i": return ImageItem.fromJSON(d, images)
    default: return nil
    }
}

// MARK: stroke points as text

private func zig(_ value: Int64, into out: inout [UInt8]) {
    var n = UInt64(bitPattern: (value << 1) ^ (value >> 63))
    while true {
        let b = UInt8(n & 0x7f)
        n >>= 7
        if n != 0 { out.append(b | 0x80) } else { out.append(b); return }
    }
}

/// Stroke points as text a fifth the size of a list of numbers: the first point in full,
/// then the steps between points in hundredths of a point, and each pressure as one byte.
func packPoints(_ pts: [Pt]) -> String {
    guard let first = pts.first else { return "" }
    var out: [UInt8] = []
    out.reserveCapacity(16 + pts.count * 4)
    withUnsafeBytes(of: first.x.bitPattern.littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: first.y.bitPattern.littleEndian) { out.append(contentsOf: $0) }
    var px = Int64((first.x * 100).rounded(.toNearestOrEven)), py = Int64((first.y * 100).rounded(.toNearestOrEven))
    for p in pts {
        let cx = Int64((p.x * 100).rounded(.toNearestOrEven)), cy = Int64((p.y * 100).rounded(.toNearestOrEven))
        zig(cx - px, into: &out)
        zig(cy - py, into: &out)
        out.append(UInt8(max(0, min(255, (p.p * 255).rounded(.toNearestOrEven)))))
        px = cx; py = cy
    }
    return Data(out).base64EncodedString()
}

func unpackPoints(_ text: String) -> [Pt] {
    guard let data = Data(base64Encoded: text), data.count >= 16 else { return [] }
    let bytes = [UInt8](data)
    func f64(_ o: Int) -> Double {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
        return Double(bitPattern: v)
    }
    let x0 = f64(0), y0 = f64(8)
    var px = Int64((x0 * 100).rounded(.toNearestOrEven)), py = Int64((y0 * 100).rounded(.toNearestOrEven))
    var pts: [Pt] = []
    var i = 16
    let n = bytes.count
    while i < n {
        var step = [Int64](repeating: 0, count: 2)
        for k in 0..<2 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < n {
                let c = bytes[i]
                i += 1
                value |= UInt64(c & 0x7f) << shift
                shift += 7
                if c & 0x80 == 0 { break }
            }
            step[k] = Int64(bitPattern: value >> 1) ^ -Int64(value & 1)
        }
        guard i < n else { break }
        px += step[0]; py += step[1]
        pts.append(Pt(x: Double(px) / 100, y: Double(py) / 100, p: Double(bytes[i]) / 255))
        i += 1
    }
    if !pts.isEmpty {
        pts[0].x = x0
        pts[0].y = y0
    }
    return pts
}
