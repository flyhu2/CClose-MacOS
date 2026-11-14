import AppKit

/// Coordinates are in logical points; backing pixels never enter the input mapping.
enum MirrorGeometry {
    static func coherentCapture(pixels: CGSize, content: CGSize?, source: CGSize, scale: CGFloat) -> Bool {
        guard source.width > 0, source.height > 0, scale > 0,
              abs(pixels.width - source.width * scale) <= 2,
              abs(pixels.height - source.height * scale) <= 2 else { return false }
        guard let content, content.width > 0, content.height > 0 else { return false }
        return abs(content.width / content.height - source.width / source.height) < 2 / source.height
    }
    static func presentationMatches(actualPixels: CGSize, expectedPixels: CGSize) -> Bool {
        expectedPixels.width > 0 && expectedPixels.height > 0
            && actualPixels == expectedPixels
    }

    static let edgeInset: CGFloat = 14
    static let cornerInset: CGFloat = 22
    static func resizeEdges(at point: CGPoint, bounds: CGRect) -> Int {
        guard bounds.contains(point) else { return 0 }
        var mask = 0
        if point.x < bounds.minX + edgeInset { mask |= 1 }
        if point.x > bounds.maxX - edgeInset { mask |= 2 }
        if point.y < bounds.minY + edgeInset { mask |= 4 }
        if point.y > bounds.maxY - edgeInset { mask |= 8 }
        if point.x < bounds.minX + cornerInset && point.y < bounds.minY + cornerInset { mask = 5 }
        if point.x > bounds.maxX - cornerInset && point.y < bounds.minY + cornerInset { mask = 6 }
        if point.x < bounds.minX + cornerInset && point.y > bounds.maxY - cornerInset { mask = 9 }
        if point.x > bounds.maxX - cornerInset && point.y > bounds.maxY - cornerInset { mask = 10 }
        return mask
    }

    /// AppKit screen frame <-> Quartz screen frame; this transform is its own inverse.
    static func screenFrame(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func settingsOrigin(anchor: CGRect, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(visible.minX + 6, anchor.midX - size.width / 2), visible.maxX - size.width - 6),
                y: max(visible.minY + 6, anchor.minY - size.height - 6))
    }
    static func isTitle(_ point: CGPoint, source: CGSize, bounds: CGRect) -> Bool {
        let image = imageRect(source: source, bounds: bounds)
        guard source.width > 0, image.contains(point) else { return false }
        let scale = image.width / source.width
        return point.y >= image.maxY - 28 * scale && point.x > image.minX + 90 * scale
    }

    static func resizedFrame(_ initial: CGRect, delta: CGPoint, edges: Int) -> CGRect {
        var result = initial
        if edges & 1 != 0 { result.size.width = max(240, initial.width - delta.x); result.origin.x = initial.maxX - result.width }
        if edges & 2 != 0 { result.size.width = max(240, initial.width + delta.x) }
        if edges & 4 != 0 { result.size.height = max(140, initial.height - delta.y); result.origin.y = initial.maxY - result.height }
        if edges & 8 != 0 { result.size.height = max(140, initial.height + delta.y) }
        return result
    }

    static func imageRect(source: CGSize, bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// AppKit view point (bottom left) -> target CG screen point (top left).
    static func targetPoint(_ point: CGPoint, source: CGRect, bounds: CGRect, clamp: Bool = false, displayedSize: CGSize? = nil) -> CGPoint? {
        let image = imageRect(source: displayedSize ?? source.size, bounds: bounds)
        guard image.width > 0, image.height > 0 else { return nil }
        if !clamp && !image.contains(point) { return nil }
        let x = min(max((point.x - image.minX) / image.width, 0), 1)
        let y = min(max((point.y - image.minY) / image.height, 0), 1)
        // Clamp to just inside the window; drags ending in letterboxing must release their button.
        return CGPoint(x: source.minX + min(x * source.width, source.width - 0.01),
                       y: source.minY + min((1 - y) * source.height, source.height - 0.01))
    }
}

/// PID-only posting is not enough for a background app with multiple windows.
/// The undocumented window-routing fields (51, 58) follow the technique described in
/// https://github.com/PerpetualBeta/WindowPin/blob/main/Sources/EventForwarder.swift
/// Addressed events are retained only when native hit-testing is unavailable.
enum MirrorEventRouter {
    private static let sessionSource = CGEventSource(stateID: .combinedSessionState)
    static let marker: Int64 = 0x4343_4C53

    // Called only after the overlay is transparent to input and the source is verified
    // underneath it. Clear process/window routing inherited from the overlay event.
    static func nativeCopy(_ event: CGEvent) -> CGEvent? {
        guard let copy = event.copy() else { return nil }
        copy.setIntegerValueField(.eventSourceUserData, value: marker)
        for field in [CGEventField.eventTargetUnixProcessID, .mouseEventWindowUnderMousePointer,
                      .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
            copy.setIntegerValueField(field, value: 0)
        }
        for raw: UInt32 in [51, 58] {
            if let field = CGEventField(rawValue: raw) { copy.setIntegerValueField(field, value: 0) }
        }
        return copy
    }
    static func postNative(_ event: CGEvent) { nativeCopy(event)?.post(tap: .cghidEventTap) }

    static func addressedCopy(_ original: CGEvent, point: CGPoint, windowID: UInt32, pid: pid_t,
                              delta: CGPoint? = nil) -> CGEvent? {
        let copy: CGEvent
        if original.type == .scrollWheel {
            // Keep smooth deltas, horizontal scrolling, scroll/momentum phases and modifiers.
            guard let cloned = original.copy() else { return nil }
            copy = cloned
        } else {
            let button = CGMouseButton(rawValue: UInt32(original.getIntegerValueField(.mouseEventButtonNumber))) ?? .left
            guard let rebuilt = CGEvent(mouseEventSource: sessionSource, mouseType: original.type,
                                        mouseCursorPosition: point, mouseButton: button) else { return nil }
            copy = rebuilt
            copy.flags = original.flags
            copy.timestamp = original.timestamp
            for field: CGEventField in [.mouseEventClickState, .mouseEventNumber, .mouseEventButtonNumber] {
                copy.setIntegerValueField(field, value: original.getIntegerValueField(field))
            }
            copy.setDoubleValueField(.mouseEventPressure, value: original.getDoubleValueField(.mouseEventPressure))
        }
        copy.location = point
        copy.setIntegerValueField(.eventSourceUserData, value: marker)
        copy.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        if let field = CGEventField(rawValue: 51) { copy.setIntegerValueField(field, value: Int64(windowID)) }
        if let field = CGEventField(rawValue: 58) { copy.setIntegerValueField(field, value: 1) }
        if let delta {
            copy.setDoubleValueField(.mouseEventDeltaX, value: delta.x)
            copy.setDoubleValueField(.mouseEventDeltaY, value: delta.y)
        }
        return copy
    }
}
