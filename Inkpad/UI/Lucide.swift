import SwiftUI

/// The desktop app's icons: glyphs from the Lucide set (https://lucide.dev, ISC licence),
/// kept as the same SVG path data and drawn here, so both apps show identical icons.
enum Lucide {
    struct Glyph {
        let path: Path   // in the 24-unit Lucide grid
        let fill: Bool
    }

    private static let tables: (icons: [String: Glyph], glyphs: [String: Glyph]) = {
        guard let url = Bundle.main.url(forResource: "icons", withExtension: "json"), let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([:], [:]) }
        var icons: [String: Glyph] = [:], glyphs: [String: Glyph] = [:]
        for (name, value) in json["icons"] as? [String: [String: Any]] ?? [:] {
            icons[name] = Glyph(path: build(value["els"] as? [Any] ?? []), fill: value["fill"] as? Bool ?? false)
        }
        for (name, value) in json["glyphs"] as? [String: [Any]] ?? [:] {
            glyphs[name] = Glyph(path: build(value), fill: false)
        }
        return (icons, glyphs)
    }()

    static func icon(_ name: String) -> Glyph? { tables.icons[name] }
    static func folderGlyph(_ name: String) -> Glyph? { tables.glyphs[name] }
    static var folderGlyphNames: [String] { tables.glyphs.keys.sorted() }

    /// Elements are path strings, ["rect", x, y, w, h, r] or ["circle", x, y, r].
    private static func build(_ elements: [Any]) -> Path {
        var p = Path()
        for el in elements {
            if let d = el as? String {
                svg(d, into: &p)
            } else if let a = el as? [Any], let kind = a.first as? String {
                let v = a.dropFirst().map { CGFloat(num($0)) }
                if kind == "rect", v.count >= 5 {
                    p.addRoundedRect(in: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), cornerSize: CGSize(width: v[4], height: v[4]), style: .circular)
                } else if v.count >= 3 {
                    p.addEllipse(in: CGRect(x: v[0] - v[2], y: v[1] - v[2], width: 2 * v[2], height: 2 * v[2]))
                }
            }
        }
        return p
    }

    private static let token = try! NSRegularExpression(pattern: "([MmLlHhVvCcSsQqAaZz])|([-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?)")
    private static let arity: [Character: Int] = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "A": 7, "Z": 0]

    private static func svg(_ d: String, into p: inout Path) {
        let ns = d as NSString
        var tokens: [(cmd: Character?, value: CGFloat)] = []
        for m in token.matches(in: d, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                tokens.append((Character(ns.substring(with: m.range(at: 1))), 0))
            } else {
                tokens.append((nil, CGFloat(Double(ns.substring(with: m.range(at: 2))) ?? 0)))
            }
        }
        var i = 0
        var x: CGFloat = 0, y: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0
        var lastC: CGPoint?   // previous cubic control point, for S
        var cmd: Character = "M"
        while i < tokens.count {
            if let c = tokens[i].cmd {
                cmd = c
                i += 1
            }
            let up = Character(cmd.uppercased())
            let rel = cmd != up
            let n = arity[up] ?? 0
            guard i + n <= tokens.count else { break }
            let a = (0..<n).map { tokens[i + $0].value }
            i += n
            let ox = rel ? x : 0, oy = rel ? y : 0
            var ctrl: CGPoint?
            switch up {
            case "M":
                x = a[0] + ox; y = a[1] + oy
                sx = x; sy = y
                p.move(to: CGPoint(x: x, y: y))
                cmd = rel ? "l" : "L"   // further pairs are line-tos
            case "L":
                x = a[0] + ox; y = a[1] + oy
                p.addLine(to: CGPoint(x: x, y: y))
            case "H":
                x = a[0] + ox
                p.addLine(to: CGPoint(x: x, y: y))
            case "V":
                y = a[0] + oy
                p.addLine(to: CGPoint(x: x, y: y))
            case "C":
                p.addCurve(to: CGPoint(x: a[4] + ox, y: a[5] + oy), control1: CGPoint(x: a[0] + ox, y: a[1] + oy),
                           control2: CGPoint(x: a[2] + ox, y: a[3] + oy))
                ctrl = CGPoint(x: a[2] + ox, y: a[3] + oy)
                x = a[4] + ox; y = a[5] + oy
            case "S":
                let c1 = lastC.map { CGPoint(x: 2 * x - $0.x, y: 2 * y - $0.y) } ?? CGPoint(x: x, y: y)
                p.addCurve(to: CGPoint(x: a[2] + ox, y: a[3] + oy), control1: c1, control2: CGPoint(x: a[0] + ox, y: a[1] + oy))
                ctrl = CGPoint(x: a[0] + ox, y: a[1] + oy)
                x = a[2] + ox; y = a[3] + oy
            case "Q":
                p.addQuadCurve(to: CGPoint(x: a[2] + ox, y: a[3] + oy), control: CGPoint(x: a[0] + ox, y: a[1] + oy))
                x = a[2] + ox; y = a[3] + oy
            case "A":
                let ex = a[5] + ox, ey = a[6] + oy
                arc(&p, x, y, a[0], a[1], a[2], a[3] != 0, a[4] != 0, ex, ey)
                x = ex; y = ey
            default:
                p.closeSubpath()
                x = sx; y = sy
            }
            lastC = ctrl
            if up == "Z", i < tokens.count, tokens[i].cmd == nil { break }
        }
    }

    /// An SVG elliptical arc from the current point (x1, y1) to (x2, y2).
    private static func arc(_ p: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ rxIn: CGFloat, _ ryIn: CGFloat, _ degrees: CGFloat,
                            _ large: Bool, _ sweep: Bool, _ x2: CGFloat, _ y2: CGFloat) {
        if rxIn == 0 || ryIn == 0 || (x1 == x2 && y1 == y2) {
            p.addLine(to: CGPoint(x: x2, y: y2))
            return
        }
        let phi = degrees * .pi / 180
        let cosp = cos(phi), sinp = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let xp = cosp * dx + sinp * dy, yp = -sinp * dx + cosp * dy
        var rx = abs(rxIn), ry = abs(ryIn)
        let lam = xp * xp / (rx * rx) + yp * yp / (ry * ry)
        if lam > 1 {
            rx *= sqrt(lam)
            ry *= sqrt(lam)
        }
        let top = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
        let den = rx * rx * yp * yp + ry * ry * xp * xp
        let k = sqrt(max(0, top / den)) * (large == sweep ? -1 : 1)
        let cxp = k * rx * yp / ry, cyp = -k * ry * xp / rx
        let cx = cosp * cxp - sinp * cyp + (x1 + x2) / 2, cy = sinp * cxp + cosp * cyp + (y1 + y2) / 2
        let a1 = atan2((yp - cyp) / ry, (xp - cxp) / rx), a2 = atan2((-yp - cyp) / ry, (-xp - cxp) / rx)
        let t = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
        p.addArc(center: .zero, radius: 1, startAngle: .radians(a1), endAngle: .radians(a2), clockwise: !sweep, transform: t)
    }

    /// The outline to fill for an icon drawn `size` points across.
    static func outline(_ glyph: Glyph, size: CGFloat, weight: CGFloat = 2) -> Path {
        let k = size / 24
        let scaled = glyph.path.applying(CGAffineTransform(scaleX: k, y: k))
        var out = scaled.strokedPath(StrokeStyle(lineWidth: weight * k, lineCap: .round, lineJoin: .round))
        if glyph.fill { out.addPath(scaled) }
        return out
    }

    /// The icon as a template image, for UIKit controls.
    static func image(_ name: String, size: CGFloat = 20) -> UIImage? {
        guard let glyph = icon(name) else { return nil }
        let path = outline(glyph, size: size).cgPath
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            ctx.cgContext.addPath(path)
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// One of the desktop app's icons, in the current foreground colour.
struct Icon: View {
    let name: String
    var size: CGFloat = 20

    init(_ name: String, _ size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Group {
            if let glyph = Lucide.icon(name) {
                Lucide.outline(glyph, size: size).fill(.foreground)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}

/// Small drawn marks the option bar uses, each in a 20-unit box like the desktop's.
struct Mark: View {
    enum Kind {
        case weight(Double)          // a line of this thickness
        case dot(Double)             // a ring of this radius
        case letter(Double)          // an "A" at this scale
        case lineStyle(Int)          // solid, dashed, dotted
    }

    let kind: Kind
    var size: CGFloat = 20

    var body: some View {
        Canvas { g, _ in
            g.scaleBy(x: size / 20, y: size / 20)
            var p = Path()
            var style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            switch kind {
            case .weight(let w):
                p.move(to: CGPoint(x: 4, y: 10))
                p.addLine(to: CGPoint(x: 16, y: 10))
                style.lineWidth = w
            case .dot(let r):
                p.addEllipse(in: CGRect(x: 10 - r, y: 10 - r, width: 2 * r, height: 2 * r))
            case .letter(let s):
                p.move(to: CGPoint(x: -5, y: 6))
                p.addLine(to: CGPoint(x: 0, y: -6))
                p.addLine(to: CGPoint(x: 5, y: 6))
                p.move(to: CGPoint(x: -3.2, y: 2))
                p.addLine(to: CGPoint(x: 3.2, y: 2))
                p = p.applying(CGAffineTransform(translationX: 10, y: 10.5).scaledBy(x: s, y: s))
                style.lineWidth = 1.5
            case .lineStyle(let dash):
                p.move(to: CGPoint(x: 2.5, y: 10))
                p.addLine(to: CGPoint(x: 17.5, y: 10))
                style.lineWidth = 1.8
                if dash == 1 { style.dash = [4, 3.2] } else if dash == 2 { style.dash = [0.01, 3.6] }
            }
            g.stroke(p, with: .foreground, style: style)
        }
        .frame(width: size, height: size)
    }
}

/// A colour slot. The chosen one carries a chevron: press it again to change it.
struct Swatch: View {
    let color: RGB
    var chevron = false
    var size: CGFloat = 22

    var body: some View {
        Canvas { g, _ in
            g.scaleBy(x: size / 20, y: size / 20)
            let disc = Path(ellipseIn: CGRect(x: 2, y: 2, width: 16, height: 16))
            g.fill(disc, with: .color(color.color))
            g.stroke(disc, with: .color(.black.opacity(0.16)), lineWidth: 1)
            if chevron {
                var v = Path()
                v.move(to: CGPoint(x: 7, y: 9))
                v.addLine(to: CGPoint(x: 10, y: 12))
                v.addLine(to: CGPoint(x: 13, y: 9))
                g.stroke(v, with: .color(color.luma < 0.6 ? .white.opacity(0.95) : .black.opacity(0.6)),
                         style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The rainbow disc that stands for "any colour".
struct ColorWheel: View {
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(AngularGradient(gradient: Gradient(colors: (0...24).map { Color(hue: Double($0) / 24, saturation: 0.9, brightness: 1) }), center: .center))
            .overlay(Circle().fill(.white).frame(width: size * 0.3, height: size * 0.3))
            .frame(width: size * 0.8, height: size * 0.8)
            .frame(width: size, height: size)
    }
}
