import Foundation
import CoreGraphics

/// Geometry helpers: hit testing, lasso picking and scribble-to-erase detection.
/// All coordinates are page points.

struct Pt {
    var x: Double
    var y: Double
    var p: Double = 0.5
}

struct Box: Equatable {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double

    var w: Double { x1 - x0 }
    var h: Double { y1 - y0 }
    var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }

    init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    init(_ r: CGRect) {
        self.init(Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY))
    }

    func intersects(_ b: Box) -> Bool { x0 <= b.x1 && b.x0 <= x1 && y0 <= b.y1 && b.y0 <= y1 }
    func contains(_ x: Double, _ y: Double) -> Bool { x0 <= x && x <= x1 && y0 <= y && y <= y1 }
    func padded(_ d: Double) -> Box { Box(x0 - d, y0 - d, x1 + d, y1 + d) }
    func union(_ b: Box) -> Box { Box(min(x0, b.x0), min(y0, b.y0), max(x1, b.x1), max(y1, b.y1)) }
}

func union(_ a: Box?, _ b: Box?) -> Box? {
    guard let a else { return b }
    guard let b else { return a }
    return a.union(b)
}

enum Geom {
    static func bbox(_ pts: [Pt], pad: Double = 0) -> Box {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for p in pts {
            x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
        }
        return Box(x0 - pad, y0 - pad, x1 + pad, y1 + pad)
    }

    static func decimate(_ pts: [Pt], _ limit: Int) -> [Pt] {
        let n = pts.count
        if n <= limit { return pts }
        let step = Double(n) / Double(limit)
        var out = (0..<limit).map { pts[Int(Double($0) * step)] }
        out.append(pts[n - 1])
        return out
    }

    static func dist2Seg(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let d = dx * dx + dy * dy
        if d <= 1e-12 { return (px - ax) * (px - ax) + (py - ay) * (py - ay) }
        var t = ((px - ax) * dx + (py - ay) * dy) / d
        t = t < 0 ? 0 : t > 1 ? 1 : t
        let ex = px - ax - t * dx, ey = py - ay - t * dy
        return ex * ex + ey * ey
    }

    static func polylineHit(_ pts: [Pt], _ x: Double, _ y: Double, _ r: Double) -> Bool {
        let r2 = r * r
        guard var a = pts.first else { return false }
        if pts.count == 1 { return (a.x - x) * (a.x - x) + (a.y - y) * (a.y - y) <= r2 }
        for b in pts.dropFirst() {
            if dist2Seg(x, y, a.x, a.y, b.x, b.y) <= r2 { return true }
            a = b
        }
        return false
    }

    static func inPolygon(_ poly: [Pt], _ x: Double, _ y: Double) -> Bool {
        guard var a = poly.last else { return false }
        var inside = false
        for b in poly {
            if (a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            a = b
        }
        return inside
    }

    static func convexHull(_ input: [Pt]) -> [Pt] {
        var seen = Set<[Double]>()
        var pts: [Pt] = []
        for p in input where seen.insert([p.x, p.y]).inserted { pts.append(Pt(x: p.x, y: p.y)) }
        pts.sort { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        if pts.count < 3 { return pts }
        func half(_ seq: [Pt]) -> [Pt] {
            var out: [Pt] = []
            for p in seq {
                while out.count >= 2 {
                    let a = out[out.count - 2], b = out[out.count - 1]
                    if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) <= 0 { out.removeLast() } else { break }
                }
                out.append(p)
            }
            out.removeLast()
            return out
        }
        return half(pts) + half(pts.reversed())
    }

    static func segsCross(_ a: Pt, _ b: Pt, _ c: Pt, _ d: Pt) -> Bool {
        func side(_ p: Pt, _ q: Pt, _ r: Pt) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        return (side(a, b, c) > 0) != (side(a, b, d) > 0) && (side(c, d, a) > 0) != (side(c, d, b) > 0)
    }

    // MARK: scribble to erase

    static let minReversals = 3       // a scribble is at least four back-and-forth passes
    static let minLengthRatio = 2.5   // path length relative to its extent along the main axis
    static let spreadFree = 0.3       // a scribble this thin (width across / length along) needs no extra passes
    static let spreadStep = 0.25      // one more pass for each step wider than that
    static let denseRatio = 7.0       // path length relative to extent of a rub over one small spot
    static let straightPasses = 4     // straight lines back and forth, each along the one before

    /// True when a stroke looks like a quick back-and-forth scratch-out.
    ///
    /// Writing turns a lot too, so turning alone does not decide: a word written in one stroke goes
    /// round its letters, and a large one turns through 4π or 8π without being a scribble. What a
    /// scratch-out does is go back over the same ground: each pass runs at least half the stroke's
    /// length, it turns about half a turn at each end and seldom in between, and the more room it
    /// spreads over the more passes it takes before it reads as a scribble. A rub that keeps
    /// circling one small spot counts as well, and so do straight lines drawn back and forth, each
    /// close along the one before, however far they reach. `loose` asks for the earlier rule.
    static func isScribble(_ pts: [Pt], loose: Bool = false) -> Bool {
        if pts.count < 10 { return false }
        if loose { return Self.loose(pts) }
        return scratched(pts) || straightPasses(pts)
    }

    /// The earlier rule, kept for those who want it: four passes back and forth along the main
    /// axis, each at least 15% of the stroke's length. It catches more, joined-up writing included.
    private static func loose(_ pts: [Pt]) -> Bool {
        let n = pts.count
        let mx = pts.reduce(0) { $0 + $1.x } / Double(n)
        let my = pts.reduce(0) { $0 + $1.y } / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(ang), uy = sin(ang)
        let t = pts.map { ($0.x - mx) * ux + ($0.y - my) * uy }
        let extent = t.max()! - t.min()!
        if extent < 5 { return false }
        var length = 0.0
        var a = pts[0]
        for b in pts.dropFirst() {
            length += hypot(b.x - a.x, b.y - a.y)
            a = b
        }
        if length < minLengthRatio * extent { return false }
        let h = max(extent * 0.15, 1.5)
        var direction = 0
        var ext = t[0]
        var reversals = 0
        for v in t.dropFirst() {
            if direction == 0 {
                if abs(v - ext) >= h {
                    direction = v > ext ? 1 : -1
                    ext = v
                }
            } else if direction == 1 {
                if v > ext { ext = v } else if ext - v >= h { reversals += 1; direction = -1; ext = v }
            } else {
                if v < ext { ext = v } else if v - ext >= h { reversals += 1; direction = 1; ext = v }
            }
        }
        return reversals >= minReversals
    }

    private static func scratched(_ pts: [Pt]) -> Bool {
        let n = pts.count
        let mx = pts.reduce(0) { $0 + $1.x } / Double(n)
        let my = pts.reduce(0) { $0 + $1.y } / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(ang), uy = sin(ang)
        let t = pts.map { ($0.x - mx) * ux + ($0.y - my) * uy }
        let across = pts.map { ($0.y - my) * ux - ($0.x - mx) * uy }
        let extent = t.max()! - t.min()!
        if extent < 5 { return false }
        let width = across.max()! - across.min()!
        var length = 0.0
        var a = pts[0]
        for b in pts.dropFirst() {
            length += hypot(b.x - a.x, b.y - a.y)
            a = b
        }
        if length < minLengthRatio * extent { return false }
        // Direction reversals along the main axis, each at least half the stroke's length away
        // from the one before, so that what letters do inside a word is not counted.
        let h = extent * 0.5
        var direction = 0
        var ext = t[0]
        var reversals = 0
        for v in t.dropFirst() {
            if direction == 0 {
                if abs(v - ext) >= h {
                    direction = v > ext ? 1 : -1
                    ext = v
                }
            } else if direction == 1 {
                if v > ext { ext = v } else if ext - v >= h { reversals += 1; direction = -1; ext = v }
            } else {
                if v < ext { ext = v } else if v - ext >= h { reversals += 1; direction = 1; ext = v }
            }
        }
        if reversals < minReversals { return false }
        let turned = turning(pts, max(hypot(extent, width) / 40, 0.5))
        if length >= denseRatio * extent && turned >= 4 * .pi { return true }
        if turned - .pi * Double(reversals) > 2 * .pi { return false }   // it went round in loops besides: handwriting
        let need = minReversals + max(0, Int(((width / extent - spreadFree) / spreadStep - 1e-9).rounded(.up)))
        return reversals >= need
    }

    /// Straight lines back and forth: each pass turns right round from the one before, runs close
    /// along it, and is about as long. Handwriting has strokes like that (an M, a W) but not four
    /// in a row lying on top of each other.
    private static func straightPasses(_ pts: [Pt]) -> Bool {
        let (legs, size) = Self.legs(pts)
        var run = 1
        for (a, b) in zip(legs, legs.dropFirst()) {
            let la = hypot(a.2 - a.0, a.3 - a.1)
            let lb = hypot(b.2 - b.0, b.3 - b.1)
            let longer = max(la, lb), shorter = min(la, lb)
            let back = ((a.2 - a.0) * (b.2 - b.0) + (a.3 - a.1) * (b.3 - b.1)) / (la * lb) <= -0.966   // 165° or more
            // how far the middle of this pass is from the line of the one before
            let mx = (b.0 + b.2) / 2, my = (b.1 + b.3) / 2
            let off = abs((a.2 - a.0) * (a.1 - my) - (a.0 - mx) * (a.3 - a.1)) / la
            if back && off <= 0.08 * longer && shorter >= 0.4 * longer && shorter >= 0.2 * size {
                run += 1
                if run >= straightPasses { return true }
            } else {
                run = 1
            }
        }
        return false
    }

    /// A stroke as the straight runs it is made of, (x0, y0, x1, y1) each, leaving out the short
    /// bits where it turns; and the size of the stroke.
    private static func legs(_ pts: [Pt]) -> ([(Double, Double, Double, Double)], Double) {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let size = hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        if size < 5 { return ([], size) }
        let step = size / 100
        var r = [pts[0]]
        var walked = 0.0
        var lastKept = 0
        for i in 1..<pts.count {
            walked += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            if walked >= step {
                r.append(pts[i])
                lastKept = i
                walked = 0
            }
        }
        if lastKept != pts.count - 1 { r.append(pts[pts.count - 1]) }
        // A run ends where the way on, a few steps ahead, leaves its direction by more than 45°.
        var legs: [(Double, Double, Double, Double)] = []
        var start = 0
        if r.count > 2 {
            for i in 1..<(r.count - 1) {
                let j = min(i + 3, r.count - 1)
                let lx = r[i].x - r[start].x, ly = r[i].y - r[start].y
                let nx = r[j].x - r[i].x, ny = r[j].y - r[i].y
                let a = hypot(lx, ly), b = hypot(nx, ny)
                if a > 1e-9 && b > 1e-9 && (lx * nx + ly * ny) / (a * b) < 0.7071 {
                    legs.append((r[start].x, r[start].y, r[i].x, r[i].y))
                    start = i
                }
            }
        }
        legs.append((r[start].x, r[start].y, r[r.count - 1].x, r[r.count - 1].y))
        let longest = legs.map { hypot($0.2 - $0.0, $0.3 - $0.1) }.max()!
        return (legs.filter { hypot($0.2 - $0.0, $0.3 - $0.1) >= 0.15 * longest && longest > 0 }, size)
    }

    /// How far the direction of a stroke turns in all, left and right alike, measured on points
    /// about `step` apart so that the tremor of the hand does not add up.
    static func turning(_ pts: [Pt], _ step: Double) -> Double {
        var kept = [pts[0]]
        var run = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) {
            run += hypot(b.x - a.x, b.y - a.y)
            if run >= step {
                kept.append(b)
                run = 0
            }
        }
        var total = 0.0
        var prev: Double?
        for (a, b) in zip(kept, kept.dropFirst()) {
            let heading = atan2(b.y - a.y, b.x - a.x)
            if let prev {
                var d = (heading - prev + .pi).truncatingRemainder(dividingBy: 2 * .pi)
                if d < 0 { d += 2 * .pi }
                total += abs(d - .pi)
            }
            prev = heading
        }
        return total
    }

    /// Items a scribble covers: mostly inside its hull, or crossed repeatedly.
    static func scribbleTargets(_ pts: [Pt], _ items: [Item]) -> [Item] {
        let sc = decimate(pts, 150)
        let bb = bbox(sc)
        let hull = convexHull(sc)
        if hull.count < 3 { return [] }
        var out: [Item] = []
        for it in items {
            guard it.kind == "s" || it.kind == "h", it.bbox.intersects(bb) else { continue }
            let pl = decimate(it.polyline(), 150)
            if pl.count == 1 {
                if inPolygon(hull, pl[0].x, pl[0].y) { out.append(it) }
                continue
            }
            var total = 0.0, inside = 0.0
            var a = pl[0]
            for b in pl.dropFirst() {
                let seg = hypot(b.x - a.x, b.y - a.y) + 1e-6
                total += seg
                if inPolygon(hull, (a.x + b.x) / 2, (a.y + b.y) / 2) { inside += seg }
                a = b
            }
            let cover = inside / total
            if cover >= 0.35 {
                out.append(it)
            } else if cover >= 0.08 && crossings(sc, pl, 4) >= 4 {
                out.append(it)
            }
        }
        return out
    }

    private static func crossings(_ aPts: [Pt], _ bPts: [Pt], _ enough: Int) -> Int {
        var count = 0
        var a0 = aPts[0]
        for a1 in aPts.dropFirst() {
            var b0 = bPts[0]
            for b1 in bPts.dropFirst() {
                if segsCross(a0, a1, b0, b1) {
                    count += 1
                    if count >= enough { return count }
                }
                b0 = b1
            }
            a0 = a1
        }
        return count
    }

    /// Whether any part of an item lies in a region given by its box and a point test.
    private static func touching(_ it: Item, _ box: Box, _ inside: (Double, Double) -> Bool) -> Bool {
        if !it.bbox.intersects(box) { return false }
        let line = it.polyline()
        let pts = line.count > 1 ? densify(line, 3.0) : it.sample()
        return pts.contains { inside($0.x, $0.y) }
    }

    /// Items the lasso touches: having any part inside it selects the whole item.
    static func lassoPick(_ input: [Pt], _ items: [Item]) -> [Item] {
        let poly = decimate(input, 120)
        if poly.count < 3 { return [] }
        let bb = bbox(poly)
        var out: [Item] = []
        for it in items {
            if touching(it, bb, { inPolygon(poly, $0, $1) }) {
                out.append(it)
            } else if (it.kind == "i" || it.kind == "t") && it.bbox.intersects(bb) {
                // Pictures and text boxes have an inside: a loop drawn over one counts too.
                if poly.contains(where: { it.bbox.contains($0.x, $0.y) }) { out.append(it) }
            }
        }
        return out
    }

    static func rectPick(_ box: Box, _ items: [Item]) -> [Item] {
        items.filter { it in
            if it.kind == "i" || it.kind == "t" { return it.bbox.intersects(box) }
            return touching(it, box) { box.contains($0, $1) }
        }
    }

    // MARK: partial erasing

    /// Insert interpolated samples so no segment is longer than step.
    static func densify(_ pts: [Pt], _ step: Double) -> [Pt] {
        var out = [pts[0]]
        for b in pts.dropFirst() {
            let a = out[out.count - 1]
            let d = hypot(b.x - a.x, b.y - a.y)
            if d > step {
                let n = Int(d / step) + 1
                for i in 1..<n {
                    let t = Double(i) / Double(n)
                    out.append(Pt(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, p: a.p + (b.p - a.p) * t))
                }
            }
            out.append(b)
        }
        return out
    }

    /// Cut the part of a stroke within r of segment a-b out of it.
    ///
    /// Returns the surviving runs of points and the bounding box of the part that changed,
    /// or nil when nothing was touched. Only the segments next to the eraser are resampled,
    /// so the rest of the stroke keeps its exact shape.
    static func eraseRuns(_ pts: [Pt], _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ r: Double) -> (runs: [[Pt]], box: Box)? {
        let r2 = r * r
        let n = pts.count
        guard n > 0 else { return nil }
        let inside = pts.map { dist2Seg($0.x, $0.y, ax, ay, bx, by) <= r2 }
        let step = max(r * 0.4, 0.3)
        let ea = Pt(x: ax, y: ay), eb = Pt(x: bx, y: by)
        var runs: [[Pt]] = []
        var run: [Pt] = []
        var cut = inside[0]
        var lo = inside[0] ? 0 : n, hi = inside[0] ? 0 : -1
        if !inside[0] { run.append(pts[0]) }
        for i in 1..<max(1, n) where n > 1 {
            let a = pts[i - 1], b = pts[i]
            if !(inside[i - 1] || inside[i]
                 || dist2Seg(ax, ay, a.x, a.y, b.x, b.y) <= r2
                 || dist2Seg(bx, by, a.x, a.y, b.x, b.y) <= r2
                 || segsCross(a, b, ea, eb)) {
                run.append(b)
                continue
            }
            lo = min(lo, i - 1); hi = max(hi, i)
            let k = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step) + 1)
            for j in 1...k {
                let t = Double(j) / Double(k)
                let q = j == k ? b : Pt(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, p: a.p + (b.p - a.p) * t)
                if dist2Seg(q.x, q.y, ax, ay, bx, by) <= r2 {
                    cut = true
                    if !run.isEmpty {
                        runs.append(run)
                        run = []
                    }
                } else {
                    run.append(q)
                }
            }
        }
        if !cut { return nil }
        if !run.isEmpty { runs.append(run) }
        return (runs, bbox(Array(pts[max(0, lo - 2)..<min(n, hi + 3)])))
    }

    // MARK: hold to snap to a shape

    /// Classify a freehand stroke as a line, rectangle or ellipse, or nil.
    static func recognizeShape(_ pts: [Pt]) -> (kind: String, x0: Double, y0: Double, x1: Double, y1: Double)? {
        let n = pts.count
        if n < 6 { return nil }
        var length = 0.0
        var a = pts[0]
        for b in pts.dropFirst() {
            length += hypot(b.x - a.x, b.y - a.y)
            a = b
        }
        let first = pts[0], last = pts[n - 1]
        let chord = hypot(last.x - first.x, last.y - first.y)
        if length < 8 { return nil }
        if chord > 0.88 * length { return ("line", first.x, first.y, last.x, last.y) }
        if chord > 0.25 * length { return nil }   // neither straight nor closed
        let b = bbox(pts)
        let w = b.w, h = b.h
        if min(w, h) < 4 { return nil }
        let cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2, rx = w / 2, ry = h / 2
        var eErr = 0.0, rErr = 0.0
        for p in pts {
            eErr += abs(hypot((p.x - cx) / rx, (p.y - cy) / ry) - 1)
            rErr += min(p.x - b.x0, b.x1 - p.x, p.y - b.y0, b.y1 - p.y) / min(w, h)
        }
        eErr /= Double(n); rErr /= Double(n)
        if rErr < 0.07 && rErr < eErr { return ("rect", b.x0, b.y0, b.x1, b.y1) }
        if eErr < 0.16 { return ("ellipse", b.x0, b.y0, b.x1, b.y1) }
        return nil
    }
}
