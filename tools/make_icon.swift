// Draws the app icon (the desktop app's SVG, full bleed) to a 1024 px PNG.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let g = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
g.setFillColor(rgb(0x36609f))
g.fill(CGRect(x: 0, y: 0, width: size, height: size))
// SVG units: the badge spans 12...116; flip to a top-left origin.
let k = CGFloat(size) / 104
g.translateBy(x: 0, y: CGFloat(size))
g.scaleBy(x: k, y: -k)
g.translateBy(x: -12, y: -12)
g.setFillColor(rgb(0xffffff))
g.addPath(CGPath(roundedRect: CGRect(x: 34, y: 24, width: 60, height: 80), cornerWidth: 6, cornerHeight: 6, transform: nil))
g.fillPath()
g.setStrokeColor(rgb(0x4a9ef5))
g.setLineWidth(5)
g.setLineCap(.round)
g.move(to: CGPoint(x: 44, y: 84))
g.addCurve(to: CGPoint(x: 64, y: 82), control1: CGPoint(x: 52, y: 74), control2: CGPoint(x: 56, y: 92))
g.addCurve(to: CGPoint(x: 82, y: 70), control1: CGPoint(x: 72, y: 72), control2: CGPoint(x: 74, y: 76))
g.strokePath()
g.setLineJoin(.round)
g.setLineWidth(3)
g.setFillColor(rgb(0xffb02e))
g.setStrokeColor(rgb(0x2c4a7c))
let pencil = [(96, 30), (106, 40), (72, 74), (59, 77), (62, 64)].map { CGPoint(x: $0.0, y: $0.1) }
g.addLines(between: pencil)
g.closePath()
g.drawPath(using: .fillStroke)
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, g.makeImage()!, nil)
CGImageDestinationFinalize(dest)
