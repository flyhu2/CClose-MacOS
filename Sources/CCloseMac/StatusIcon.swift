import AppKit

/// A small window stack with a pin: recognisable at menu-bar size and template-tinted by macOS.
enum StatusIcon {
    static func image(pinned: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 14, height: 11), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.25; back.stroke()
            NSColor.clear.setFill()
            NSRect(x: 5, y: 5, width: 16, height: 12).fill(using: .copy)
            NSColor.black.setStroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 5.5, width: 15, height: 11), xRadius: 2, yRadius: 2)
            front.lineWidth = pinned ? 1.8 : 1.25; front.stroke()
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: 6, y: 13.5)); bar.line(to: NSPoint(x: 10, y: 13.5))
            bar.lineWidth = 1; bar.stroke()
            let pin = NSBezierPath()
            pin.move(to: NSPoint(x: 12, y: 14)); pin.line(to: NSPoint(x: 17, y: 14))
            pin.move(to: NSPoint(x: 13, y: 14)); pin.line(to: NSPoint(x: 13, y: 11))
            pin.line(to: NSPoint(x: 11.8, y: 9.5)); pin.line(to: NSPoint(x: 17.2, y: 9.5))
            pin.line(to: NSPoint(x: 16, y: 11)); pin.line(to: NSPoint(x: 16, y: 14))
            pin.move(to: NSPoint(x: 14.5, y: 9.5)); pin.line(to: NSPoint(x: 14.5, y: 7))
            pin.lineWidth = 1.2; pin.lineCapStyle = .round; pin.lineJoinStyle = .round; pin.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CClose-MscOS 窗口置顶"
        return image
    }
}
