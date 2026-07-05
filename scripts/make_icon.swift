// Render the Sauron app icon (the Eye, over a ghost treemap) to a PNG.
// Usage: swift scripts/make_icon.swift <out.png> [size]
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024

let S = CGFloat(size)
let scale = S / 1024.0
func px(_ v: CGFloat) -> CGFloat { v * scale }

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// ---- Tile: macOS-style rounded square with margin ----
let margin = px(100)
let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let corner = tile.width * 0.224
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Background: deep charcoal, slightly blue, vertical gradient.
let bgGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(0.16, 0.15, 0.19, 1), rgba(0.05, 0.045, 0.07, 1)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: tile.midX, y: tile.maxY),
                       end: CGPoint(x: tile.midX, y: tile.minY), options: [])

// Ghost treemap: faint tiles in the background.
let cuts: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.00, 0.00, 0.58, 0.55), (0.00, 0.55, 0.58, 0.30), (0.00, 0.85, 0.58, 0.15),
    (0.58, 0.00, 0.42, 0.38), (0.58, 0.38, 0.42, 0.36), (0.58, 0.74, 0.24, 0.26),
    (0.82, 0.74, 0.18, 0.26),
]
for (i, c) in cuts.enumerated() {
    let r = CGRect(x: tile.minX + c.0 * tile.width,
                   y: tile.minY + c.1 * tile.height,
                   width: c.2 * tile.width,
                   height: c.3 * tile.height).insetBy(dx: px(3), dy: px(3))
    ctx.setFillColor(rgba(1, 0.75, 0.55, i % 2 == 0 ? 0.030 : 0.015))
    ctx.fill(r)
    ctx.setStrokeColor(rgba(1, 0.85, 0.7, 0.06))
    ctx.setLineWidth(px(2))
    ctx.stroke(r)
}

let cx = tile.midX
let cy = tile.midY

// ---- Outer glow ----
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(1.0, 0.45, 0.10, 0.55), rgba(0.95, 0.25, 0.05, 0.22), rgba(0.6, 0.08, 0.02, 0.0)] as CFArray,
    locations: [0, 0.45, 1])!
ctx.saveGState()
ctx.translateBy(x: cx, y: cy)
ctx.scaleBy(x: 1.0, y: 0.72)
ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0,
                       endCenter: .zero, endRadius: px(430), options: [])
ctx.restoreGState()

// ---- Eye almond ----
func almond(cx: CGFloat, cy: CGFloat, halfWidth: CGFloat, controlHeight: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - halfWidth, y: cy))
    p.addQuadCurve(to: CGPoint(x: cx + halfWidth, y: cy),
                   control: CGPoint(x: cx, y: cy + controlHeight))
    p.addQuadCurve(to: CGPoint(x: cx - halfWidth, y: cy),
                   control: CGPoint(x: cx, y: cy - controlHeight))
    p.closeSubpath()
    return p
}

let eyePath = almond(cx: cx, cy: cy, halfWidth: px(300), controlHeight: px(310))

// Fiery iris: yellow core -> orange -> deep red rim, elliptical.
ctx.saveGState()
ctx.addPath(eyePath)
ctx.clip()
let iris = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(1.0, 0.93, 0.45, 1), rgba(1.0, 0.62, 0.12, 1),
             rgba(0.92, 0.30, 0.03, 1), rgba(0.62, 0.09, 0.01, 1)] as CFArray,
    locations: [0, 0.35, 0.7, 1])!
ctx.translateBy(x: cx, y: cy)
ctx.scaleBy(x: 1.0, y: 0.52)
ctx.drawRadialGradient(iris, startCenter: .zero, startRadius: 0,
                       endCenter: .zero, endRadius: px(310), options: [])
ctx.restoreGState()

// Rim stroke around the almond.
ctx.saveGState()
ctx.addPath(eyePath)
ctx.setStrokeColor(rgba(0.45, 0.05, 0.0, 0.85))
ctx.setLineWidth(px(7))
ctx.strokePath()
ctx.restoreGState()

// ---- Slit pupil ----
let pupil = almond(cx: cx, cy: cy, halfWidth: px(46), controlHeight: px(0))
// vertical slit: reuse almond rotated 90° — build directly instead:
let slit = CGMutablePath()
slit.move(to: CGPoint(x: cx, y: cy - px(150)))
slit.addQuadCurve(to: CGPoint(x: cx, y: cy + px(150)),
                  control: CGPoint(x: cx + px(66), y: cy))
slit.addQuadCurve(to: CGPoint(x: cx, y: cy - px(150)),
                  control: CGPoint(x: cx - px(66), y: cy))
slit.closeSubpath()
_ = pupil

// soft dark halo behind the slit
ctx.saveGState()
ctx.translateBy(x: cx, y: cy)
ctx.scaleBy(x: 0.42, y: 1.0)
let pupilHalo = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(0.25, 0.0, 0.0, 0.9), rgba(0.25, 0.0, 0.0, 0.0)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(pupilHalo, startCenter: .zero, startRadius: 0,
                       endCenter: .zero, endRadius: px(190), options: [])
ctx.restoreGState()

ctx.addPath(slit)
ctx.setFillColor(rgba(0.02, 0.0, 0.0, 1))
ctx.fillPath()

ctx.restoreGState() // tile clip

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)x\(size))")
