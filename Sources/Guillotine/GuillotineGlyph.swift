// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import AppKit

/// One original vector drawing supplies the app icon and both menu bar states.
enum GuillotineGlyph {
    static func draw(size: CGFloat, active: Bool, colored: Bool) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: size / 32, y: size / 32)
        let frame = colored ? NSColor(red: 0.78, green: 0.86, blue: 0.94, alpha: 1) : .black
        let accent = colored ? NSColor(red: 1, green: 0.40, blue: 0.26, alpha: 1) : .black
        frame.setStroke()
        let rails = NSBezierPath()
        rails.move(to: NSPoint(x: 7, y: 3)); rails.line(to: NSPoint(x: 7, y: 28))
        rails.line(to: NSPoint(x: 25, y: 28)); rails.line(to: NSPoint(x: 25, y: 3))
        rails.move(to: NSPoint(x: 4, y: 3)); rails.line(to: NSPoint(x: 28, y: 3))
        rails.lineWidth = 2; rails.lineCapStyle = .round; rails.lineJoinStyle = .round; rails.stroke()

        // Suspended diagonal blade above the computer's detachable graphical "head".
        let blade = NSBezierPath()
        blade.move(to: NSPoint(x: 10, y: 24)); blade.line(to: NSPoint(x: 22, y: 24))
        blade.line(to: NSPoint(x: 22, y: 16)); blade.line(to: NSPoint(x: 10, y: 20)); blade.close()
        accent.setStroke(); accent.setFill()
        blade.lineWidth = 1.5; blade.lineJoinStyle = .round
        if active { blade.fill() } else { blade.stroke() }

        frame.setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 11, y: 7, width: 10, height: 6), xRadius: 1, yRadius: 1)
        screen.lineWidth = 1.5; screen.stroke()
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: 16, y: 7)); neck.line(to: NSPoint(x: 16, y: 5))
        neck.lineWidth = 1.5; neck.stroke()
        if active {
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: 26.5, y: 26.5, width: 4, height: 4)).fill()
        }
    }

    static func menuImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            draw(size: 20, active: active, colored: false)
            return true
        }
        image.isTemplate = true
        return image
    }
}
