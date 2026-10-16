// Draws the 1024 px app icon: swift scripts/make-icon.swift icon_1024.png
// Then scale it into Blinkers/Assets.xcassets/AppIcon.appiconset with sips.

import AppKit

let size: CGFloat = 1024
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255, green: CGFloat((hex >> 8) & 0xFF)/255, blue: CGFloat(hex & 0xFF)/255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Body: Apple's macOS icon grid, 824 pt rounded square inset 100.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the body, like system icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(c(0x0B0D14)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
// Background: deep night gradient.
ctx.drawLinearGradient(gradient([c(0x232838), c(0x0E1019), c(0x07080D)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Warm glow behind the window.
ctx.drawRadialGradient(gradient([c(0xFFB547, 0.7), c(0xFF8A3D, 0.24), c(0xFF8A3D, 0)], [0, 0.45, 1]),
                       startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 500), endRadius: 430, options: [])

// Blinkers: two dark slabs in perspective, narrowing towards the middle.
func blinker(mirrored: Bool) {
    let outerX: CGFloat = 158, innerX: CGFloat = 318
    let p = CGMutablePath()
    func x(_ v: CGFloat) -> CGFloat { mirrored ? size - v : v }
    p.move(to: CGPoint(x: x(outerX), y: 820))
    p.addLine(to: CGPoint(x: x(innerX), y: 742))
    p.addLine(to: CGPoint(x: x(innerX), y: 282))
    p.addLine(to: CGPoint(x: x(outerX), y: 204))
    p.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: mirrored ? -10 : 10, height: -6), blur: 30, color: c(0x000000, 0.6))
    ctx.addPath(p); ctx.setFillColor(c(0x1A1E2B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(gradient([c(0x4A5272), c(0x20253A), c(0x12141E)], [0, 0.5, 1]),
                           start: CGPoint(x: x(outerX), y: 820), end: CGPoint(x: x(innerX), y: 204), options: [])
    ctx.restoreGState()
    // Lit inner edge, facing the window.
    ctx.saveGState()
    ctx.setStrokeColor(c(0xFFC977, 0.55)); ctx.setLineWidth(5); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x(innerX), y: 738)); ctx.addLine(to: CGPoint(x: x(innerX), y: 286)); ctx.strokePath()
    ctx.restoreGState()
}
blinker(mirrored: false)
blinker(mirrored: true)

// The focused window.
let window = CGRect(x: 360, y: 300, width: 304, height: 424)
let windowPath = CGPath(roundedRect: window, cornerWidth: 40, cornerHeight: 40, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 90, color: c(0xFFA53A, 0.85))
ctx.addPath(windowPath); ctx.setFillColor(c(0xFFD48A)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(windowPath); ctx.clip()
ctx.drawLinearGradient(gradient([c(0xFFFBF2), c(0xFFE7B8), c(0xFFC266)], [0, 0.45, 1]),
                       start: CGPoint(x: 512, y: 724), end: CGPoint(x: 512, y: 300), options: [])
// Title bar.
ctx.setFillColor(c(0xFFFFFF, 0.55)); ctx.fill(CGRect(x: 360, y: 668, width: 304, height: 56))
ctx.setFillColor(c(0xE0A04A, 0.35)); ctx.fill(CGRect(x: 360, y: 666, width: 304, height: 2))
for (i, col) in [0xFF6159, 0xFFBD2E, 0x28C941].enumerated() {
    ctx.setFillColor(c(UInt32(col), 0.9))
    ctx.fillEllipse(in: CGRect(x: 386 + CGFloat(i) * 30, y: 686, width: 20, height: 20))
}
// Text lines.
ctx.setFillColor(c(0xC9822E, 0.38))
for (i, w) in [CGFloat(220), 250, 190, 236, 150].enumerated() {
    let r = CGRect(x: 392, y: 610 - CGFloat(i) * 46, width: w, height: 18)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath()
}
ctx.restoreGState()

// Top sheen on the body.
ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0.10), c(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(bodyPath); ctx.setStrokeColor(c(0xFFFFFF, 0.10)); ctx.setLineWidth(2); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
