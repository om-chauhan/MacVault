#!/usr/bin/env swift
// Renders the MacVault app icon at every macOS AppIcon size.
//   swift Scripts/generate-icon.swift [output.appiconset]
// Default output: Config/Assets.xcassets/AppIcon.appiconset
//
// Motif: a vault door whose dial is a storage-usage ring, on the
// standard macOS icon grid (824pt body on a 1024pt canvas).

import AppKit
import CoreGraphics

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Config/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
}

/// Draws the icon into a 1024×1024 coordinate space (origin bottom-left).
func drawIcon(_ ctx: CGContext) {
    let center = CGPoint(x: 512, y: 512)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Body with drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1B2266))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linearGradient(ctx, [rgb(0x4A5CF0), rgb(0x2A2F9E), rgb(0x161A55)],
                   from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft top highlight.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 924), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 924), endRadius: 560, options: [])
    ctx.restoreGState()

    // Vault door: metallic rim.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x05071F, 0.55))
    ctx.addPath(circle(center, 318))
    ctx.setFillColor(rgb(0xC9CEDD))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(circle(center, 318))
    ctx.clip()
    linearGradient(ctx, [rgb(0xF4F6FB), rgb(0xB9BFD2), rgb(0x8C93AB)],
                   from: CGPoint(x: 300, y: 830), to: CGPoint(x: 724, y: 194))
    ctx.restoreGState()

    // Locking bolts around the rim.
    for i in 0..<12 {
        let angle = CGFloat(i) * .pi / 6 + .pi / 12
        let p = CGPoint(x: center.x + cos(angle) * 293, y: center.y + sin(angle) * 293)
        ctx.addPath(circle(p, 11))
        ctx.setFillColor(rgb(0x6B7290))
        ctx.fillPath()
        ctx.addPath(circle(CGPoint(x: p.x - 2, y: p.y + 2), 6))
        ctx.setFillColor(rgb(0xE4E7F0))
        ctx.fillPath()
    }

    // Door face.
    ctx.saveGState()
    ctx.addPath(circle(center, 268))
    ctx.clip()
    linearGradient(ctx, [rgb(0x262C7A), rgb(0x12153F)],
                   from: CGPoint(x: 512, y: 780), to: CGPoint(x: 512, y: 244))
    ctx.restoreGState()

    // Storage ring: category segments + unused remainder.
    let ringRadius: CGFloat = 206
    let ringWidth: CGFloat = 58
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.strokePath()

    let segments: [(fraction: CGFloat, color: UInt32)] = [
        (0.30, 0x5AC8FA), // cyan
        (0.20, 0xAF7BFF), // violet
        (0.14, 0xFF5E9C), // pink
        (0.10, 0xFF9F43), // orange
        (0.08, 0x4CD97B), // green
    ]
    let gap: CGFloat = 0.035
    var start: CGFloat = .pi / 2 // 12 o'clock, running clockwise
    for segment in segments {
        let sweep = segment.fraction * .pi * 2
        ctx.addArc(center: center, radius: ringRadius,
                   startAngle: start - gap / 2, endAngle: start - sweep + gap / 2, clockwise: true)
        ctx.setStrokeColor(rgb(segment.color))
        ctx.strokePath()
        start -= sweep
    }

    // Hub with a three-spoke handle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.45))
    ctx.setLineCap(.round)
    ctx.setLineWidth(30)
    ctx.setStrokeColor(rgb(0xDDE1EC))
    for i in 0..<3 {
        let angle = CGFloat(i) * 2 * .pi / 3 + .pi / 2
        ctx.move(to: center)
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * 128, y: center.y + sin(angle) * 128))
    }
    ctx.strokePath()
    ctx.addPath(circle(center, 78))
    ctx.setFillColor(rgb(0xDDE1EC))
    ctx.fillPath()
    ctx.restoreGState()

    for i in 0..<3 {
        let angle = CGFloat(i) * 2 * .pi / 3 + .pi / 2
        ctx.addPath(circle(CGPoint(x: center.x + cos(angle) * 128, y: center.y + sin(angle) * 128), 24))
        ctx.setFillColor(rgb(0xF4F6FB))
        ctx.fillPath()
    }

    ctx.saveGState()
    ctx.addPath(circle(center, 78))
    ctx.clip()
    linearGradient(ctx, [rgb(0xFFFFFF), rgb(0xB4BACD)],
                   from: CGPoint(x: 470, y: 590), to: CGPoint(x: 554, y: 434))
    ctx.restoreGState()
    ctx.addPath(circle(center, 30))
    ctx.setFillColor(rgb(0x2A2F9E))
    ctx.fillPath()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try fm.createDirectory(atPath: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))

let catalog = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("Contents.json")
if !fm.fileExists(atPath: catalog.path) {
    try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: catalog, atomically: true, encoding: .utf8)
}
print("Wrote \(images.count) icons to \(output)")
