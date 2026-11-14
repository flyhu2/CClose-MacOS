import AppKit
import XCTest
@testable import CCloseMac

@MainActor
final class MirrorPreviewTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, at point: CGPoint, time: TimeInterval = 10,
                       clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: time,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testPreviewBlocksContentWithoutDisablingTitleActions() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MirrorView(frame: panel.contentView!.bounds)
        panel.contentView = view
        view.sourceSize = view.bounds.size
        view.sourceTitleHit = { _ in true }
        view.contentInteractionEnabled = false
        var inputs = 0, visits = 0, menus = 0, dismissals = 0, minimizes = 0, zooms = 0
        view.onInput = { _, _ in inputs += 1 }
        view.onVisit = { visits += 1 }
        view.onContextMenu = { _, _ in menus += 1 }
        view.onDismiss = { dismissals += 1 }
        view.onMinimize = { minimizes += 1 }
        view.onTitleDoubleClick = { _, _ in zooms += 1 }
        let content = CGPoint(x: 200, y: 150)
        for flags: NSEvent.ModifierFlags in [[], .command] {
            view.mouseDown(with: event(.leftMouseDown, at: content, flags: flags))
            view.mouseDragged(with: event(.leftMouseDragged, at: content, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, at: content, clicks: 2, flags: flags))
        }
        view.rightMouseDown(with: event(.rightMouseDown, at: content))
        view.rightMouseUp(with: event(.rightMouseUp, at: content))
        view.otherMouseDown(with: event(.otherMouseDown, at: content))
        view.otherMouseUp(with: event(.otherMouseUp, at: content))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertEqual(inputs + visits + menus + dismissals + minimizes + zooms, 0)
        let title = CGPoint(x: 200, y: 280)
        view.mouseDown(with: event(.leftMouseDown, at: title))
        view.mouseUp(with: event(.leftMouseUp, at: title, time: 10 + Prefs.shared.holdSeconds + 1))
        XCTAssertEqual(dismissals, 1)
        view.mouseDown(with: event(.leftMouseDown, at: title))
        view.mouseUp(with: event(.leftMouseUp, at: title, time: 10.1, clicks: 2))
        XCTAssertEqual(zooms, 1)
        // Direct interaction is still available to the normal overlapping mode.
        view.contentInteractionEnabled = true
        view.mouseDown(with: event(.leftMouseDown, at: content))
        view.rightMouseDown(with: event(.rightMouseDown, at: content))
        XCTAssertEqual(inputs, 1)
        XCTAssertEqual(menus, 1)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(visits, 1)
    }
}
