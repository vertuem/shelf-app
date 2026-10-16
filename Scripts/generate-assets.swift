#!/usr/bin/env swift
// Renders the flat app icon from Resources/AppIcon.icon and draws the DMG background. Run from the repository root:
//   swift Scripts/generate-assets.swift
// Writes Resources/AppIcon.icns, Resources/AppIcon.png and Resources/dmg-background{,@2x}.png.
import AppKit

func png(_ image: NSImage, pixels: NSSize) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The app icon is the layered Icon Composer document `Resources/AppIcon.icon`,
/// which macOS 26 renders as Liquid Glass. For macOS 14
/// and 15 and for the README it is rendered flat by Icon Composer's `ictool`,
/// inside the standard 824 point tile of a 1024 point canvas, with a soft shadow.
let ictool = ProcessInfo.processInfo.environment["ICTOOL"]
    ?? "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
let rendered = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-rendered.png")
let render = Process()
render.executableURL = URL(fileURLWithPath: ictool)
render.arguments = ["Resources/AppIcon.icon", "--export-image", "--output-file", rendered.path, "--platform", "macOS",
                    "--rendition", "Default", "--width", "824", "--height", "824", "--scale", "2"]
try render.run()
render.waitUntilExit()
guard render.terminationStatus == 0, let artwork = NSImage(contentsOf: rendered) else {
    fatalError("ictool could not render Resources/AppIcon.icon. Is Icon Composer installed (it comes with Xcode 26)?")
}
let icon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    artwork.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
    return true
}

let resources = URL(fileURLWithPath: "Resources", isDirectory: true)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let size = CGFloat(points * scale)
        try png(icon, pixels: NSSize(width: size, height: size)).write(to: iconset.appendingPathComponent(name))
    }
}
try png(icon, pixels: NSSize(width: 1024, height: 1024)).write(to: resources.appendingPathComponent("AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

/// The DMG window: app on the left, Applications on the right, an arrow between.
let background = NSImage(size: NSSize(width: 660, height: 400), flipped: false) { rect in
    NSGradient(colors: [color(0xF4F6FF), color(0xE3E8FA)])!.draw(in: rect, angle: -90)
    color(0x3A3FB8, 0.75).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 280, y: 215))
    arrow.line(to: NSPoint(x: 380, y: 215))
    arrow.move(to: NSPoint(x: 356, y: 239))
    arrow.line(to: NSPoint(x: 380, y: 215))
    arrow.line(to: NSPoint(x: 356, y: 191))
    arrow.stroke()
    let text = "Drag Shelf to Applications" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: color(0x3C3C43, 0.8),
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (660 - size.width) / 2, y: 70), withAttributes: attributes)
    return true
}
try png(background, pixels: NSSize(width: 660, height: 400)).write(to: resources.appendingPathComponent("dmg-background.png"))
try png(background, pixels: NSSize(width: 1320, height: 800)).write(to: resources.appendingPathComponent("dmg-background@2x.png"))
print("Wrote AppIcon.icns, AppIcon.png and the DMG background to Resources/")
