import AppKit
import Foundation

// Packaging helper: 660x420 DMG background. The icon coordinates match the
// create-dmg arguments in Scripts/package-dmg.sh.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png>\n".utf8))
    exit(2)
}

let size = NSSize(width: 660, height: 420)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.086, alpha: 1).setFill()
rect.fill()
if let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.045, green: 0.05, blue: 0.07, alpha: 1),
]) {
    gradient.draw(in: rect, angle: -70)
}

let title = "Drift" as NSString
title.draw(
    at: NSPoint(x: 48, y: 320),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 38, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
)
let subtitle = "Native macOS BitTorrent, now with a built-in engine" as NSString
subtitle.draw(
    at: NSPoint(x: 50, y: 292),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1),
    ]
)
let hint = "Drag Drift to Applications" as NSString
hint.draw(
    at: NSPoint(x: 248, y: 88),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1),
    ]
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 300, y: 190))
arrow.line(to: NSPoint(x: 388, y: 190))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.30, green: 0.66, blue: 1.0, alpha: 1).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 388, y: 190))
head.line(to: NSPoint(x: 366, y: 202))
head.line(to: NSPoint(x: 366, y: 178))
head.close()
NSColor(calibratedRed: 0.30, green: 0.66, blue: 1.0, alpha: 1).setFill()
head.fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("failed to render background\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
