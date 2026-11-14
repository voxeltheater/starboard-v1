// Draws the app icon into StarboardUpdater/Assets.xcassets/AppIcon.appiconset.
// Rerun after changing the design:  cd app && swift make_icon.swift
import AppKit

let out = URL(fileURLWithPath: "StarboardUpdater/Assets.xcassets/AppIcon.appiconset")

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// The 1024-point design; everything scales from it.
func draw(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS icon grid: an 824-point rounded square, centred, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0.07, 0.09, 0.17)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0.16, 0.20, 0.36), rgb(0.05, 0.06, 0.13)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Twelve LEDs, as on an RGB12 board: rows of red, green and blue.
    let colors = [rgb(1.0, 0.27, 0.30), rgb(0.25, 0.95, 0.45), rgb(0.30, 0.55, 1.0)]
    let cols = 4, rows = 3, pitch: CGFloat = 150, radius: CGFloat = 46
    let originX = 512 - pitch * CGFloat(cols - 1) / 2
    let originY = 560 - pitch * CGFloat(rows - 1) / 2
    for r in 0..<rows {
        for c in 0..<cols {
            let center = CGPoint(x: originX + CGFloat(c) * pitch, y: originY + CGFloat(rows - 1 - r) * pitch)
            let color = colors[r]
            // Glow
            let glow = CGGradient(colorsSpace: space, colors: [color.copy(alpha: 0.55)!, color.copy(alpha: 0)!] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: radius * 0.6,
                                   endCenter: center, endRadius: radius * 2.1, options: [])
            // Lens: hot white centre fading to the colour.
            let lens = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1), color, color.copy(alpha: 0.9)!] as CFArray,
                                  locations: [0, 0.45, 1])!
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.clip()
            ctx.drawRadialGradient(lens, startCenter: CGPoint(x: center.x - 10, y: center.y + 10), startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    // Update badge: a white disc with a down arrow, bottom right.
    let badgeCenter = CGPoint(x: 752, y: 262), badgeR: CGFloat = 128
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0, 0, 0, 0.5))
    ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR, width: badgeR * 2, height: badgeR * 2))
    ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
    ctx.restoreGState()

    let arrow = CGMutablePath()
    let cx = badgeCenter.x, cy = badgeCenter.y
    arrow.move(to: CGPoint(x: cx - 24, y: cy + 74))
    arrow.addLine(to: CGPoint(x: cx + 24, y: cy + 74))
    arrow.addLine(to: CGPoint(x: cx + 24, y: cy - 4))
    arrow.addLine(to: CGPoint(x: cx + 64, y: cy - 4))
    arrow.addLine(to: CGPoint(x: cx, y: cy - 76))
    arrow.addLine(to: CGPoint(x: cx - 64, y: cy - 4))
    arrow.addLine(to: CGPoint(x: cx - 24, y: cy - 4))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setLineJoin(.round); ctx.setLineWidth(14)
    ctx.setFillColor(rgb(0.12, 0.16, 0.32)); ctx.setStrokeColor(rgb(0.12, 0.16, 0.32))
    ctx.drawPath(using: .fillStroke)
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: out.appendingPathComponent(name))
        images.append(#"{ "idiom": "mac", "size": "\#(points)x\#(points)", "scale": "\#(scale)x", "filename": "\#(name)" }"#)
    }
}
let contents = "{\n  \"images\": [\n    " + images.joined(separator: ",\n    ") + "\n  ],\n  \"info\": { \"version\": 1, \"author\": \"xcode\" }\n}\n"
try contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try #"{ "info": { "version": 1, "author": "xcode" } }"#.write(
    to: out.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote", out.path)
