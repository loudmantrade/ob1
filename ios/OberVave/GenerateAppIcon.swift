import AppKit

let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("AppIcons", isDirectory: true)
let size = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                             bytesPerRow: size * 4, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot create app icon bitmap")
}
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
guard let background = NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1),
                                  ending: NSColor(srgbRed: 0.035, green: 0.05, blue: 0.08, alpha: 1)) else {
    fatalError("Cannot create app icon gradient")
}
background.draw(in: canvas, angle: -90)
let cyan = NSColor(srgbRed: 0.2, green: 0.85, blue: 0.95, alpha: 1)
let border = NSBezierPath(roundedRect: canvas.insetBy(dx: 92, dy: 92), xRadius: 62, yRadius: 62)
border.lineWidth = 6
cyan.withAlphaComponent(0.45).setStroke()
border.stroke()

let title = NSAttributedString(string: "OB", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 470, weight: .heavy),
    .foregroundColor: cyan,
    .kern: -18
])
let bounds = title.size()
title.draw(at: NSPoint(x: (1024 - bounds.width) / 2, y: (1024 - bounds.height) / 2 + 15))

let line = NSBezierPath()
line.move(to: NSPoint(x: 260, y: 260))
line.line(to: NSPoint(x: 764, y: 260))
line.lineWidth = 10
cyan.setStroke()
line.stroke()

guard let image = bitmap.makeImage() else {
    fatalError("Cannot create app icon image")
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, pixels) in [
    ("Icon1024", 1024), ("Icon60@2x", 120), ("Icon60@3x", 180),
    ("Icon76", 76), ("Icon76@2x", 152), ("Icon83.5@2x", 167)
] {
    guard let resized = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Cannot resize app icon")
    }
    resized.interpolationQuality = .high
    resized.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = resized.makeImage(),
          let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode app icon PNG")
    }
    try png.write(to: destination.appendingPathComponent("\(name).png"))
}
print("Generated icons in \(destination.path)")
