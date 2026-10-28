// Draws MacProton's app icon in Winkelnet's style and writes a 1024 px PNG.
//
// usage: swift macos/app/make-icon.swift OUT.png

import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let violet = color(124, 58, 237), blue = color(47, 87, 239), cyan = color(6, 182, 212)
let ink = color(10, 10, 15)

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    // macOS icon grid: 824 px squircle centered in 1024 px
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    NSGradient(colors: [color(28, 26, 40), ink])!.draw(in: squircle, angle: 90)

    // Soft brand glows, as on winkelnet.com
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [violet.withAlphaComponent(0.45), violet.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 300, y: 260), radius: 0, toCenter: NSPoint(x: 300, y: 260), radius: 520, options: [])
    NSGradient(colors: [cyan.withAlphaComponent(0.30), cyan.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 780, y: 820), radius: 0, toCenter: NSPoint(x: 780, y: 820), radius: 460, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Gamepad: a wide body with two grips
    let pad = NSBezierPath(roundedRect: NSRect(x: 232, y: 372, width: 560, height: 250), xRadius: 125, yRadius: 125)
    pad.append(NSBezierPath(ovalIn: NSRect(x: 222, y: 470, width: 250, height: 250)))
    pad.append(NSBezierPath(ovalIn: NSRect(x: 552, y: 470, width: 250, height: 250)))
    pad.windingRule = .nonZero

    NSGraphicsContext.saveGraphicsState()
    pad.addClip()
    NSGradient(colors: [violet, blue, cyan])!.draw(in: NSRect(x: 222, y: 372, width: 580, height: 348), angle: 35)
    NSGraphicsContext.restoreGraphicsState()

    // Cut-outs: d-pad on the left, two buttons on the right
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 318, y: 476, width: 124, height: 38), xRadius: 19, yRadius: 19).fill()
    NSBezierPath(roundedRect: NSRect(x: 361, y: 433, width: 38, height: 124), xRadius: 19, yRadius: 19).fill()
    NSBezierPath(ovalIn: NSRect(x: 614, y: 430, width: 52, height: 52)).fill()
    NSBezierPath(ovalIn: NSRect(x: 672, y: 500, width: 52, height: 52)).fill()

    // Winkelnet's dot, the full stop of its wordmark
    let dot = NSBezierPath(ovalIn: NSRect(x: 812, y: 650, width: 66, height: 66))
    NSGraphicsContext.saveGraphicsState()
    dot.addClip()
    NSGradient(colors: [blue, cyan])!.draw(in: dot.bounds, angle: 35)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
