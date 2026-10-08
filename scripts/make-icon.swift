#!/usr/bin/env swift
// Mapo uygulama ikonunu üretir (docs/TASARIM.md §Uygulama ikonu).
//
//   swift scripts/make-icon.swift            → App/Resources/Assets.xcassets/AppIcon.appiconset
//   swift scripts/make-icon.swift --preview out.png
//
// Koyu mürekkep zemin, haritadaki gibi iç içe daireler (klasör halkası, içinde
// dosyalar), seçili dosyada pusula sarısı halka ve kullandığı bölgeye bir ok. Çizim 1024 pt'lik tuvalde; macOS ızgarası
// gereği içerik 824 pt'lik yuvarlatılmış karede, kenarda 100 pt boşluk.

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Circle-packing composition in tile-unit space (0…1, y up), the same
// language as the map: folders are rings, files are discs inside them, the
// selection wears the Pusula ring and one arrow shows what it uses. Hand
// placed so it reads at 16 px: three masses, one accent.
struct C { let x: CGFloat; let y: CGFloat; let r: CGFloat }
let teal: UInt32 = 0x4FC1B3, violet: UInt32 = 0x9A8CF0, coral: UInt32 = 0xF07E6E
let regions: [(C, UInt32, [C])] = [
    (C(x: 0.38, y: 0.58, r: 0.31), teal, [
        C(x: 0.30, y: 0.64, r: 0.105), C(x: 0.50, y: 0.73, r: 0.075), C(x: 0.58, y: 0.59, r: 0.055),
        C(x: 0.24, y: 0.42, r: 0.075), C(x: 0.41, y: 0.35, r: 0.055),
    ]),
    (C(x: 0.78, y: 0.27, r: 0.16), violet, [
        C(x: 0.74, y: 0.30, r: 0.070), C(x: 0.86, y: 0.22, r: 0.050), C(x: 0.80, y: 0.15, r: 0.035),
    ]),
    (C(x: 0.80, y: 0.74, r: 0.12), coral, [
        C(x: 0.77, y: 0.76, r: 0.055), C(x: 0.86, y: 0.69, r: 0.040),
    ]),
]
let selected = regions[0].2[0]
let target = regions[1].0

func draw(in ctx: CGContext, size: CGFloat) {
    let s = size / canvas
    ctx.scaleBy(x: s, y: s)

    // Tile with macOS-style continuous corners.
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x0E1015))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x1A1F2B), rgb(0x0B0D12)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Faint dot grid, as on the map canvas.
    ctx.setFillColor(rgb(0xC9D3E6, 0.07))
    var gx = tile.minX + 34
    while gx < tile.maxX {
        var gy = tile.minY + 34
        while gy < tile.maxY { ctx.fillEllipse(in: CGRect(x: gx - 3, y: gy - 3, width: 6, height: 6)); gy += 68.67 }
        gx += 68.67
    }

    func p(_ c: C) -> CGPoint { CGPoint(x: tile.minX + c.x * tile.width, y: tile.minY + c.y * tile.height) }
    func r(_ c: C) -> CGFloat { c.r * tile.width }
    func circle(_ c: C, grow: CGFloat = 0) -> CGRect {
        let o = p(c), rr = r(c) + grow
        return CGRect(x: o.x - rr, y: o.y - rr, width: 2 * rr, height: 2 * rr)
    }

    for (ring, color, files) in regions {
        ctx.setFillColor(rgb(color, 0.13))
        ctx.fillEllipse(in: circle(ring))
        ctx.setStrokeColor(rgb(color, 0.55))
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: circle(ring, grow: -3.5))
        ctx.setFillColor(rgb(color))
        for f in files { ctx.fillEllipse(in: circle(f)) }
    }

    // Arrow: selection → the area it uses, curved like the map's links.
    let a0 = p(selected), b0 = p(target)
    let dx = b0.x - a0.x, dy = b0.y - a0.y, d = hypot(dx, dy)
    let start = CGPoint(x: a0.x + dx / d * (r(selected) + 72), y: a0.y + dy / d * (r(selected) + 72))
    let end = CGPoint(x: b0.x - dx / d * (r(target) + 6), y: b0.y - dy / d * (r(target) + 6))
    let mid = CGPoint(x: (start.x + end.x) / 2 + dy * 0.16, y: (start.y + end.y) / 2 - dx * 0.16)
    ctx.setLineCap(.round)
    for (w, col) in [(CGFloat(34), rgb(0x0E1015, 0.75)), (CGFloat(18), rgb(0xF0AE47))] {
        ctx.setStrokeColor(col)
        ctx.setLineWidth(w)
        ctx.move(to: start)
        ctx.addQuadCurve(to: end, control: mid)
        ctx.strokePath()
    }
    let ang = atan2(end.y - mid.y, end.x - mid.x), L: CGFloat = 62
    ctx.setFillColor(rgb(0xF0AE47))
    ctx.move(to: CGPoint(x: end.x + 10 * cos(ang), y: end.y + 10 * sin(ang)))
    ctx.addLine(to: CGPoint(x: end.x - L * cos(ang - 0.5), y: end.y - L * sin(ang - 0.5)))
    ctx.addLine(to: CGPoint(x: end.x - L * cos(ang + 0.5), y: end.y - L * sin(ang + 0.5)))
    ctx.closePath()
    ctx.fillPath()

    // Selection ring (Pusula), with a dark gap so it reads at small sizes.
    ctx.setStrokeColor(rgb(0x0E1015))
    ctx.setLineWidth(12)
    ctx.strokeEllipse(in: circle(selected, grow: 10))
    ctx.setStrokeColor(rgb(0xF0AE47))
    ctx.setLineWidth(15)
    ctx.strokeEllipse(in: circle(selected, grow: 22))

    // Subtle top highlight on the tile edge.
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(in: ctx, size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    try png(size: 1024).write(to: URL(fileURLWithPath: args[i + 1]))
    print("önizleme:", args[i + 1])
    exit(0)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let dir = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try png(size: px).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
print("AppIcon yazıldı:", dir.path)
