import AppKit

/// Borderless overlay: the source's title bar remains the only title bar.
final class MirrorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class MirrorView: NSView {
    var sourceTitleHit: ((CGPoint) -> Bool)?
    var onManipulationStart: (() -> Void)?
    var onTitleDoubleClick: ((NSEvent, CGPoint) -> Void)?
    var hasActiveGesture: Bool { mode != 0 }
    var isManipulating: Bool { (mode == 1 || mode == 2 || mode == 4) && moved }
    var onFrameChange: ((CGRect, Bool) -> Void)?
    var onInput: ((NSEvent, CGPoint) -> Void)?
    var onVisit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onCloseSource: (() -> Void)?
    var onContextMenu: ((NSEvent, CGPoint) -> Void)?
    var sourceSize = CGSize.zero
    var contentInteractionEnabled = true
    var defersResizePresentation = false
    #if DEBUG
    var onQAHoldFrames: ((Bool) -> Void)?
    #endif
    private var requestedResize: CGRect?
    private var downAt: CGPoint?
    private var initialFrame = CGRect.zero
    private var downTime: TimeInterval = 0
    private var mode = 0 // 1: title drag/hold, 2: resize, 3: command click
    private var resizeEdges = 0
    private var moved = false
    private var titleGesture = false
    private var middleHandled = false
    private var holdWork: DispatchWorkItem?
    private let decoration = MirrorDecoration()

    override init(frame: NSRect) {
        super.init(frame: frame)
        decoration.frame = bounds
        decoration.autoresizingMask = [.width, .height]
        addSubview(decoration)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "取消悬浮", target: self, selector: #selector(accessibleDismiss))
        ])
        #if DEBUG
        setAccessibilityCustomActions((accessibilityCustomActions() ?? []) + [
            NSAccessibilityCustomAction(name: "验证：增大宽高", target: self, selector: #selector(qaGrow)),
            NSAccessibilityCustomAction(name: "验证：缩小宽高", target: self, selector: #selector(qaShrink)),
            NSAccessibilityCustomAction(name: "验证：关闭独立桌面开关", target: self, selector: #selector(qaDisableDesktop)),
            NSAccessibilityCustomAction(name: "验证：停帧并放大", target: self, selector: #selector(qaStallResize)),
            NSAccessibilityCustomAction(name: "验证：恢复画面", target: self, selector: #selector(qaResumeFrames))
        ])
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool {
        guard contentInteractionEnabled else { return false }
        onVisit?(); return true
    }
    @objc private func accessibleDismiss() -> Bool { onDismiss?(); return true }
    #if DEBUG
    @objc private func qaStallResize() -> Bool { onQAHoldFrames?(true); return qaGrow() }
    @objc private func qaResumeFrames() -> Bool { onQAHoldFrames?(false); return true }
    @objc private func qaDisableDesktop() -> Bool {
        UserDefaults.standard.set(false, forKey: "independentDesktopEnabled")
        return true
    }
    @objc private func qaGrow() -> Bool { qaResize(CGPoint(x: 80, y: -60)) }
    @objc private func qaShrink() -> Bool { qaResize(CGPoint(x: -80, y: 60)) }
    private func qaResize(_ delta: CGPoint) -> Bool {
        guard let window else { return false }
        onManipulationStart?()
        let frame = MirrorGeometry.resizedFrame(window.frame, delta: delta, edges: 6)
        if !defersResizePresentation { window.setFrame(frame, display: true) }
        onFrameChange?(frame, true)
        return true
    }
    #endif
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func input(_ event: NSEvent) {
        guard contentInteractionEnabled else { return }
        onInput?(event, local(event))
    }
    private func isTitle(_ point: CGPoint) -> Bool {
        MirrorGeometry.isTitle(point, source: sourceSize, bounds: bounds) && (sourceTitleHit?(point) ?? false)
    }
    func refreshAppearance() {
        layer?.backgroundColor = MirrorAppearance.background.cgColor
        decoration.needsDisplay = true
    }
    func isContent(_ point: CGPoint) -> Bool {
        bounds.contains(point) && edges(point) == 0 && !isTitle(point)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        window?.backgroundColor = .clear
        refreshAppearance()
    }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(local(event)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(local(event)) }
    override func mouseExited(with event: NSEvent) { decoration.hoverEdges = 0; NSCursor.arrow.set() }
    private func updateCursor(_ point: CGPoint) {
        let mask = edges(point)
        decoration.hoverEdges = mask
        if mask == 5 || mask == 10 { Self.reverseDiagonalCursor.set() }
        else if mask == 6 || mask == 9 { Self.diagonalCursor.set() }
        else if mask & 3 != 0 { NSCursor.resizeLeftRight.set() }
        else if mask & 12 != 0 { NSCursor.resizeUpDown.set() }
        else if !MirrorGeometry.imageRect(source: sourceSize, bounds: bounds).contains(point) || isTitle(point) { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    private func edges(_ p: CGPoint) -> Int {
        MirrorGeometry.resizeEdges(at: p, bounds: bounds)
    }
    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 14, width: 14, height: max(0, bounds.height - 28)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - 14, y: 14, width: 14, height: max(0, bounds.height - 28)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 14, y: 0, width: max(0, bounds.width - 28), height: 14), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 14, y: bounds.height - 14, width: max(0, bounds.width - 28), height: 14), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: bounds.width - 22, y: 0, width: 22, height: 22), cursor: Self.diagonalCursor)
        addCursorRect(NSRect(x: 0, y: bounds.height - 22, width: 22, height: 22), cursor: Self.diagonalCursor)
        addCursorRect(NSRect(x: 0, y: 0, width: 22, height: 22), cursor: Self.reverseDiagonalCursor)
        addCursorRect(NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 22, height: 22), cursor: Self.reverseDiagonalCursor)
    }
    private static let diagonalCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 5, y: 19)); path.line(to: NSPoint(x: 19, y: 5))
            path.move(to: NSPoint(x: 5, y: 12)); path.line(to: NSPoint(x: 5, y: 19)); path.line(to: NSPoint(x: 12, y: 19))
            path.move(to: NSPoint(x: 12, y: 5)); path.line(to: NSPoint(x: 19, y: 5)); path.line(to: NSPoint(x: 19, y: 12))
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    private static let reverseDiagonalCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let transform = NSAffineTransform(); transform.translateX(by: 24, yBy: 0); transform.scaleX(by: -1, yBy: 1); transform.concat()
            diagonalCursor.image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    override func mouseDown(with event: NSEvent) {
        let point = local(event)
        resizeEdges = edges(point)
        let blank = !MirrorGeometry.imageRect(source: sourceSize, bounds: bounds).contains(point)
        titleGesture = isTitle(point)
        mode = resizeEdges != 0 ? 2 : (blank ? 4 : (titleGesture ? 1 : (contentInteractionEnabled && event.modifierFlags.contains(.command) ? 3 : 0)))
        guard mode != 0 else { input(event); return }
        downAt = NSEvent.mouseLocation
        initialFrame = window?.frame ?? .zero
        requestedResize = nil
        downTime = event.timestamp
        moved = false
        if titleGesture {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.moved, self.titleGesture, self.mode != 0 else { return }
                HUD.shared.flash("松开以取消悬浮")
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.shared.holdSeconds, execute: work)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard mode != 0 else { input(event); return }
        guard let downAt, let window else { return }
        let delta = CGPoint(x: NSEvent.mouseLocation.x - downAt.x, y: NSEvent.mouseLocation.y - downAt.y)
        if !moved && ((mode == 2 && !titleGesture && hypot(delta.x, delta.y) > 1) || hypot(delta.x, delta.y) > (Prefs.shared.trackpadCompatibility ? 12 : 8)) {
            moved = true; holdWork?.cancel()
            if mode == 1 || mode == 2 || mode == 4 { onManipulationStart?() }
        }
        if (mode == 1 || mode == 4) && moved {
            window.setFrameOrigin(NSPoint(x: initialFrame.minX + delta.x, y: initialFrame.minY + delta.y))
            onFrameChange?(window.frame, false)
        } else if mode == 2 && moved {
            let requested = MirrorGeometry.resizedFrame(initialFrame, delta: delta, edges: resizeEdges)
            requestedResize = requested
            if !defersResizePresentation { window.setFrame(requested, display: true) }
            window.invalidateCursorRects(for: self)
            onFrameChange?(requested, false)
        }
    }
    override func mouseUp(with event: NSEvent) {
        holdWork?.cancel(); holdWork = nil
        let oldMode = mode
        mode = 0; downAt = nil
        if (oldMode == 2 || oldMode == 1 || oldMode == 4) && moved, let window { onFrameChange?(oldMode == 2 ? (requestedResize ?? window.frame) : window.frame, true) }
        if oldMode == 0 { input(event) }
        else if titleGesture && !moved && event.timestamp - downTime >= Prefs.shared.holdSeconds { onDismiss?() }
        else if titleGesture && !moved && event.clickCount == 2 { onTitleDoubleClick?(event, local(event)) }
        else if oldMode == 3 && !moved { onVisit?() }
        titleGesture = false
    }
    override func rightMouseDown(with event: NSEvent) {
        if isTitle(local(event)), !Prefs.shared.paused, Prefs.shared.rightClickMinimize { onMinimize?() }
        else if contentInteractionEnabled { onContextMenu?(event, local(event)) }
    }
    override func rightMouseUp(with event: NSEvent) { input(event) }
    override func rightMouseDragged(with event: NSEvent) { input(event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 && isTitle(local(event)), Prefs.shared.middleClickClose { middleHandled = true; onCloseSource?() }
        else { input(event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 && middleHandled { middleHandled = false; return }
        input(event)
    }
    override func otherMouseDragged(with event: NSEvent) { input(event) }
    override func scrollWheel(with event: NSEvent) { input(event) }
}

private final class MirrorDecoration: NSView {
    var hoverEdges = 0 { didSet { if oldValue != hoverEdges { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        MirrorAppearance.borderColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: MirrorAppearance.borderWidth / 2, dy: MirrorAppearance.borderWidth / 2), xRadius: 9, yRadius: 9)
        border.lineWidth = MirrorAppearance.borderWidth
        if border.lineWidth > 0 { border.stroke() }
        // Small edge handles make horizontal/vertical resizing discoverable, not just corners.
        for (edge, start, end): (Int, NSPoint, NSPoint) in [
            (1, NSPoint(x: 3, y: bounds.midY - 10), NSPoint(x: 3, y: bounds.midY + 10)),
            (2, NSPoint(x: bounds.maxX - 3, y: bounds.midY - 10), NSPoint(x: bounds.maxX - 3, y: bounds.midY + 10)),
            (4, NSPoint(x: bounds.midX - 10, y: 3), NSPoint(x: bounds.midX + 10, y: 3)),
            (8, NSPoint(x: bounds.midX - 10, y: bounds.maxY - 3), NSPoint(x: bounds.midX + 10, y: bounds.maxY - 3))
        ] {
            MirrorAppearance.borderColor.withAlphaComponent(hoverEdges & edge != 0 ? 1 : 0.55).setStroke()
            let handle = NSBezierPath(); handle.lineWidth = hoverEdges & edge != 0 ? 3 : 2
            handle.lineCapStyle = .round; handle.move(to: start); handle.line(to: end); handle.stroke()
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.width - 26, y: 0, width: 26, height: 26), xRadius: 6, yRadius: 6).fill()
        NSColor.white.setStroke()
        for offset in [7.0, 12.0, 17.0] {
            let p = NSBezierPath(); p.lineWidth = 1.5
            p.move(to: NSPoint(x: bounds.width - offset, y: 5))
            p.line(to: NSPoint(x: bounds.width - 5, y: offset)); p.stroke()
        }
    }
}
