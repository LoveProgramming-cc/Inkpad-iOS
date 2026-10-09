import UIKit

let coverStyles = ["simple", "label", "ribbon", "band", "grid"]
let coverColors = [RGB(0.69, 0.61, 0.50), RGB(0.13, 0.15, 0.27), RGB(0.17, 0.27, 0.45), RGB(0.24, 0.46, 0.38),
                   RGB(0.70, 0.26, 0.26), RGB(0.33, 0.34, 0.37), RGB(0.93, 0.75, 0.30), RGB(0.89, 0.89, 0.88)]

/// A notebook cover in one of coverStyles, carrying the title.
func renderCover(_ spec: (String, RGB), title: String, w: Double = 225, h: Double = 300) -> UIImage {
    let (style, color) = spec
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
        let g = ctx.cgContext
        let light = color.luma > 0.6
        let ink = light ? RGB(0.12, 0.12, 0.14) : RGB.white
        let dark = color.scaled(0.78)
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        func text(_ x: Double, _ y: Double, _ size: Double, _ width: Double, _ c: RGB, _ alpha: Double = 0.92) {
            TextLayout.show(g, x, y, title, size, width, c.ui.withAlphaComponent(alpha))
        }
        func round(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, _ r: Double) -> CGPath {
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: rw, height: rh), cornerRadius: r).cgPath
        }
        g.setFillColor(color.cg())
        g.fill(full)
        switch style {
        case "grid":
            g.setStrokeColor(ink.cg(0.10))
            g.setLineWidth(0.6)
            let step = w / 12
            for i in 1..<12 {
                g.move(to: CGPoint(x: Double(i) * step, y: 0))
                g.addLine(to: CGPoint(x: Double(i) * step, y: h))
            }
            for i in 1...Int(h / step) {
                g.move(to: CGPoint(x: 0, y: Double(i) * step))
                g.addLine(to: CGPoint(x: w, y: Double(i) * step))
            }
            g.strokePath()
            g.setFillColor((light ? RGB.white : dark).cg())
            g.fill(CGRect(x: w * 0.14, y: h * 0.12, width: w * 0.72, height: h * 0.20))
            text(w * 0.19, h * 0.17, w * 0.075, w * 0.62, light ? RGB(0.12, 0.12, 0.14) : .white)
        case "band":
            g.setFillColor(dark.cg())
            g.fill(CGRect(x: 0, y: h * 0.66, width: w, height: h * 0.34))
            g.setFillColor(ink.cg(0.5))
            g.fill(CGRect(x: w * 0.14, y: h * 0.33, width: w * 0.16, height: 2.2))
            text(w * 0.14, h * 0.37, w * 0.09, w * 0.76, ink)
        case "ribbon":
            // A loose ribbon looping across the cover, with a label for the title.
            let accent = light ? color.scaled(0.55) : RGB(0.22, 0.70, 0.84)
            g.setLineCap(.round)
            g.setLineWidth(w * 0.085)
            g.setStrokeColor(accent.cg())
            g.move(to: CGPoint(x: w * 0.20, y: -h * 0.05))
            g.addCurve(to: CGPoint(x: w * 0.52, y: h * 0.36), control1: CGPoint(x: -w * 0.10, y: h * 0.30), control2: CGPoint(x: w * 0.45, y: h * 0.52))
            g.addCurve(to: CGPoint(x: w * 0.42, y: h * 0.52), control1: CGPoint(x: w * 0.58, y: h * 0.22), control2: CGPoint(x: w * 0.30, y: h * 0.24))
            g.addCurve(to: CGPoint(x: w * 1.08, y: h * 0.98), control1: CGPoint(x: w * 0.60, y: h * 0.92), control2: CGPoint(x: w * 0.95, y: h * 0.70))
            g.strokePath()
            g.setFillColor(RGB.white.cg())
            g.addPath(round(w * 0.16, h * 0.39, w * 0.68, h * 0.21, 4))
            g.fillPath()
            text(w * 0.21, h * 0.425, w * 0.07, w * 0.58, RGB(0.12, 0.12, 0.14))
        case "label":
            g.setStrokeColor(ink.cg(0.28))
            g.setLineWidth(1)
            g.stroke(CGRect(x: w * 0.09, y: h * 0.05, width: w * 0.84, height: h * 0.90))
            g.setFillColor(RGB(0.98, 0.97, 0.94).cg())
            g.addPath(round(w * 0.20, h * 0.26, w * 0.62, h * 0.24, 3))
            g.fillPath()
            g.setStrokeColor(RGB.black.cg(0.25))
            g.setLineWidth(0.8)
            g.addPath(round(w * 0.225, h * 0.275, w * 0.57, h * 0.21, 2))
            g.strokePath()
            text(w * 0.26, h * 0.32, w * 0.072, w * 0.50, RGB(0.12, 0.12, 0.14))
        default:
            let left = w * 0.15
            text(left, h * 0.13, w * 0.075, w * 0.75, ink)
            g.setStrokeColor(ink.cg(0.35))
            g.setLineWidth(1)
            g.move(to: CGPoint(x: left, y: h * 0.30))
            g.addLine(to: CGPoint(x: w * 0.9, y: h * 0.30))
            for i in 0..<3 {
                g.move(to: CGPoint(x: w * 0.72, y: h * (0.84 + Double(i) * 0.03)))
                g.addLine(to: CGPoint(x: w * 0.9, y: h * (0.84 + Double(i) * 0.03)))
            }
            g.strokePath()
        }
        // Shared finish: a soft sheen and the pale spine.
        let colors = [UIColor(white: 1, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0.10).cgColor] as CFArray
        if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            g.drawLinearGradient(sheen, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        g.setFillColor(UIColor(white: 1, alpha: 0.92).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: w * 0.045, height: h))
        g.setFillColor(UIColor(white: 0, alpha: 0.16).cgColor)
        g.fill(CGRect(x: w * 0.045, y: 0, width: 1.5, height: h))
    }
}
