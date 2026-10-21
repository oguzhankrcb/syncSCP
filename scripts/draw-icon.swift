// SPDX-License-Identifier: GPL-3.0-or-later
// Original vector artwork, independent of the upstream WinSCP icon set.
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor) {
    let path = NSBezierPath(); path.lineWidth = 71; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: start); path.line(to: end)
    color.setStroke(); path.stroke()
    let sign: CGFloat = end.x > start.x ? 1 : -1
    let head = NSBezierPath(); head.lineWidth = 71; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: NSPoint(x: end.x - sign * 112, y: end.y + 112)); head.line(to: end)
    head.line(to: NSPoint(x: end.x - sign * 112, y: end.y - 112)); head.stroke()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220)
        NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.46, blue: 0.94, alpha: 1), ending: NSColor(srgbRed: 0.08, green: 0.24, blue: 0.65, alpha: 1))!.draw(in: background, angle: -90)
        drawArrow(from: NSPoint(x: 265, y: 655), to: NSPoint(x: 760, y: 655), color: .white)
        drawArrow(from: NSPoint(x: 760, y: 365), to: NSPoint(x: 265, y: 365), color: NSColor(srgbRed: 0.56, green: 0.91, blue: 0.82, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
