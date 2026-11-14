import AppKit

/// Immediate geometry feedback while an off-Space app is still drawing its new size.
final class ResizeFeedback {
    private var panel: NSPanel?
    func show(_ frame: CGRect) {
        if panel == nil {
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear
            window.ignoresMouseEvents = true; window.hasShadow = false
            window.level = .floating; window.hidesOnDeactivate = false
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = Outline(frame: CGRect(origin: .zero, size: frame.size))
            panel = window
        }
        panel?.setFrame(frame, display: true)
        panel?.contentView?.needsDisplay = true
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    deinit { panel?.close() }

    private final class Outline: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            path.lineWidth = 2; path.setLineDash([6, 4], count: 2, phase: 0)
            MirrorAppearance.borderColor.setStroke(); path.stroke()
            let text = "\(Int(bounds.width)) × \(Int(bounds.height))"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            let rect = CGRect(x: max(8, bounds.width - size.width - 22), y: 10, width: size.width + 12, height: 22)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
        }
    }
}
