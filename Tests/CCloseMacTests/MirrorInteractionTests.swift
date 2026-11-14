import XCTest
import CoreGraphics
@testable import CCloseMac

final class MirrorInteractionTests: XCTestCase {
    func testNativeReplayRemovesOverlayRoutingButPreservesScroll() throws {
        let original = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 15, wheel2: -4, wheel3: 0))
        original.flags = [.maskShift]
        original.setIntegerValueField(.eventTargetUnixProcessID, value: 123)
        original.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 456)
        let replay = try XCTUnwrap(MirrorEventRouter.nativeCopy(original))
        XCTAssertEqual(replay.getIntegerValueField(.eventTargetUnixProcessID), 0)
        XCTAssertEqual(replay.getIntegerValueField(.mouseEventWindowUnderMousePointer), 0)
        XCTAssertEqual(replay.getIntegerValueField(.eventSourceUserData), MirrorEventRouter.marker)
        XCTAssertEqual(replay.getIntegerValueField(.scrollWheelEventDeltaAxis1), original.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        XCTAssertEqual(replay.flags, original.flags)
        XCTAssertEqual(original.getIntegerValueField(.eventTargetUnixProcessID), 123)
    }
    func testTimeoutAndMinimizedWindowDoNotEndSession() {
        var state = MirrorLifecycle()
        for _ in 0..<20 { XCTAssertTrue(state.sourceExists(processRunning: true, axResult: .cannotComplete, listed: false)) }
        XCTAssertTrue(state.sourceExists(processRunning: true, axResult: .invalidUIElement, listed: true))
        XCTAssertTrue(state.sourceExists(processRunning: true, axResult: .invalidUIElement, listed: nil))
        XCTAssertTrue(state.sourceExists(processRunning: true, axResult: .invalidUIElement, listed: false))
        XCTAssertTrue(state.sourceExists(processRunning: true, axResult: .invalidUIElement, listed: false))
        XCTAssertFalse(state.sourceExists(processRunning: true, axResult: .invalidUIElement, listed: false))
    }
    func testRestoreRequiresConfirmedUnminimizedState() {
        XCTAssertFalse(MirrorLifecycle.shouldResume(waiting: true, minimized: nil))
        XCTAssertFalse(MirrorLifecycle.shouldResume(waiting: true, minimized: true))
        XCTAssertTrue(MirrorLifecycle.shouldResume(waiting: true, minimized: false))
        XCTAssertFalse(MirrorLifecycle.shouldResume(waiting: false, minimized: false))
    }

    func testCaptureAcceptsPixelRoundingWithoutAcceptingOldSize() {
        let source = CGSize(width: 800.5, height: 500.5)
        XCTAssertTrue(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1600, height: 1000), content: source, source: source, scale: 2))
        XCTAssertFalse(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1590, height: 1000), content: source, source: source, scale: 2))
    }
    func testIndependentResizeRejectsStretchedAndLetterboxedFrames() {
        let size = CGSize(width: 800, height: 500)
        XCTAssertTrue(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1600, height: 1000), content: size, source: size, scale: 2))
        XCTAssertFalse(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1200, height: 1000), content: size, source: size, scale: 2))
        XCTAssertFalse(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1600, height: 1000), content: CGSize(width: 600, height: 500), source: size, scale: 2))
        XCTAssertFalse(MirrorGeometry.coherentCapture(pixels: CGSize(width: 1600, height: 1000), content: nil, source: size, scale: 2))
    }
    func testBrowserTabTextIsNeverTreatedAsTitleChrome() {
        XCTAssertTrue(AXBridge.hasInteractiveTitleRole(["AXStaticText", "AXRadioButton", "AXTabGroup"]))
        XCTAssertTrue(AXBridge.hasInteractiveTitleRole(["AXStaticText", "AXTab", "AXGroup"]))
        XCTAssertTrue(AXBridge.hasInteractiveTitleRole(["AXImage", "AXButton"]))
        XCTAssertFalse(AXBridge.hasInteractiveTitleRole(["AXGroup", "AXTabGroup"]))
        XCTAssertFalse(AXBridge.hasInteractiveTitleRole(["AXTitleUIElement"]))
    }

    func testStaleCaptureCannotReplaceNativeResizePresentation() {
        let expected = CGSize(width: 1600, height: 1000)
        XCTAssertFalse(MirrorGeometry.presentationMatches(actualPixels: CGSize(width: 1600, height: 900), expectedPixels: expected))
        XCTAssertFalse(MirrorGeometry.presentationMatches(actualPixels: CGSize(width: 1200, height: 1000), expectedPixels: expected))
        XCTAssertTrue(MirrorGeometry.presentationMatches(actualPixels: expected, expectedPixels: expected))
        XCTAssertFalse(MirrorGeometry.presentationMatches(actualPixels: .zero, expectedPixels: .zero))
    }

    func testAllFourEdgesAndCornersAreResizeTargets() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let cases: [(CGPoint, Int)] = [
            (CGPoint(x: 10, y: 200), 1), (CGPoint(x: 590, y: 200), 2),
            (CGPoint(x: 300, y: 10), 4), (CGPoint(x: 300, y: 390), 8),
            (CGPoint(x: 18, y: 18), 5), (CGPoint(x: 582, y: 18), 6),
            (CGPoint(x: 18, y: 382), 9), (CGPoint(x: 582, y: 382), 10),
            (CGPoint(x: 300, y: 200), 0), (CGPoint(x: -1, y: 200), 0)
        ]
        for (point, expected) in cases { XCTAssertEqual(MirrorGeometry.resizeEdges(at: point, bounds: bounds), expected) }
    }

    func testSideResizeChangesOnlyOneAxis() {
        let initial = CGRect(x: 100, y: 200, width: 600, height: 400)
        for edge in [1, 2] {
            let frame = MirrorGeometry.resizedFrame(initial, delta: CGPoint(x: 30, y: 70), edges: edge)
            XCTAssertEqual(frame.minY, initial.minY); XCTAssertEqual(frame.height, initial.height)
            XCTAssertNotEqual(frame.width, initial.width)
        }
        for edge in [4, 8] {
            let frame = MirrorGeometry.resizedFrame(initial, delta: CGPoint(x: 30, y: 70), edges: edge)
            XCTAssertEqual(frame.minX, initial.minX); XCTAssertEqual(frame.width, initial.width)
            XCTAssertNotEqual(frame.height, initial.height)
        }
    }

    func testSynchronizedScreenFrameRoundTripsAcrossDisplays() {
        for frame in [CGRect(x: -1400, y: 150, width: 900, height: 700), CGRect(x: 150, y: -800, width: 700, height: 500)] {
            let quartz = MirrorGeometry.screenFrame(frame, desktopTop: 1080)
            XCTAssertEqual(quartz.minY, 1080 - frame.maxY)
            XCTAssertEqual(MirrorGeometry.screenFrame(quartz, desktopTop: 1080), frame)
            XCTAssertTrue(MirrorGeometry.sameFrame(frame, frame.offsetBy(dx: 0.5, dy: -0.5)))
            XCTAssertFalse(MirrorGeometry.sameFrame(frame, frame.offsetBy(dx: 15, dy: 0)))
        }
    }

    func testNativeCoordinatesStayOneToOneWhenSourceAndMirrorMatch() throws {
        let source = CGRect(x: -800, y: 120, width: 700, height: 480)
        let local = CGPoint(x: 130, y: 200)
        let mapped = try XCTUnwrap(MirrorGeometry.targetPoint(local, source: source, bounds: CGRect(origin: .zero, size: source.size)))
        XCTAssertEqual(mapped.x, -670, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 400, accuracy: 0.001)
    }

    func testTitleHitNeverIncludesContentOrLetterboxingAfterResize() {
        let source = CGSize(width: 1000, height: 500)
        for bounds in [CGRect(x: 0, y: 0, width: 500, height: 500), CGRect(x: 0, y: 0, width: 1400, height: 300)] {
            let image = MirrorGeometry.imageRect(source: source, bounds: bounds)
            XCTAssertTrue(MirrorGeometry.isTitle(CGPoint(x: image.midX, y: image.maxY - 2), source: source, bounds: bounds))
            XCTAssertFalse(MirrorGeometry.isTitle(CGPoint(x: image.midX, y: image.midY), source: source, bounds: bounds))
            XCTAssertFalse(MirrorGeometry.isTitle(CGPoint(x: image.midX, y: image.maxY + 2), source: source, bounds: bounds))
            XCTAssertFalse(MirrorGeometry.isTitle(CGPoint(x: image.minX + 2, y: image.maxY - 2), source: source, bounds: bounds))
        }
    }

    func testSettingsAnchoredBelowIconOnMultipleDisplays() {
        let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        let anchor = CGRect(x: -500, y: 1050, width: 24, height: 30)
        let size = CGSize(width: 290, height: 536)
        let origin = MirrorGeometry.settingsOrigin(anchor: anchor, size: size, visible: visible)
        XCTAssertEqual(origin.x + size.width / 2, anchor.midX)
        XCTAssertEqual(origin.y + size.height, anchor.minY - 6)
        let edge = MirrorGeometry.settingsOrigin(anchor: CGRect(x: -20, y: 1050, width: 20, height: 30), size: size, visible: visible)
        XCTAssertLessThanOrEqual(edge.x + size.width, visible.maxX - 6)
    }

    func testResizeKeepsOppositeCornerAndMinimumSize() {
        let initial = CGRect(x: 100, y: 200, width: 800, height: 600)
        let smaller = MirrorGeometry.resizedFrame(initial, delta: CGPoint(x: 900, y: 900), edges: 1 | 4)
        XCTAssertEqual(smaller.width, 240)
        XCTAssertEqual(smaller.height, 140)
        XCTAssertEqual(smaller.maxX, initial.maxX)
        XCTAssertEqual(smaller.maxY, initial.maxY)
        let larger = MirrorGeometry.resizedFrame(initial, delta: CGPoint(x: 100, y: -50), edges: 2 | 4)
        XCTAssertEqual(larger.size, CGSize(width: 900, height: 650))
        XCTAssertEqual(larger.minX, initial.minX)
        XCTAssertEqual(larger.maxY, initial.maxY)
    }

    func testInputUsesDisplayedImageWhileSourceResizeIsPending() throws {
        // The new source is square, but the last captured image still has a 2:1 aspect.
        let target = CGRect(x: 100, y: 200, width: 800, height: 800)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let displayed = CGSize(width: 1000, height: 500)
        XCTAssertNil(MirrorGeometry.targetPoint(CGPoint(x: 200, y: 50), source: target, bounds: bounds, displayedSize: displayed))
        let mapped = try XCTUnwrap(MirrorGeometry.targetPoint(CGPoint(x: 250, y: 375), source: target, bounds: bounds, clamp: true, displayedSize: displayed))
        XCTAssertEqual(mapped, CGPoint(x: 500, y: 200))
    }

    func testScaledWindowCoordinatesOnLeftHandDisplay() throws {
        let source = CGRect(x: -1600, y: 100, width: 1200, height: 800)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let result = try XCTUnwrap(MirrorGeometry.targetPoint(CGPoint(x: 150, y: 300), source: source, bounds: bounds))
        XCTAssertEqual(result.x, -1300, accuracy: 0.001)
        XCTAssertEqual(result.y, 300, accuracy: 0.001)
    }

    func testLetterboxingIsNotInteractive() {
        let source = CGRect(x: 100, y: -900, width: 1000, height: 500)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        XCTAssertNil(MirrorGeometry.targetPoint(CGPoint(x: 200, y: 50), source: source, bounds: bounds))
        XCTAssertEqual(MirrorGeometry.targetPoint(CGPoint(x: 250, y: 250), source: source, bounds: bounds), CGPoint(x: 600, y: -650))
    }

    func testDragReleaseOutsideImageClampsToSource() throws {
        let source = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let point = try XCTUnwrap(MirrorGeometry.targetPoint(CGPoint(x: -200, y: 800), source: source,
                                                          bounds: CGRect(x: 0, y: 0, width: 500, height: 500), clamp: true))
        XCTAssertEqual(point, CGPoint(x: 100, y: 200))
        XCTAssertNil(MirrorGeometry.targetPoint(.zero, source: .zero, bounds: source))
    }

    func testMousePacketTargetsSpecificWindowAndPreservesDoubleClick() throws {
        let original = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                             mouseCursorPosition: CGPoint(x: 10, y: 20), mouseButton: .left))
        original.flags = [.maskShift]
        original.setIntegerValueField(.mouseEventClickState, value: 2)
        let result = try XCTUnwrap(MirrorEventRouter.addressedCopy(original, point: CGPoint(x: -500, y: 600), windowID: 1234, pid: 4321))
        XCTAssertEqual(result.location, CGPoint(x: -500, y: 600))
        XCTAssertEqual(original.location, CGPoint(x: 10, y: 20))
        XCTAssertEqual(result.getIntegerValueField(.eventTargetUnixProcessID), 4321)
        XCTAssertEqual(result.getIntegerValueField(.mouseEventWindowUnderMousePointer), 1234)
        XCTAssertEqual(result.getIntegerValueField(.eventSourceUserData), MirrorEventRouter.marker)
        XCTAssertEqual(result.getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertTrue(result.flags.contains(.maskShift))
    }

    func testScrollCopiesSmoothHorizontalDeltaAndMomentum() throws {
        let original = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 5, wheel3: 0))
        original.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -12.5)
        original.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        let result = try XCTUnwrap(MirrorEventRouter.addressedCopy(original, point: .zero, windowID: 3, pid: 4))
        for field: CGEventField in [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                                   .scrollWheelEventMomentumPhase, .scrollWheelEventIsContinuous] {
            XCTAssertEqual(result.getDoubleValueField(field), original.getDoubleValueField(field))
        }
        XCTAssertEqual(result.type, .scrollWheel)
    }
}
