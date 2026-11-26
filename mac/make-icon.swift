// Draws the Companion icon. Run from mac/: swift make-icon.swift [--ios]
import Foundation
import AppKit
let size = 1024
let ios = CommandLine.arguments.contains("--ios")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let opaque = ios ? CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)! : nil
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = opaque.map { NSGraphicsContext(cgContext: $0, flipped: false) }
  ?? NSGraphicsContext(bitmapImageRep: rep)
// iOS masks the full-bleed square itself. macOS uses the inset tile.
let tile = ios ? NSRect(x: 0, y: 0, width: size, height: size) : NSRect(x: 100, y: 100, width: 824, height: 824)
let path = ios ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.89, green: 1, blue: 0.55, alpha: 1), ending: NSColor(red: 0.72, green: 0.93, blue: 0.30, alpha: 1))!.draw(in: path, angle: -90)
let art = NSImage(contentsOfFile: "Sources/Companion/Resources/happy-0.png")!
let w = 600.0 * tile.width / 824, h = w * art.size.height / art.size.width
art.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2 - 10, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
let output = ios ? "../ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png" : "/tmp/icon-1024.png"
let bitmap = opaque.map { NSBitmapImageRep(cgImage: $0.makeImage()!) } ?? rep
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
