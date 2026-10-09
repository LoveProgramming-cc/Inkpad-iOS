import UIKit

/// Reading and writing Goodnotes documents (.goodnotes), as the desktop app does.
///
/// The format is not published; what is here was worked out from files. A document is a
/// zip archive:
///
///   index.events.pb       a log of length-prefixed protobuf records describing the document:
///                         its title, its page templates (a PDF attachment, a page of it, and
///                         the size the template is laid out at) and its pages (which template,
///                         and a sort key that gives the page order)
///   index.notes.pb        page id -> the file with that page's content
///   notes/<id>            length-prefixed protobuf records, a header and a body per element;
///                         a later body for the same element replaces the earlier one, and one
///                         marked as deleted removes it
///   attachments/<id>      the PDFs that the pages are drawn on (paper templates included)
///
/// A stroke's geometry is an Apple-LZ4 compressed "tpl" block: a type string followed by the
/// values it describes. Only the centre line and the width are read; the cached outline
/// that follows is ignored.
///
/// What is imported: pages in order, their PDF backgrounds, pen strokes with colour and
/// width, text boxes and notes (plain text), pictures and straight connectors. Anything
/// else is skipped and counted.
enum Goodnotes {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Stats: Equatable {
        var strokes = 0, texts = 0, shapes = 0, formulas = 0, images = 0, skipped = 0
    }

    /// Goodnotes lays a template out larger than its PDF page; this is the factor when there
    /// is no PDF to measure it against.
    static let fallbackScale = 6.0 / 11
    /// The number stored with each point of a pressure-sensitive stroke is not the line's
    /// half width: measured against the outlines Goodnotes caches next to it, the line is
    /// about 1.42 times that number wide.
    static let penWidth = 1.42
    static let imageLimit: CGFloat = 2400   // pixels along the longer side of an imported picture

    typealias Bytes = [UInt8]

    // MARK: protobuf, as much of it as is needed

    enum Value {
        case int(UInt64)
        case bytes(Bytes)

        var bytes: Bytes {
            if case .bytes(let b) = self { return b }
            return []
        }

        var isBytes: Bool {
            if case .bytes = self { return true }
            return false
        }

        /// Set to something: a number other than zero, or bytes that are not empty.
        var truthy: Bool {
            switch self {
            case .int(let n): return n != 0
            case .bytes(let b): return !b.isEmpty
            }
        }
    }

    typealias Message = [Int: [Value]]

    private static let malformed = Failure("malformed")

    private static func varint(_ b: Bytes, _ i: inout Int) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < b.count else { throw malformed }
            let c = b[i]
            i += 1
            if shift < 64 { value |= UInt64(c & 0x7f) << shift }
            shift += 7
            if c & 0x80 == 0 { return value }
        }
    }

    /// (field number, wire type, value) for each field of a message.
    static func fields(_ b: Bytes) throws -> [(Int, Int, Value)] {
        var out: [(Int, Int, Value)] = []
        var i = 0
        let n = b.count
        while i < n {
            let key = try varint(b, &i)
            let number = Int(truncatingIfNeeded: key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                out.append((number, wire, .int(try varint(b, &i))))
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard i + size <= n else { throw malformed }
                out.append((number, wire, .bytes(Array(b[i..<(i + size)]))))
                i += size
            case 2:
                let size = try varint(b, &i)
                guard size <= UInt64(n - i) else { throw malformed }
                out.append((number, wire, .bytes(Array(b[i..<(i + Int(size))]))))
                i += Int(size)
            default:
                throw malformed
            }
        }
        return out
    }

    /// A message as [field number: values].
    static func message(_ b: Bytes) throws -> Message {
        var out: Message = [:]
        for (number, _, value) in try fields(b) { out[number, default: []].append(value) }
        return out
    }

    /// The length-prefixed records of a file; a damaged tail is left out.
    static func records(_ b: Bytes) -> [Bytes] {
        var out: [Bytes] = []
        var i = 0
        while i < b.count {
            guard let size = try? varint(b, &i) else { break }
            let end = Int(min(UInt64(b.count - i), size)) + i
            out.append(Array(b[i..<end]))
            i = end
        }
        return out
    }

    private static func first(_ m: Message, _ number: Int) -> Value? { m[number]?.first }
    private static func data(_ m: Message, _ number: Int) -> Bytes { m[number]?.first?.bytes ?? [] }
    private static func sub(_ m: Message, _ number: Int) throws -> Message { try message(data(m, number)) }
    private static func text(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

    private static func float(_ b: Bytes, _ o: Int = 0) -> Double {
        guard o + 4 <= b.count else { return 0 }
        return Double(Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
    }

    /// A point, size or colour: float fields 1..n. A component that is zero is simply left
    /// out of the file, so the values have to be placed by field number, not by position.
    private static func vec(_ value: Bytes, _ n: Int) throws -> [Double] {
        var out = [Double](repeating: 0, count: n)
        for (number, wire, v) in try fields(value) where wire == 5 && 1 <= number && number <= n { out[number - 1] = float(v.bytes) }
        return out
    }

    // MARK: Apple's LZ4 framing

    private static func lz4Block(_ src: ArraySlice<UInt8>, into out: inout Bytes) throws {
        var i = src.startIndex
        let n = src.endIndex
        while i < n {
            let token = src[i]
            i += 1
            var literal = Int(token >> 4)
            if literal == 15 {
                while true {
                    guard i < n else { throw malformed }
                    let c = src[i]
                    i += 1
                    literal += Int(c)
                    if c != 255 { break }
                }
            }
            guard i + literal <= n else { throw malformed }
            out.append(contentsOf: src[i..<(i + literal)])
            i += literal
            if i >= n { break }
            guard i + 2 <= n else { throw malformed }
            let offset = Int(src[i]) | Int(src[i + 1]) << 8
            i += 2
            var length = Int(token & 15)
            if length == 15 {
                while true {
                    guard i < n else { throw malformed }
                    let c = src[i]
                    i += 1
                    length += Int(c)
                    if c != 255 { break }
                }
            }
            length += 4
            let start = out.count - offset
            guard offset > 0, start >= 0 else { throw malformed }
            out.reserveCapacity(out.count + length)
            for k in 0..<length { out.append(out[start + k]) }   // the match may overlap what it produces
        }
    }

    private static func u32(_ b: Bytes, _ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= b.count else { throw malformed }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// Blocks tagged bv41 (LZ4) or bv4- (stored), ended by bv4$.
    static func decompress(_ b: Bytes) throws -> Bytes {
        var out: Bytes = []
        var i = 0
        while i + 4 <= b.count {
            let magic = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            i += 4
            if magic == "bv41" {
                let size = try u32(b, i + 4)
                i += 8
                guard i + size <= b.count else { throw malformed }
                try lz4Block(b[i..<(i + size)], into: &out)
                i += size
            } else if magic == "bv4-" {
                let size = try u32(b, i)
                i += 4
                guard i + size <= b.count else { throw malformed }
                out.append(contentsOf: b[i..<(i + size)])
                i += size
            } else if magic == "bv4$" {
                break
            } else {
                throw Failure("not an LZ4 stream")
            }
        }
        return out
    }

    // MARK: "tpl" blocks

    /// The type string as a tree: v u f are scalars, A(..) an array, S(..) a struct.
    private indirect enum Kind: Equatable {
        case v, u, f
        case array([Kind])
        case record([Kind])
    }

    private enum Val {
        case num(Double)
        case nums([Double])
        case list([Val])

        var num: Double {
            if case .num(let n) = self { return n }
            return 0
        }

        var nums: [Double]? {
            if case .nums(let n) = self { return n }
            return nil
        }

        var list: [Val] {
            if case .list(let l) = self { return l }
            return []
        }
    }

    private static func signature(_ sig: [Character], _ i: inout Int) -> [Kind] {
        var out: [Kind] = []
        while i < sig.count && sig[i] != ")" {
            let c = sig[i]
            if c == "A" || c == "S" {
                i += 2
                let inner = signature(sig, &i)
                out.append(c == "A" ? .array(inner) : .record(inner))
                i += 1
            } else {
                out.append(c == "v" ? .v : c == "u" ? .u : .f)
                i += 1
            }
        }
        return out
    }

    private static func read(_ types: [Kind], _ d: Bytes, _ i: inout Int) throws -> [Val] {
        var values: [Val] = []
        func u16() throws -> Double {
            guard i + 2 <= d.count else { throw malformed }
            defer { i += 2 }
            return Double(Int(d[i]) | Int(d[i + 1]) << 8)
        }
        func f32() throws -> Double {
            guard i + 4 <= d.count else { throw malformed }
            defer { i += 4 }
            return float(d, i)
        }
        for t in types {
            switch t {
            case .v:
                values.append(.num(try u16()))
            case .u, .f:
                values.append(.num(try f32()))
            case .array(let inner):
                let count = try u32(d, i)
                i += 4
                if inner == [.v] {
                    guard count >= 0, i + 2 * count <= d.count else { throw malformed }
                    values.append(.nums(try (0..<count).map { _ in try u16() }))
                } else if inner == [.u] || inner == [.f] {
                    guard count >= 0, i + 4 * count <= d.count else { throw malformed }
                    values.append(.nums(try (0..<count).map { _ in try f32() }))
                } else {
                    guard count >= 0, count <= d.count else { throw malformed }
                    values.append(.list(try (0..<count).map { _ in .list(try read(inner, d, &i)) }))
                }
            case .record(let inner):
                values.append(.list(try read(inner, d, &i)))
            }
        }
        return values
    }

    private static func tpl(_ raw: Bytes) throws -> (String, [Val]) {
        guard raw.count > 9, raw[0] == 0x74, raw[1] == 0x70, raw[2] == 0x6c, raw[3] == 0,
              let end = raw[8...].firstIndex(of: 0) else { throw Failure("not a tpl block") }
        let sig = String(decoding: raw[8..<end], as: UTF8.self)
        var at = 0
        let types = signature(Array(sig), &at)
        var i = end + 1
        return (sig, try read(types, raw, &i))
    }

    // MARK: strokes

    private typealias P3 = (Double, Double, Double)   // x, y, width

    /// Add the middle and the end of a quadratic curve to a polyline of (x, y, width).
    private static func quad(_ points: inout [P3], _ c: P3, _ p1: P3) {
        guard let p0 = points.last else { return }
        points.append((0.25 * p0.0 + 0.5 * c.0 + 0.25 * p1.0, 0.25 * p0.1 + 0.5 * c.1 + 0.25 * p1.1, 0.25 * p0.2 + 0.5 * c.2 + 0.25 * p1.2))
        points.append(p1)
    }

    /// A width factor, or 1 where the file holds something that is not one.
    private static func factor(_ k: Double) -> Double { 0.05 < k && k < 8 ? k : 1.0 }

    /// A stroke's centre lines as [(tool hint, [(x, y, width)])]; width is a diameter.
    private static func paths(_ raw: Bytes) throws -> [(String, [P3])] {
        let (sig, v) = try tpl(raw)
        var paths: [(String, [P3])] = []
        func need(_ n: Int) throws {
            if v.count < n { throw malformed }
        }
        if sig.hasPrefix("vuA(v)A(S(uu))A(S(uuuu))") {
            // Constant width: op 0 starts at the next point, op 1 is a curve (control, end).
            try need(5)
            let width = v[1].num, ops = v[2].nums ?? [], moves = v[3].list, curves = v[4].list
            var mi = 0, ci = 0
            for op in ops {
                if op == 0 && mi < moves.count {
                    let p = moves[mi].list.first?.list ?? []
                    mi += 1
                    guard p.count >= 2 else { throw malformed }
                    paths.append(("ball", [(p[0].num, p[1].num, width)]))
                } else if op == 1 && ci < curves.count && !paths.isEmpty {
                    let c = curves[ci].list.first?.list ?? []
                    ci += 1
                    guard c.count >= 4 else { throw malformed }
                    quad(&paths[paths.count - 1].1, (c[0].num, c[1].num, width), (c[2].num, c[3].num, width))
                }
            }
        } else if sig.hasPrefix("vA(v)A(u)A(u)") {
            // Variable width: op 4 starts at (x, y, radius, ...), op 5 is a curve whose control
            // and end point each carry a radius.
            try need(4)
            let ops = v[1].nums ?? [], moves = v[2].nums ?? [], curves = v[3].nums ?? []
            var mi = 0, ci = 0
            for op in ops {
                if op == 4 && mi + 4 <= moves.count {
                    paths.append(("fountain", [(moves[mi], moves[mi + 1], penWidth * moves[mi + 2])]))
                    mi += 4
                } else if op == 5 && ci + 9 <= curves.count && !paths.isEmpty {
                    quad(&paths[paths.count - 1].1, (curves[ci], curves[ci + 1], penWidth * curves[ci + 2]),
                         (curves[ci + 3], curves[ci + 4], penWidth * curves[ci + 5]))
                    ci += 9
                }
            }
        } else if sig.hasPrefix("vuA(v)A(u)A(u)") {
            // A brush stroke, in up to two stretches that share the two arrays. It starts with a
            // taper of overlapping dabs: op 2 is a dab's centre (x, y, size) and op 3 its extent,
            // which adds nothing to the centre line. It may go on at a constant width, op 0 (x, y)
            // and op 1 (control, end), or as a broad nib with a size at every point: op 6
            // (x, y, size, ..) and op 7 (control, end, their sizes, three more numbers).
            try need(5)
            var base = v[1].num
            let ops = v[2].nums ?? [], points = v[3].nums ?? [], curves = v[4].nums ?? []
            // Compared with Goodnotes' own rendering, a dab's size is the width of the line there,
            // and the constant width is the pen's nominal size, which is penWidth times what is
            // drawn. A nib is a slanted edge about three quarters of its size long: the line is
            // as wide as the edge is across the direction of travel, and never thinner than six
            // tenths of it. Where the file gives the edge, each point gets its own width below.
            let k = 1.0
            var nib = 0.74
            if base > 0 { base /= penWidth }
            var edge: (Double, Double)?
            if v.count > 10, let e = v[10].nums, e.count >= 7, e[3] > 0 {
                edge = (e[4], e[5])
                let found = min(1.0, 2 * hypot(e[4], e[5]) / e[3])
                nib = found != 0 ? found : 0.74
            }
            var broad = Set<Int>()   // the paths drawn with the nib
            var pi = 0, ci = 0
            var current: Int?
            var tail: P3?   // where the last dab reaches to, used when nothing follows the taper

            func to(_ x: Double, _ y: Double, _ w: Double) {
                if let c = current {
                    let last = paths[c].1[paths[c].1.count - 1]
                    if abs(last.0 - x) + abs(last.1 - y) > 0.01 { paths[c].1.append((x, y, w)) }
                } else {
                    paths.append(("fountain", [(x, y, w)]))
                    current = paths.count - 1
                }
            }

            for op in ops {
                if op == 2 && pi + 3 <= points.count {
                    to(points[pi], points[pi + 1], k * points[pi + 2])
                    pi += 3
                } else if op == 3 && ci + 6 <= curves.count {
                    tail = (curves[ci + 2], curves[ci + 3], k * curves[ci + 5])
                    ci += 6
                } else if op == 0 && pi + 2 <= points.count {
                    let lastW = current.map { paths[$0].1[paths[$0].1.count - 1].2 }
                    to(points[pi], points[pi + 1], base > 0 ? base : (lastW ?? 1.0))
                    pi += 2
                    tail = nil
                } else if op == 1 && ci + 4 <= curves.count, let c = current {
                    let w = base > 0 ? base : paths[c].1[paths[c].1.count - 1].2
                    quad(&paths[c].1, (curves[ci], curves[ci + 1], w), (curves[ci + 2], curves[ci + 3], w))
                    ci += 4
                } else if op == 6 && pi + 4 <= points.count {
                    let x = points[pi], y = points[pi + 1], r = points[pi + 2]
                    pi += 4
                    if nib < 1, let c = current {   // the taper before it is in the same unit
                        paths[c].1 = paths[c].1.map { ($0.0, $0.1, nib * $0.2) }
                    }
                    to(x, y, nib * r)
                    if let c = current { broad.insert(c) }
                    tail = nil
                } else if op == 7 && ci + 9 <= curves.count, let c = current {
                    quad(&paths[c].1, (curves[ci], curves[ci + 1], nib * curves[ci + 4]), (curves[ci + 2], curves[ci + 3], nib * curves[ci + 5]))
                    ci += 9
                } else {
                    throw Failure("unknown op in a brush stroke")
                }
            }
            if let tail, current != nil { to(tail.0, tail.1, tail.2) }
            if let c = current, paths[c].1.count == 1 {
                let p = paths[c].1[0]
                paths[c].1.append((p.0 + 0.01, p.1, p.2))
            }
            if let edge, hypot(edge.0, edge.1) > 0 {
                let ex = edge.0 / hypot(edge.0, edge.1), ey = edge.1 / hypot(edge.0, edge.1)
                for c in broad {
                    var pts = paths[c].1
                    for i in pts.indices {
                        let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
                        let dx = b.0 - a.0, dy = b.1 - a.1
                        let d = hypot(dx, dy)
                        let across = d > 0 ? abs(ex * dy - ey * dx) / d : 1.0
                        pts[i].2 *= max(0.6, across)
                    }
                    paths[c].1 = pts
                }
            }
        } else if sig.hasPrefix("vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))") {
            // A base width, and points that each carry a factor for it: op 0 starts at
            // (x, y, factor, ..), op 1 is a curve (.., control with its factor, end with its factor).
            try need(5)
            let width = v[1].num, ops = v[2].nums ?? [], moves = v[3].list, curves = v[4].list
            var mi = 0, ci = 0
            for op in ops {
                if op == 0 && mi < moves.count {
                    let p = moves[mi].list.first?.list ?? []
                    mi += 1
                    guard p.count >= 3 else { throw malformed }
                    paths.append(("fountain", [(p[0].num, p[1].num, width * factor(p[2].num))]))
                } else if op == 1 && ci < curves.count && !paths.isEmpty {
                    let c = curves[ci].list.first?.list ?? []
                    ci += 1
                    guard c.count >= 9 else { throw malformed }
                    quad(&paths[paths.count - 1].1, (c[1].num, c[2].num, width * factor(c[3].num)), (c[6].num, c[7].num, width * factor(c[8].num)))
                }
            }
        } else {
            throw Failure("unknown stroke layout " + sig)
        }
        for (_, pts) in paths {
            // Better none than a blot over the page.
            if pts.contains(where: { !(abs($0.0) < 1e7 && abs($0.1) < 1e7 && 0 <= $0.2 && $0.2 < 400) }) { throw Failure("stroke read as nonsense") }
        }
        return paths.filter { !$0.1.isEmpty }
    }

    /// The outline of a recognised shape, which is stored as its geometry instead of as a
    /// drawn path: a polyline, a curve, a rectangle or an ellipse.
    private static func shapePaths(_ shape: Bytes) throws -> [(String, [P3])] {
        let m = try message(shape)
        let w15 = try vec(shape, 15)[14]
        let width = w15 != 0 ? w15 : 2.0
        var pts: [(Double, Double)] = []
        var corners = false
        if m[1] != nil {
            pts = try (try sub(m, 1))[1, default: []].map {
                let p = try vec($0.bytes, 2)
                return (p[0], p[1])
            }
            if pts.count == 1 { pts += pts }
            corners = true
        } else if m[2] != nil {
            // The middle point is taken to be the curve's control point; the file does not say.
            let g = try sub(m, 2)
            let a = try vec(data(g, 1), 2), c = try vec(data(g, 2), 2), b = try vec(data(g, 3), 2)
            for i in 0...16 {
                let t = Double(i) / 16
                pts.append(((1 - t) * (1 - t) * a[0] + 2 * t * (1 - t) * c[0] + t * t * b[0], (1 - t) * (1 - t) * a[1] + 2 * t * (1 - t) * c[1] + t * t * b[1]))
            }
        } else if m[3] != nil {
            let g = try sub(m, 3)
            let c = try vec(data(g, 1), 2), s = try vec(data(g, 2), 2)
            let (cx, cy, w, h) = (c[0], c[1], s[0], s[1])
            pts = [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2), (cx - w / 2, cy - h / 2)]
            corners = true
        } else if m[4] != nil {
            let g = try sub(m, 4)
            let c = try vec(data(g, 1), 2), r = try vec(data(g, 2), 2)
            let turn = try vec(data(m, 4), 3)[2]
            for i in 0...48 {
                let a = Double(i) * 2 * .pi / 48
                let x = r[0] * cos(a), y = r[1] * sin(a)
                pts.append((c[0] + x * cos(turn) - y * sin(turn), c[1] + x * sin(turn) + y * cos(turn)))
            }
        }
        if corners && pts.count > 1 {
            // Inkpad rounds a stroke through its points; a point given twice stays a sharp corner.
            pts = [pts[0]] + pts[1..<(pts.count - 1)].flatMap { [$0, $0] } + [pts[pts.count - 1]]
        }
        let dashed = try sub(m, 5)[1] != nil
        return pts.count > 1 ? [(dashed ? "dash" : "ball", pts.map { ($0.0, $0.1, width) })] : []
    }

    /// An element's bounding box, from its origin and size.
    private static func frame(_ body: Message) throws -> Box {
        let f = try sub(body, 2)
        let o = try vec(data(f, 1), 2), s = try vec(data(f, 2), 2)
        return Box(o[0] - 4, o[1] - 4, o[0] + s[0] + 4, o[1] + s[1] + 4)
    }

    private static func unit(_ c: Double) -> Double { max(0.0, min(1.0, c)) }

    /// Inkpad strokes for one stroke element. `within` drops paths outside a box: a formula's
    /// parts include helper strokes in a coordinate system of their own.
    private static func strokes(_ body: Message, _ scale: Double, dataField: Int = 2, colorField: Int = 4, within: Box? = nil) throws -> [Item] {
        let packed = data(body, dataField)
        if packed.isEmpty { return [] }
        let rgba = try vec(data(body, colorField), 4)
        let color = RGB(unit(rgba[0]), unit(rgba[1]), unit(rgba[2])), alpha = rgba[3]
        let moved = try vec(data(body, 6), 2)   // where the stroke was moved to after it was drawn
        let marker = first(body, 5)?.truthy ?? false   // a highlighter: drawn in full colour, blended under the text
        var out: [Item] = []
        var found = try paths(try decompress(packed))
        if found.isEmpty, first(body, 9)?.truthy ?? false { found = try shapePaths(data(body, 9)) }
        for (tool, raw) in found {
            if let within, !raw.allSatisfy({ within.x0 <= $0.0 && $0.0 <= within.x1 && within.y0 <= $0.1 && $0.1 <= within.y1 }) { continue }
            let pts = raw.map { (($0.0 + moved[0]) * scale, ($0.1 + moved[1]) * scale, $0.2 * scale) }
            let widths = pts.map(\.2)
            let mean = max(0.2, widths.reduce(0, +) / Double(widths.count))
            if marker || alpha < 0.9 {
                out.append(Stroke("hl", color, mean, pts.map { Pt(x: $0.0, y: $0.1, p: 0.5) }))
            } else if tool == "fountain" && (widths.max() ?? 0) - (widths.min() ?? 0) > 0.02 {
                // Inkpad's fountain pen draws width * (0.4 + 1.2 * pressure): turn each width
                // back into the pressure that gives it.
                out.append(Stroke("fountain", color, mean, pts.map { Pt(x: $0.0, y: $0.1, p: unit(($0.2 / mean - 0.4) / 1.2)) }, sens: 1.0))
            } else {
                out.append(Stroke("ball", color, mean, pts.map { Pt(x: $0.0, y: $0.1, p: 0.5) }, dash: tool == "dash" ? 1 : 0))
            }
        }
        return out
    }

    /// The plain text of a compressed rich-text block.
    private static func runs(_ packed: Bytes) throws -> String {
        var text = ""
        for run in try message(try decompress(packed))[1, default: []] { text += Self.text(data(try message(run.bytes), 1)) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    private static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A text box as plain text; its styling is not read.
    private static func textBox(_ body: Message, _ scale: Double) throws -> Item? {
        let content = try sub(body, 32)
        let packed = data(try sub(content, 1), 2)
        let text = packed.isEmpty ? "" : try runs(packed)
        if blank(text) { return nil }
        let at = try vec(data(try sub(body, 20), 1), 2)
        let layout = try sub(body, 21)
        let width = try vec(layout[2] != nil ? data(layout, 2) : data(content, 2), 1)[0]
        let style = try sub(try sub(content, 5), 1)
        let font = style[40] != nil ? float(data(style, 40)) : 18.0
        let pad = 10 * scale   // the box's inner margin
        return TextItem(at[0] * scale + pad, at[1] * scale + pad, text, max(6.0, font * scale), RGB(0.1, 0.1, 0.1),
                        wrap: max(60.0, (width != 0 ? width : 400.0) * scale - 2 * pad))
    }

    /// A comment or sticky note: its text on a slip of its colour.
    private static func sticky(_ body: Message, _ scale: Double) throws -> Item? {
        let packed = data(try sub(try sub(body, 31), 1), 2)
        let text = packed.isEmpty ? "" : try runs(packed)
        if blank(text) { return nil }
        let at = try vec(data(try sub(body, 20), 1), 2)
        let c = try vec(data(body, 30), 3)
        let layout = try sub(body, 21)
        let width = layout[2] != nil ? try vec(data(layout, 2), 1)[0] * scale : 0.0
        return TextItem(at[0] * scale + 8, at[1] * scale + 8, text, 11.0, RGB(0.15, 0.15, 0.15), wrap: max(160.0, width - 16),
                        bg: RGB(unit(c[0]), unit(c[1]), unit(c[2])))
    }

    /// The text of an RTF fragment, without its formatting.
    static func unrtf(_ source: String) throws -> String {
        let rtf = Array(source.unicodeScalars)
        var out: [UInt16] = []
        var i = 0, depth = 0
        var skip: Int?
        func starts(_ prefix: String, _ at: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            return at + p.count <= rtf.count && Array(rtf[at..<(at + p.count)]) == p
        }
        func put(_ s: Unicode.Scalar) { out.append(contentsOf: String(s).utf16) }
        func digit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        while i < rtf.count {
            let c = rtf[i]
            if c == "{" {
                depth += 1
                if skip == nil, ["{\\fonttbl", "{\\colortbl", "{\\*", "{\\stylesheet", "{\\info"].contains(where: { starts($0, i) }) { skip = depth }
                i += 1
            } else if c == "}" {
                if skip == depth { skip = nil }
                depth -= 1
                i += 1
            } else if c == "\\" {
                let j = i + 1
                if j < rtf.count, rtf[j] == "'" {   // \'hh: a byte in the document's code page
                    if skip == nil, j + 3 <= rtf.count, let byte = UInt8(String(String.UnicodeScalarView(rtf[(j + 1)..<(j + 3)])), radix: 16),
                       let s = String(bytes: [byte], encoding: .windowsCP1252) {
                        out.append(contentsOf: s.utf16)
                    }
                    i = j + 3
                } else if j < rtf.count, !rtf[j].properties.isAlphabetic {   // an escaped character, or a line break
                    if skip == nil { put(rtf[j]) }
                    i = j + 1
                } else {
                    var k = j
                    while k < rtf.count, rtf[k].properties.isAlphabetic { k += 1 }
                    let word = String(String.UnicodeScalarView(rtf[j..<k]))
                    var m = k
                    while m < rtf.count, digit(rtf[m]) || rtf[m] == "-" { m += 1 }
                    if skip == nil {
                        if word == "par" || word == "line" {
                            put("\n")
                        } else if word == "tab" {
                            put("\t")
                        } else if word == "u" && m > k {
                            guard let n = Int(String(String.UnicodeScalarView(rtf[k..<m]))) else { throw malformed }
                            out.append(UInt16(((n % 65536) + 65536) % 65536))
                            if m < rtf.count, rtf[m] == " " { m += 1 }
                            if m < rtf.count, !"\\{}".unicodeScalars.contains(rtf[m]) { m += 1 }   // the fallback character
                            i = m
                            continue
                        }
                    }
                    i = m < rtf.count && rtf[m] == " " ? m + 1 : m
                }
            } else {
                if skip == nil && c != "\r" && c != "\n" { put(c) }
                i += 1
            }
        }
        // Characters outside the basic plane arrive as two halves; put them together.
        return String(decoding: out, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An older kind of text box, stored as RTF with its frame.
    private static func rtfBox(_ body: Message, _ scale: Double) throws -> Item? {
        let text = try unrtf(Self.text(data(body, 6)))
        if text.isEmpty { return nil }
        let f = try message(data(body, 3).isEmpty ? data(body, 2) : data(body, 3))
        let at = try vec(data(f, 1), 2)
        let w = try vec(data(f, 2), 2)[0]
        return TextItem(at[0] * scale, at[1] * scale, text, 11.0, RGB(0.1, 0.1, 0.1), wrap: max(60.0, w * scale))
    }

    /// A straight connector between two points.
    private static func line(_ body: Message, _ scale: Double) throws -> Item {
        let geometry = try sub(body, 20)
        let a = try vec(data(geometry, 2), 2)
        let b = try vec(data(try sub(geometry, 3), 1), 2)
        let style = try sub(body, 32)
        let w = try vec(data(body, 32), 1)[0]
        let c = try vec(data(try sub(style, 3), 1), 3)
        return Shape("line", a[0] * scale, a[1] * scale, b[0] * scale, b[1] * scale, RGB(unit(c[0]), unit(c[1]), unit(c[2])),
                     max(0.3, (w != 0 ? w : 2.0) * scale))
    }

    // MARK: the document

    /// A picture file as PNG bytes, which is what Inkpad keeps; nil when it cannot be read.
    private static func toPNG(_ bytes: Data) -> Data? {
        guard let image = UIImage(data: bytes) else { return nil }
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return nil }
        let k = min(1, imageLimit / max(w, h))
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.pngData()
    }

    /// When an element was made: they are numbered in that order.
    private static func made(_ kind: Int, _ body: Message) -> UInt64 {
        guard let stamp = first(body, kind == 1 ? 5 : 7), stamp.isBytes,   // a picture keeps it elsewhere
              let outer = try? message(stamp.bytes), let inner = try? message(data(outer, 1)),
              case .int(let number)? = first(inner, 1) else { return 0 }
        return number
    }

    /// A page's content is stored under its own id with the last byte one higher.
    private static func notesID(_ pageID: String) -> String {
        guard pageID.count >= 2, let last = Int(pageID.suffix(2), radix: 16) else { return pageID }
        return String(pageID.dropLast(2)) + String(format: "%02X", (last + 1) & 0xff)
    }

    /// Read a .goodnotes file: the document, its title and what was read.
    static func load(_ url: URL) throws -> (Document, String, Stats) {
        let notGoodnotes = Failure(tr("不是 Goodnotes 文档"))
        guard let archive = try? ZipReader(url: url) else { throw notGoodnotes }
        let names = Set(archive.names)
        guard names.contains("index.events.pb"), names.contains("index.notes.pb") else { throw notGoodnotes }
        func file(_ name: String) throws -> Bytes { Bytes(try archive.read(name)) }

        var title: String?
        var templates: [String: (String, Int, (Double, Double)?)] = [:]   // id -> (attachment id, PDF page number from 1, size)
        var pages: [String: (template: String?, key: String, order: Int)] = [:]
        for record in records(try file("index.events.pb")) {
            guard let all = try? fields(record) else { continue }
            for (number, wire, value) in all where wire == 2 && number != 1 {
                guard let m = try? message(value.bytes) else { continue }
                switch number {
                case 30:
                    let found = text(data((try? sub(m, 2)) ?? [:], 1))
                    if !found.isEmpty { title = found }
                case 2:
                    let size = (try? vec(data(m, 8), 2)) ?? [0, 0]
                    var page = 1
                    if case .int(let n)? = first(m, 5) { page = Int(truncatingIfNeeded: n) }
                    templates[text(data(m, 2))] = (text(data(m, 4)), page, size[0] > 0 && size[1] > 0 ? (size[0], size[1]) : nil)
                case 54:
                    let id = text(data(m, 2))
                    var page = pages[id] ?? (nil, "", pages.count)
                    let template = text(data((try? sub(m, 3)) ?? [:], 1)), key = text(data((try? sub(m, 4)) ?? [:], 1))
                    if !template.isEmpty { page.template = template }
                    if !key.isEmpty { page.key = key }
                    pages[id] = page
                case 55:
                    // A page that was moved gets a new sort key.
                    let key = text(data((try? sub(m, 3)) ?? [:], 1)), id = text(data(m, 2))
                    if !key.isEmpty, pages[id] != nil { pages[id]?.key = key }
                default:
                    break
                }
            }
        }

        func table(_ name: String) throws -> [String: String] {
            var out: [String: String] = [:]
            for record in records(try file(name)) {
                let m = try message(record)
                out[text(data(m, 1))] = text(data(m, 2))
            }
            return out
        }
        let files = try table("index.notes.pb")
        let attachments = names.contains("index.attachments.pb") ? try table("index.attachments.pb") : [:]

        var pdfs: [String: PdfDoc?] = [:]
        func pdf(for attachment: String) -> PdfDoc? {
            if let known = pdfs[attachment] { return known }
            var found: PdfDoc?
            if let name = attachments[attachment], names.contains(name), let bytes = try? archive.read(name), bytes.prefix(5) == Data("%PDF-".utf8) {
                found = try? PdfDoc(bytes)
            }
            pdfs[attachment] = .some(found)
            return found
        }

        let doc = Document()
        doc.pages = []
        var stats = Stats()
        let ordered = pages.sorted { $0.value.key != $1.value.key ? $0.value.key < $1.value.key : $0.value.order < $1.value.order }
        for (pageID, info) in ordered {
            let (attachment, number, size) = templates[info.template ?? ""] ?? ("", 1, nil)
            let page: Page
            let scale: Double
            if !attachment.isEmpty, let pdf = pdf(for: attachment), 1 <= number, number <= pdf.nPages {
                let (w, h) = pdf.pageSize(number - 1)
                page = Page(w, h, pdf: pdf, pdfPage: number - 1)
                scale = size.map { $0.0 > 0 ? w / $0.0 : fallbackScale } ?? fallbackScale
            } else if let size {
                scale = fallbackScale
                page = Page(size.0 * scale, size.1 * scale)
            } else {
                // No template and no size: a whiteboard, which has no edges in Inkpad either.
                scale = fallbackScale
                page = Page(boardSize.0, boardSize.1, paper: "dots", board: true)
            }

            // Element id -> (kind, body); a later record replaces an earlier one.
            var elements: [String: (Int, Message, Int)] = [:]
            if let name = files[notesID(pageID)] ?? files[pageID], names.contains(name) {
                for record in records(try file(name)) {
                    guard let all = try? fields(record), let (number, wire, value) = all.first, wire == 2, !(number == 1 && all.count > 1),   // the header that precedes each element
                          let body = try? message(value.bytes) else { continue }
                    if number == 1 && !(first(body, 1)?.isBytes ?? false) { continue }
                    let id = text(data(body, 1))
                    elements[id] = (number, body, elements[id]?.2 ?? elements.count)
                }
            }
            // Elements are numbered as they were made; later ones lie on top of earlier ones.
            let sorted = elements.values.map { ($0.0, $0.1, made($0.0, $0.1), $0.2) }.sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.3 < $1.3 }
            for (kind, body, _, _) in sorted {
                if first(body, 14)?.truthy ?? false { continue }   // erased or removed
                do {
                    switch kind {
                    case 7:
                        let found = try strokes(body, scale)
                        page.items += found
                        stats.strokes += found.count
                    case 21, 20, 8:
                        if let item = try kind == 21 ? textBox(body, scale) : kind == 20 ? sticky(body, scale) : rtfBox(body, scale) {
                            page.items.append(item)
                            stats.texts += 1
                        }
                    case 11:
                        // Handwriting that Goodnotes shows typeset as a formula. Inkpad cannot
                        // typeset, so the handwriting it was made from is kept instead.
                        if first(body, 6)?.truthy ?? false { continue }   // a conversion that was undone: its handwriting is on the page as strokes
                        for part in body[11, default: []] {
                            let found = try strokes(try message(part.bytes), scale, dataField: 1, colorField: 2, within: try frame(body))
                            page.items += found
                            stats.strokes += found.count
                        }
                        stats.formulas += 1
                    case 1:
                        let f = try sub(body, 2)
                        let size = try vec(data(f, 2), 2)
                        if max(size[0], size[1]) < 1 { continue }   // a speck too small to see, which Goodnotes leaves as a marker
                        let at = try vec(data(f, 1), 2)
                        if let name = attachments[text(data(body, 4))], names.contains(name), size[0] > 0, size[1] > 0,
                           let png = toPNG(try archive.read(name)) {
                            page.items.append(ImageItem(at[0] * scale, at[1] * scale, size[0] * scale, size[1] * scale, ImageData(png)))
                            stats.images += 1
                        } else {
                            stats.skipped += 1
                        }
                    case 9:
                        break   // a region marked for some tool; it shows nothing on the page
                    case 22:
                        page.items.append(try line(body, scale))
                        stats.shapes += 1
                    default:
                        stats.skipped += 1
                    }
                } catch {
                    stats.skipped += 1
                }
            }
            doc.pages.append(page)
        }

        // Inkpad treats a document as either pages or whiteboards, going by its first page.
        if let lead = doc.pages.first?.board, doc.pages.contains(where: { $0.board != lead }) {
            doc.pages = doc.pages.filter { $0.board == lead }
        }
        if doc.pages.isEmpty { throw Failure(tr("这个 Goodnotes 文档里没有可以读取的页面")) }
        doc.rev = 1   // not on disk yet
        return (doc, title ?? url.deletingPathExtension().lastPathComponent, stats)
    }

    // MARK: writing
    //
    // Experimental. The records below copy the shape of what Goodnotes itself writes, but the
    // meaning of several of their fields (the counters and hashes that look like sync clocks)
    // is a guess, and no Goodnotes app was available to open the result. What is certain is
    // only that load() reads it back.

    private static func enc(_ value: UInt64) -> Bytes {
        var n = value
        var out: Bytes = []
        while true {
            let b = UInt8(n & 0x7f)
            n >>= 7
            if n != 0 {
                out.append(b | 0x80)
            } else {
                out.append(b)
                return out
            }
        }
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> Bytes { withUnsafeBytes(of: v.littleEndian) { Bytes($0) } }

    private static func f(_ number: Int, _ value: Int) -> Bytes { enc(UInt64(number) << 3) + enc(UInt64(value)) }
    private static func f(_ number: Int, _ value: UInt64) -> Bytes { enc(UInt64(number) << 3) + enc(value) }
    private static func f(_ number: Int, _ value: Float) -> Bytes { enc(UInt64(number) << 3 | 5) + le(value.bitPattern) }
    private static func f(_ number: Int, _ value: Bytes) -> Bytes { enc(UInt64(number) << 3 | 2) + enc(UInt64(value.count)) + value }
    private static func f(_ number: Int, _ value: String) -> Bytes { f(number, Bytes(value.utf8)) }
    private static func f64(_ number: Int, _ value: Double) -> Bytes { enc(UInt64(number) << 3 | 1) + le(value.bitPattern) }
    private static func record(_ message: Bytes) -> Bytes { enc(UInt64(message.count)) + message }
    private static func stamp(_ counter: Int = 1) -> Bytes { f(1, counter) + f(2, UInt64(UInt32.random(in: 0...UInt32.max))) }
    private static func newID() -> String { UUID().uuidString.uppercased() }

    /// A constant-width path in the simplest of the layouts, stored uncompressed.
    private static func packStroke(_ points: [(Double, Double)], _ width: Double) -> Bytes {
        func fl(_ v: Double) -> Bytes { le(Float(v).bitPattern) }
        var body = le(UInt16(2)) + fl(width)
        body += le(UInt32(points.count)) + le(UInt16(0))
        for _ in 1..<points.count { body += le(UInt16(1)) }
        body += le(UInt32(1)) + fl(points[0].0) + fl(points[0].1)
        body += le(UInt32(points.count - 1))
        for (a, b) in zip(points, points.dropFirst()) {
            // A straight piece as a curve whose control point is its middle.
            body += fl((a.0 + b.0) / 2) + fl((a.1 + b.1) / 2) + fl(b.0) + fl(b.1)
        }
        body += le(UInt16(1)) + le(UInt32(0))
        let sig = Bytes("vuA(v)A(S(uu))A(S(uuuu))vA(f)".utf8) + [0]
        let raw = Bytes("tpl".utf8) + [0] + le(UInt32(8 + sig.count + body.count)) + sig + body
        return Bytes("bv4-".utf8) + le(UInt32(raw.count)) + raw + Bytes("bv4$".utf8)
    }

    /// Write an Inkpad document as a .goodnotes file (experimental, see above).
    ///
    /// Each page's paper, PDF, pictures, shapes and text go into one background PDF; pen and
    /// highlighter strokes are written as strokes, at their average width.
    static func save(_ doc: Document, to url: URL, title: String) throws {
        let now = Date().timeIntervalSince1970
        let device = UInt64.random(in: 0..<(1 << 62))
        var clock = UInt64(now * 1000)
        func tick() -> UInt64 {
            clock += 1
            return clock
        }
        let docID = newID(), attachment = newID()
        let up = 1 / fallbackScale   // Goodnotes lays pages out this much larger than their PDF

        // The background of every page, without its strokes, as one PDF.
        let snaps = doc.pages.map { $0.snap }
        var boxes: [(Double, Double, Double, Double, Double)] = []
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for snap in snaps {
                let b = snap.box
                let k = min(1.0, 14400 / max(b.w, b.h))
                boxes.append((b.x0, b.y0, k, b.w * k, b.h * k))
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: b.w * k, height: b.h * k), pageInfo: [:])
                let g = ctx.cgContext
                g.scaleBy(x: k, y: k)
                g.translateBy(x: -b.x0, y: -b.y0)
                let rest = PageSnap(w: snap.w, h: snap.h, paper: snap.paper, color: snap.color, board: snap.board, pdf: snap.pdf,
                                    pdfPage: snap.pdfPage, rot: snap.rot, items: snap.items.filter { $0.kind != "s" })
                renderPage(g, rest, printing: true)
            }
        }

        var events = record(f(1, docID) + f(30, f(1, docID) + f(2, f(1, title) + f(2, stamp())) + f(6, f(1, "P") + f(2, stamp()))
            + f(9, "en_US") + f64(10, now * 1000) + f(11, newID()) + f(13, device) + f(14, tick())
            + f(17, Bytes()) + f(18, Bytes()) + f(19, f(2, stamp())) + f(20, 24)))
        events += record(f(1, attachment) + f(6, f(1, attachment) + f(2, attachment) + f(5, pdf.count) + f(6, docID) + f64(10, now * 1000)
            + f(11, newID()) + f(12, f(1, 1) + f(2, 1)) + f(14, device) + f(15, tick()) + f(16, 24)))

        var notesIndex: Bytes = []
        var files: [(String, Bytes)] = []
        for (n, (snap, box)) in zip(snaps, boxes).enumerated() {
            let (bx, by, k, pw, ph) = box
            let template = newID()
            var pageID = newID()
            pageID = String(pageID.dropLast(2)) + String(format: "%02X", (Int(pageID.suffix(2), radix: 16) ?? 0) & 0xfe)   // so that +1 does not wrap
            events += record(f(1, template) + f(2, f(1, docID) + f(2, template) + f(4, attachment) + f(5, n + 1) + f(6, 1)
                + f(8, f(1, Float(pw * up)) + f(2, Float(ph * up))) + f64(10, now * 1000) + f(11, newID())
                + f(12, f(2, stamp())) + f(13, f(2, stamp())) + f(15, device) + f(16, tick())
                + f(17, f(1, 1) + f(2, stamp())) + f(19, f(2, stamp())) + f(21, 24)))
            events += record(f(1, pageID) + f(54, f(1, docID) + f(2, pageID) + f(3, f(1, template) + f(2, stamp()))
                + f(4, f(1, String(format: "P%06d", n)) + f(2, stamp())) + f64(10, now * 1000) + f(11, newID())
                + f(13, device) + f(14, tick()) + f(15, 24)))

            var body: Bytes = []
            var counter = 1_000_000
            for item in snap.items {
                guard let it = item as? Stroke, !it.pts.isEmpty else { continue }
                var pts = it.pts.map { (($0.x - bx) * k * up, ($0.y - by) * k * up) }
                if pts.count == 1 { pts.append((pts[0].0 + 0.01, pts[0].1)) }
                let width = it.pts.reduce(0) { $0 + it.wAt($1.p) } / Double(it.pts.count) * k * up
                let sid = newID(), mark = stamp(2)
                counter += 1
                body += record(f(1, sid) + f(2, mark) + f(6, sid) + f(8, device) + f(9, counter) + f(14, 5381) + f(16, 24))
                let color = f(1, Float(it.color.r)) + f(2, Float(it.color.g)) + f(3, Float(it.color.b)) + f(4, Float(it.tool == "hl" ? 0.5 : 1.0))
                body += record(f(7, f(1, sid) + f(2, packStroke(pts, width)) + f(4, color) + f(6, Bytes())
                    + f(7, f(1, stamp(pts.count))) + f(9, Bytes()) + f(15, mark) + f(20, Bytes()) + f(21, 24)))
            }
            let notes = notesID(pageID)
            files.append(("notes/" + notes, body))
            notesIndex += record(f(1, notes) + f(2, "notes/" + notes))
        }

        let zip = try ZipWriter(url: url)
        do {
            try zip.add("document.info.pb", Data())
            try zip.add("schema.pb", Data(f(1, 25)))
            try zip.add("index.events.pb", Data(events))
            try zip.add("index.notes.pb", Data(notesIndex))
            try zip.add("index.search.pb", Data())
            try zip.add("index.attachments.pb", Data(record(f(1, attachment) + f(2, "attachments/" + attachment))))
            try zip.add("attachments/" + attachment, pdf)
            for (name, bytes) in files { try zip.add(name, Data(bytes)) }
            if let jpeg = UIImage(data: doc.cover())?.jpegData(compressionQuality: 0.85) { try zip.add("thumbnail.jpg", jpeg) }
            try zip.finish()
        } catch {
            zip.abandon()
            throw error
        }
    }
}
