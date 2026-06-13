import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("AppBundle/Contents/Resources/Mockingbird.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let outputs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.imageInterpolation = .high

    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.48, alpha: 1)
    ])
    gradient?.draw(in: bg, angle: 45)

    let glow = NSBezierPath(ovalIn: NSRect(x: size * 0.58, y: size * 0.58, width: size * 0.28, height: size * 0.28))
    NSColor(calibratedRed: 0.72, green: 0.98, blue: 0.88, alpha: 0.25).setFill()
    glow.fill()

    let bird = NSBezierPath()
    bird.move(to: CGPoint(x: size * 0.20, y: size * 0.47))
    bird.curve(to: CGPoint(x: size * 0.43, y: size * 0.61), controlPoint1: CGPoint(x: size * 0.27, y: size * 0.58), controlPoint2: CGPoint(x: size * 0.35, y: size * 0.64))
    bird.curve(to: CGPoint(x: size * 0.57, y: size * 0.57), controlPoint1: CGPoint(x: size * 0.49, y: size * 0.59), controlPoint2: CGPoint(x: size * 0.53, y: size * 0.58))
    bird.curve(to: CGPoint(x: size * 0.78, y: size * 0.69), controlPoint1: CGPoint(x: size * 0.66, y: size * 0.66), controlPoint2: CGPoint(x: size * 0.73, y: size * 0.70))
    bird.curve(to: CGPoint(x: size * 0.69, y: size * 0.54), controlPoint1: CGPoint(x: size * 0.77, y: size * 0.62), controlPoint2: CGPoint(x: size * 0.74, y: size * 0.58))
    bird.curve(to: CGPoint(x: size * 0.84, y: size * 0.51), controlPoint1: CGPoint(x: size * 0.75, y: size * 0.54), controlPoint2: CGPoint(x: size * 0.80, y: size * 0.53))
    bird.line(to: CGPoint(x: size * 0.72, y: size * 0.45))
    bird.curve(to: CGPoint(x: size * 0.55, y: size * 0.37), controlPoint1: CGPoint(x: size * 0.68, y: size * 0.39), controlPoint2: CGPoint(x: size * 0.62, y: size * 0.36))
    bird.curve(to: CGPoint(x: size * 0.37, y: size * 0.31), controlPoint1: CGPoint(x: size * 0.47, y: size * 0.36), controlPoint2: CGPoint(x: size * 0.42, y: size * 0.34))
    bird.curve(to: CGPoint(x: size * 0.31, y: size * 0.41), controlPoint1: CGPoint(x: size * 0.35, y: size * 0.36), controlPoint2: CGPoint(x: size * 0.33, y: size * 0.39))
    bird.curve(to: CGPoint(x: size * 0.20, y: size * 0.47), controlPoint1: CGPoint(x: size * 0.27, y: size * 0.43), controlPoint2: CGPoint(x: size * 0.23, y: size * 0.45))
    bird.close()

    NSColor(calibratedRed: 0.94, green: 0.98, blue: 0.96, alpha: 1).setFill()
    bird.fill()

    let wing = NSBezierPath()
    wing.move(to: CGPoint(x: size * 0.40, y: size * 0.50))
    wing.curve(to: CGPoint(x: size * 0.55, y: size * 0.43), controlPoint1: CGPoint(x: size * 0.46, y: size * 0.49), controlPoint2: CGPoint(x: size * 0.51, y: size * 0.47))
    wing.curve(to: CGPoint(x: size * 0.35, y: size * 0.36), controlPoint1: CGPoint(x: size * 0.49, y: size * 0.37), controlPoint2: CGPoint(x: size * 0.42, y: size * 0.35))
    NSColor(calibratedRed: 0.21, green: 0.39, blue: 0.42, alpha: 1).setStroke()
    wing.lineWidth = max(1.4, size * 0.025)
    wing.lineCapStyle = .round
    wing.stroke()

    NSColor(calibratedRed: 0.04, green: 0.13, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.68, y: size * 0.58, width: size * 0.035, height: size * 0.035)).fill()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MockingbirdIcon", code: 1)
    }
    try data.write(to: url)
}

for output in outputs {
    try writePNG(drawIcon(size: output.1), to: iconset.appendingPathComponent(output.0))
}
