import AppKit
import Foundation

struct Palette {
    static let gradientStart = NSColor(hex: "#3D2808")
    static let gradientEnd = NSColor(hex: "#7A4210")
    static let amber = NSColor(hex: "#E8860A")
    static let white = NSColor.white
}

struct IconSpec {
    static let sizes: [(filename: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
}

let rootPath = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
let iconsetURL = rootURL
    .appendingPathComponent("Sources", isDirectory: true)
    .appendingPathComponent("TimeNoteApp", isDirectory: true)
    .appendingPathComponent("Assets.xcassets", isDirectory: true)
    .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (filename, pixels) in IconSpec.sizes {
    let pngData = try renderIconPNG(pixels: pixels)
    try pngData.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
}

func renderIconPNG(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "TimeNoteIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建位图"])
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "TimeNoteIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建图形上下文"])
    }
    NSGraphicsContext.current = context

    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let scale = CGFloat(pixels) / 1024

    drawBackground(in: rect)
    drawGloss(in: rect)
    drawBottomBand(in: rect, scale: scale)
    drawTimeline(in: rect, scale: scale)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TimeNoteIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法导出 PNG"])
    }
    return data
}

func drawBackground(in rect: NSRect) {
    let gradient = NSGradient(colors: [Palette.gradientStart, Palette.gradientEnd])!
    gradient.draw(in: rect, angle: -45)
}

func drawGloss(in rect: NSRect) {
    let gradient = NSGradient(
        colorsAndLocations:
            (Palette.white.withAlphaComponent(0.12), 0.0),
            (Palette.white.withAlphaComponent(0.04), 0.45),
            (Palette.white.withAlphaComponent(0.0), 1.0)
    )!
    let topRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    gradient.draw(in: topRect, angle: -90)
}

func drawBottomBand(in rect: NSRect, scale: CGFloat) {
    let bandHeight = 140 * scale
    let bandRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandHeight)
    Palette.amber.withAlphaComponent(0.18).setFill()
    bandRect.fill()
}

func drawTimeline(in rect: NSRect, scale: CGFloat) {
    let railX = 332 * scale
    let railTop = 310 * scale
    let railBottom = 784 * scale

    let railPath = NSBezierPath()
    railPath.move(to: NSPoint(x: railX, y: railTop))
    railPath.line(to: NSPoint(x: railX, y: railBottom))
    railPath.lineWidth = 16 * scale
    railPath.lineCapStyle = .round
    Palette.amber.setStroke()
    railPath.stroke()

    let nodeYs: [CGFloat] = [372, 550, 724]
    for (index, baseY) in nodeYs.enumerated() {
        let opacity: CGFloat = index == 0 ? 1.0 : (index == 1 ? 0.65 : 0.35)
        let radius = 28 * scale
        let nodeRect = NSRect(
            x: railX - radius,
            y: (baseY * scale) - radius,
            width: radius * 2,
            height: radius * 2
        )
        Palette.amber.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: nodeRect).fill()
    }

    let rows: [(y: CGFloat, w1: CGFloat, w2: CGFloat, opacity1: CGFloat, opacity2: CGFloat)] = [
        (372, 380, 240, 0.90, 0.45),
        (550, 320, 200, 0.75, 0.35),
        (724, 280, 180, 0.55, 0.25),
    ]

    for row in rows {
        fillRoundedRect(
            x: 396 * scale,
            y: (row.y - 14) * scale,
            width: row.w1 * scale,
            height: 26 * scale,
            radius: 13 * scale,
            color: Palette.white.withAlphaComponent(row.opacity1)
        )

        fillRoundedRect(
            x: 396 * scale,
            y: (row.y + 22) * scale,
            width: row.w2 * scale,
            height: 20 * scale,
            radius: 10 * scale,
            color: Palette.white.withAlphaComponent(row.opacity2)
        )
    }

    let dotRect = NSRect(
        x: 764 * scale,
        y: 196 * scale,
        width: 72 * scale,
        height: 72 * scale
    )
    Palette.amber.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
}

func fillRoundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, color: NSColor) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

extension NSColor {
    convenience init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(sanitized, radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
