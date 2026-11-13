import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift <iconset-directory>\n", stderr)
    exit(1)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(size: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high

    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 220, yRadius: 220)
    let backgroundGradient = NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.49, blue: 0.85, alpha: 1),
                                        ending: NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.66, alpha: 1))!
    backgroundGradient.draw(in: background, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
    shadow.shadowBlurRadius = 35
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    let card = NSBezierPath(roundedRect: NSRect(x: 194, y: 176, width: 636, height: 672), xRadius: 64, yRadius: 64)
    NSColor.white.setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    card.addClip()
    NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 194, y: 716, width: 636, height: 132)).fill()
    NSColor(calibratedRed: 0.25, green: 0.42, blue: 0.65, alpha: 0.75).setFill()
    for x in [CGFloat(324), CGFloat(477), CGFloat(630)] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 765, width: 71, height: 22), xRadius: 11, yRadius: 11).fill()
    }
    let colors: [NSColor] = [
        NSColor(calibratedRed: 0.28, green: 0.51, blue: 0.87, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.67, blue: 0.84, alpha: 1),
        NSColor(calibratedRed: 0.54, green: 0.67, blue: 0.88, alpha: 1)
    ]
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = NSRect(x: 276 + column * 155, y: 275 + row * 129, width: 116, height: 77)
            colors[(row + column) % colors.count].withAlphaComponent((row == 1 && column == 1) ? 1 : 0.72).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}

let outputs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in outputs { try drawIcon(size: size, name: name) }

// 使用系统支持的 PNG 图标块封装 ICNS，避免依赖图形服务。
let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
]
func appendBigEndian(_ value: Int, to data: inout Data) {
    var number = UInt32(value).bigEndian
    withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
}
var body = Data()
for (type, name) in chunks {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    body.append(contentsOf: type.utf8)
    appendBigEndian(png.count + 8, to: &body)
    body.append(png)
}
var icon = Data("icns".utf8)
appendBigEndian(body.count + 8, to: &icon)
icon.append(body)
try icon.write(to: directory.deletingPathExtension().appendingPathExtension("icns"), options: .atomic)
