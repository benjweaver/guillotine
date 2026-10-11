// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import AppKit

@main struct MakeIcon {
    static func main() throws {
        let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
        var images: [[String: String]] = []
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(size)x\(size)@\(scale)x.png"
                try render(size * scale, to: destination.appendingPathComponent(name))
                images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
            }
        }
        try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
    }
    static func render(_ pixels: Int, to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
        NSGradient(starting: NSColor(red: 0.12, green: 0.19, blue: 0.26, alpha: 1), ending: NSColor(red: 0.025, green: 0.055, blue: 0.09, alpha: 1))!.draw(in: background, angle: 90)
        context.translateBy(x: 128, y: 128)
        GuillotineGlyph.draw(size: 768, active: true, colored: true)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
