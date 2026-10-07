#!/usr/bin/env swift
// Atlas uygulama ikonunu üretir (docs/TASARIM.md §Uygulama ikonu).
//
//   swift scripts/make-icon.swift            → App/Resources/Assets.xcassets/AppIcon.appiconset
//   swift scripts/make-icon.swift --preview out.png
//
// Koyu mürekkep zemin, üç küme halinde bağlı düğümler, bir düğümün etrafında
// pusula sarısı seçim halkası. Çizim 1024 pt'lik tuvalde; macOS ızgarası
// gereği içerik 824 pt'lik yuvarlatılmış karede, kenarda 100 pt boşluk.

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Node layout in tile-unit space (0…1, y up). Three clusters, hand placed so
// the composition reads at 16 px: big masses, few edges.
struct N { let x: CGFloat; let y: CGFloat; let r: CGFloat; let c: UInt32 }
let teal: UInt32 = 0x4FC1B3, violet: UInt32 = 0x9A8CF0, coral: UInt32 = 0xF07E6E
let nodes: [N] = [
    // cluster A (upper left, teal)
    N(x: 0.30, y: 0.70, r: 0.070, c: teal),
    N(x: 0.13, y: 0.50, r: 0.040, c: teal),
    N(x: 0.45, y: 0.87, r: 0.036, c: teal),
    N(x: 0.13, y: 0.81, r: 0.030, c: teal),
    // cluster B (right, violet)
    N(x: 0.72, y: 0.62, r: 0.062, c: violet),
    N(x: 0.85, y: 0.76, r: 0.036, c: violet),
    N(x: 0.86, y: 0.48, r: 0.034, c: violet),
    // cluster C (bottom, coral)
    N(x: 0.44, y: 0.30, r: 0.058, c: coral),
    N(x: 0.28, y: 0.20, r: 0.034, c: coral),
    N(x: 0.60, y: 0.17, r: 0.036, c: coral),
]
let edges: [(Int, Int)] = [
    (0, 1), (0, 2), (0, 3), (1, 3),
    (4, 5), (4, 6),
    (7, 8), (7, 9),
    // bridges between clusters
    (0, 4), (0, 7), (4, 7),
]
let selected = 0

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
    // Ink gradient, slightly lighter at top.
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x1A1F2B), rgb(0x0B0D12)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Faint survey grid.
    ctx.setStrokeColor(rgb(0xC9D3E6, 0.06))
    ctx.setLineWidth(2)
    var g = tile.minX + 68.67
    while g < tile.maxX { ctx.move(to: CGPoint(x: g, y: tile.minY)); ctx.addLine(to: CGPoint(x: g, y: tile.maxY)); g += 68.67 }
    g = tile.minY + 68.67
    while g < tile.maxY { ctx.move(to: CGPoint(x: tile.minX, y: g)); ctx.addLine(to: CGPoint(x: tile.maxX, y: g)); g += 68.67 }
    ctx.strokePath()

    func p(_ n: N) -> CGPoint { CGPoint(x: tile.minX + n.x * tile.width, y: tile.minY + n.y * tile.height) }

    // Edges.
    ctx.setLineCap(.round)
    for (a, b) in edges {
        let bridge = nodes[a].c != nodes[b].c
        ctx.setStrokeColor(bridge ? rgb(0xE6ECF7, 0.22) : rgb(nodes[a].c, 0.55))
        ctx.setLineWidth(bridge ? 9 : 11)
        ctx.move(to: p(nodes[a])); ctx.addLine(to: p(nodes[b]))
        ctx.strokePath()
    }

    // Nodes.
    for n in nodes {
        let r = n.r * tile.width
        let c = p(n)
        ctx.setFillColor(rgb(n.c))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    // Selection ring (Pusula).
    let sel = nodes[selected]
    let rr = sel.r * tile.width + 34
    let sc = p(sel)
    ctx.setStrokeColor(rgb(0xF0AE47))
    ctx.setLineWidth(16)
    ctx.strokeEllipse(in: CGRect(x: sc.x - rr, y: sc.y - rr, width: 2 * rr, height: 2 * rr))

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
