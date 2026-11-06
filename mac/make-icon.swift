// Draws the app icon: the companion on a lime tile. Run: swift make-icon.swift  → AppIcon.icns
import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon grid: margin around the tile
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.89, green: 1, blue: 0.55, alpha: 1), ending: NSColor(red: 0.72, green: 0.93, blue: 0.30, alpha: 1))!.draw(in: path, angle: -90)
let art = NSImage(contentsOfFile: "Sources/Companion/Resources/happy-0.png")!
let w = 600.0, h = w * art.size.height / art.size.width
art.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2 - 10, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/icon-1024.png"))
