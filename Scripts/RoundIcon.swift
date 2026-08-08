import AppKit

// Rounds the corners of a square icon and writes a new PNG.
//
// Usage: swift RoundIcon.swift <in.png> <out.png> [cornerFraction]
//
// The fraction is of the icon's width. macOS's own squircle is about 0.22;
// anything smaller reads as "slightly rounded" rather than fully Apple-shaped.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: RoundIcon <in.png> <out.png> [fraction]\n".data(using: .utf8)!)
    exit(2)
}
let fraction = args.count > 3 ? (Double(args[3]) ?? 0.18) : 0.18

guard let data = FileManager.default.contents(atPath: args[1]),
      let source = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let side = max(source.pixelsWide, source.pixelsHigh)
let rect = NSRect(x: 0, y: 0, width: side, height: side)

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
canvas.size = rect.size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSColor.clear.setFill()
rect.fill()

// Clip to the rounded rect, then draw the artwork through it.
let radius = CGFloat(Double(side) * fraction)
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
source.draw(in: rect)

NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
print("rounded \(side)×\(side) at r=\(Int(radius)) -> \(args[2])")
