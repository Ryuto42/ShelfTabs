import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.42, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.22, blue: 0.92, alpha: 1),
    ])!.draw(in: bodyPath, angle: -55)

    let cards: [(NSRect, CGFloat)] = [
        (NSRect(x: 330, y: 420, width: 440, height: 330), 0.28),
        (NSRect(x: 290, y: 360, width: 460, height: 340), 0.5),
        (NSRect(x: 250, y: 290, width: 480, height: 350), 0.95),
    ]
    for (rect, alpha) in cards {
        let r = NSRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
        let path = NSBezierPath(roundedRect: r, xRadius: 46 * s, yRadius: 46 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 30 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    let pill = NSRect(x: 290 * s, y: 592 * s, width: 150 * s, height: 22 * s)
    NSColor(srgbRed: 0.3, green: 0.45, blue: 1.0, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 11 * s, yRadius: 11 * s).fill()

    let lightColors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    for (i, color) in lightColors.enumerated() {
        let d = 34 * s
        let rect = NSRect(x: (292 + CGFloat(i) * 52) * s, y: 540 * s, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
