import AppKit
@preconcurrency import ApplicationServices
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// One interactive mirror; its geometry follows the real window, including application size constraints.
final class PinManager {
    static let shared = PinManager()
    private var session: MirrorSession?
    private var requestID = UUID()
    private var pending = false
    var pinnedCount: Int { session == nil ? 0 : 1 }
    var isStarting: Bool { pending }
    func resume() { session?.resume() }
    func visitOriginal() { session?.visitOriginal() }
    func resetSize() { session?.resetSize() }

    func isPinned(_ window: AXUIElement) -> Bool {
        session.map { CFEqual($0.window, window) } ?? false
    }

    func toggle(_ window: AXUIElement, title: String?) {
        if isPinned(window) { unpinAll(); return }
        guard CGPreflightScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "实时悬浮需要屏幕录制权限"
            alert.informativeText = "仅捕获选中的窗口，在本机内存中显示，不录制文件、不采集音频。授权后如未生效，请从菜单重新启动 cclose-mac，再长按标题栏。"
            alert.addButton(withTitle: "授权屏幕录制")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if !CGRequestScreenCaptureAccess() { Permissions.openScreenRecordingSettings() }
            }
            return
        }
        unpinAll()
        let id = requestID
        pending = true
        HUD.shared.flash("正在创建实时悬浮…")
        Task { @MainActor [self] in
            do {
                await DesktopMode.shared.waitForCleanup()
                guard self.requestID == id else { return }
                guard !DesktopMode.shared.needsRecovery else { throw DesktopFailure("请先在设置中恢复独立桌面") }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.requestID == id else { return }
                var pid: pid_t = 0
                AXUIElementGetPid(window, &pid)
                guard let rect = AXBridge.frame(of: window),
                      let wid = AXBridge.windowID(window),
                      let source = content.windows.first(where: { $0.windowID == wid && $0.owningApplication?.processID == pid }) else {
                    throw MirrorError.message("找不到可捕获窗口，请确认窗口未关闭或最小化")
                }
                let mirror = MirrorSession(window: window, source: source, frame: rect)
                self.session = mirror
                mirror.onDismiss = { [weak self, weak mirror] in
                    guard let self, let mirror, self.session === mirror else { return }
                    self.unpinAll()
                    Task { @MainActor in
                        await DesktopMode.shared.waitForCleanup()
                        guard !DesktopMode.shared.needsRecovery else { return }
                        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                        _ = AXBridge.raise(window)
                        HUD.shared.flash("已取消悬浮")
                    }
                }
                mirror.onFailure = { [weak self, weak mirror] message in
                    guard let self, let mirror, self.session === mirror else { return }
                    self.unpinAll()
                    HUD.shared.flash(message)
                }
                try await mirror.start()
                guard self.requestID == id else { mirror.stop(); return }
                if DesktopMode.shared.enabled {
                    mirror.prepareIsolation()
                    try await DesktopMode.shared.prepare(pid: pid, windowID: wid)
                    guard self.requestID == id else { mirror.stop(); DesktopMode.shared.requestFinish(); return }
                    mirror.finishIsolation()
                }
                self.pending = false
            } catch {
                guard self.requestID == id else { return }
                self.unpinAll()
                await DesktopMode.shared.waitForCleanup()
                let alert = NSAlert()
                alert.messageText = "无法创建实时悬浮"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func unpinAll() {
        requestID = UUID()
        pending = false
        let old = session
        session = nil
        old?.stop()
        DesktopMode.shared.requestFinish()
    }

    func prune() {
        guard let session, !pending, !DesktopMode.shared.busy else { return }
        if !session.sourceExists {
            unpinAll()
            HUD.shared.flash("原窗口已关闭，已结束悬浮")
        } else {
            session.refreshSource()
        }
    }
}

private enum MirrorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class MirrorSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let window: AXUIElement
    private(set) var sourceSize: CGSize
    var onDismiss: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let source: SCWindow
    private let panel: MirrorPanel
    private let picture: MirrorView
    private var stream: SCStream?
    private var stopped = false
    private var receivedFrame = false
    private var independent = false
    private var independentPresentationFrame: CGRect?
    private var lastPresentedSourceFrame: CGRect = .zero
    private var recoveringResize = false
    private var captureRecoveryInFlight = false
    private let resizeFeedback = ResizeFeedback()
    #if DEBUG
    private var qaHoldFrames = false
    #endif
    private var latestCaptureImage: (CGImage, CGRect?)?
    private var preparingIsolation = false
    private var titleCells: [CGRect] = []
    private var titleHitCache: [String: (Bool, TimeInterval)] = [:]
    private var lastNativeCheck: TimeInterval = 0
    private var lastHoverRaise: TimeInterval = 0
    var sourceExists: Bool {
        if independent {
            return (try? DesktopBridge.shared.windows().contains { $0.id == source.windowID && $0.pid == pid }) ?? true
        }
        return AXBridge.isAlive(window)
    }
    private var suspended = false
    private var returningToSource = false
    private var waitingForSourceRestore = false
    private var resizePending = false
    private var pid: pid_t = 0
    private var appearanceObserver: NSObjectProtocol?
    private var sourceFrame: CGRect = .zero
    private var sourceAppElement: AXUIElement?
    private var presentationSuppressed = false
    private var expectedPresentationPixels: CGSize?
    private var latestFramePixels = CGSize.zero
    private var resizePresentationID = UUID()
    private var initialSize: CGSize = .zero
    private var pendingFrame: CGRect?
    private var geometryWork: DispatchWorkItem?
    private var geometryBusy = false
    private let geometryQueue = DispatchQueue(label: "cclose.geometry", qos: .userInteractive)
    private var captureResizeWork: DispatchWorkItem?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var zoomRestoreFrame: CGRect?
    private var nativeTimer: Timer?
    private var nativeButtons: [Int: CGEvent] = [:]
    private var lastPoint: CGPoint?
    private var pressed: [Int: CGEvent] = [:]
    private let queue = DispatchQueue(label: "cclose.mirror.frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let frameSlot = DispatchSemaphore(value: 1)

    init(window: AXUIElement, source: SCWindow, frame: CGRect) {
        self.window = window
        self.source = source
        self.sourceSize = frame.size
        self.sourceFrame = frame
        self.lastPresentedSourceFrame = frame
        self.initialSize = frame.size
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let target = CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
        panel = MirrorPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        picture = MirrorView(frame: CGRect(origin: .zero, size: frame.size))
        super.init()
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = MirrorAppearance.opacity
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = picture
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.layer?.cornerRadius = 12
        picture.layer?.masksToBounds = true
        picture.refreshAppearance()
        picture.onFrameChange = { [weak self] frame, final in
            self?.zoomRestoreFrame = nil
            self?.scheduleGeometry(frame, final: final)
        }
        picture.onManipulationStart = { [weak self] in self?.beginGeometryPresentation() }
        picture.sourceTitleHit = { [weak self] point in
            guard let self, let app = self.sourceAppElement,
                  let target = MirrorGeometry.targetPoint(point, source: self.sourceFrame, bounds: self.picture.bounds) else { return false }
            if self.independent || self.preparingIsolation {
                let relative = CGPoint(x: target.x - self.sourceFrame.minX, y: target.y - self.sourceFrame.minY)
                return self.titleCells.contains { $0.contains(relative) }
            }
            let key = "\(Int(target.x / 8)),\(Int(target.y / 6)),\(Int(self.sourceFrame.width))"
            let now = ProcessInfo.processInfo.systemUptime
            if let cached = self.titleHitCache[key], now - cached.1 < 0.5 { return cached.0 }
            let hit = AXBridge.isSourceTitlePoint(target, window: self.window, app: app)
            if self.titleHitCache.count > 128 { self.titleHitCache.removeAll() }
            self.titleHitCache[key] = (hit, now)
            return hit
        }
        picture.onTitleDoubleClick = { [weak self] event, point in self?.titleDoubleClick(event, point: point) }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updateNativeInput() }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in self?.updateNativeInput(); return event }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updateNativeInput() }
        nativeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        appearanceObserver = NotificationCenter.default.addObserver(forName: MirrorAppearance.changed, object: nil, queue: .main) { [weak self] _ in
            self?.panel.alphaValue = MirrorAppearance.opacity
            self?.panel.backgroundColor = .clear
            self?.picture.refreshAppearance()
        }
        panel.title = "CClose 悬浮"
        panel.isMovableByWindowBackground = false
        picture.autoresizingMask = [.width, .height]
        AXUIElementGetPid(window, &pid)
        sourceAppElement = AXUIElementCreateApplication(pid)
        if let sourceAppElement { AXUIElementSetMessagingTimeout(sourceAppElement, 0.03) }
        AXUIElementSetMessagingTimeout(window, 0.05)
        picture.sourceSize = frame.size
        picture.toolTip = "拖原标题区域移动 · 长按取消 · 拖四边或四角缩放 · ⌘单击临时操作原窗口"
        picture.onInput = { [weak self] event, point in self?.forward(event, at: point) }
        picture.onVisit = { [weak self] in
            guard let self, !self.independent, !self.preparingIsolation else { return }
            self.visitOriginal()
        }
        picture.onDismiss = { [weak self] in self?.onDismiss?() }
        picture.onMinimize = { [weak self] in self?.minimizeSource() }
        picture.onCloseSource = { [weak self] in self?.closeSource() }
        picture.onContextMenu = { [weak self] event, point in self?.openContextMenu(event, at: point) }
        #if DEBUG
        picture.onQAHoldFrames = { [weak self] hold in self?.qaHoldFrames = hold; if !hold { self?.retryCapturePresentation() } }
        #endif
        picture.setAccessibilityLabel("CClose 实时悬浮，长按标题栏取消，四边四角缩放")
    }

    func prepareIsolation() {
        finishNativeInput(); releaseButtons()
        picture.contentInteractionEnabled = false
        // Off-Space AX hit testing is not reliable. Cache only confirmed blank title cells.
        titleCells.removeAll()
        if let app = sourceAppElement {
            for x in stride(from: 90.0, to: sourceFrame.width, by: 16.0) {
                for y in stride(from: 2.0, to: 28.0, by: 8.0) {
                    let cell = CGRect(x: x, y: y, width: min(16, sourceFrame.width - x), height: min(8, 28 - y))
                    let points = [CGPoint(x: cell.minX, y: cell.midY), CGPoint(x: cell.maxX - 1, y: cell.midY)]
                    if points.allSatisfy({ AXBridge.isSourceTitlePoint(CGPoint(x: sourceFrame.minX + $0.x, y: sourceFrame.minY + $0.y), window: window, app: app) }) { titleCells.append(cell) }
                }
            }
        }
        preparingIsolation = true; suspended = true; panel.orderOut(nil)
    }

    func finishIsolation() {
        independent = true; preparingIsolation = false; suspended = false
        picture.defersResizePresentation = true
        panel.alphaValue = MirrorAppearance.opacity
        picture.toolTip = "独立桌面仅预览，内容不响应操作 · 标题栏手势与四边缩放仍可用"
        if receivedFrame { panel.orderFrontRegardless() }
    }

    @MainActor
    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: source)
        let config = configuration(size: sourceSize)
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await capture.startCapture()
        // A stop can arrive while startCapture is suspended.
        if stopped { try? await capture.stopCapture(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.stopped, !self.receivedFrame else { return }
            self.onFailure?("没有收到窗口画面，请检查权限后重试")
        }
    }

    @MainActor
    private func configuration(size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = panel.screen?.backingScaleFactor ?? 2
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return config
    }

    func stop() {
        resizePresentationID = UUID()
        resizeFeedback.hide()
        finishNativeInput()
        releaseButtons()
        geometryWork?.cancel()
        pendingFrame = nil
        captureResizeWork?.cancel()
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        nativeTimer?.invalidate()
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        stopped = true
        panel.orderOut(nil)
        panel.close()
        picture.layer?.contents = nil
        latestCaptureImage = nil
        picture.onInput = nil
        picture.onDismiss = nil
        picture.onVisit = nil
        picture.onContextMenu = nil
        if let capture = stream {
            stream = nil
            capture.stopCapture { _ in }
        }
    }

    @objc func visitOriginal() {
        if independent {
            guard !DesktopMode.shared.busy else { return }
            finishNativeInput(); releaseButtons()
            suspended = true; returningToSource = true; panel.orderOut(nil)
            Task { @MainActor [weak self] in
                do { try await DesktopMode.shared.visitSource() }
                catch { HUD.shared.flash(error.localizedDescription) }
                self?.refreshSource()
            }
            return
        }
        finishNativeInput()
        releaseButtons()
        suspended = true
        returningToSource = true
        panel.orderOut(nil)
        AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, kCFBooleanFalse)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        _ = AXBridge.raise(window)
        HUD.shared.flash("已临时返回原窗口 · 切换其他应用后恢复悬浮")
    }

    func resume() {
        guard !stopped else { return }
        AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, kCFBooleanFalse)
        suspended = false
        waitingForSourceRestore = false
        returningToSource = false
        if receivedFrame { panel.orderFrontRegardless() }
    }

    func resetSize() {
        var frame = panel.frame
        frame.origin.y += frame.height - initialSize.height
        frame.size = initialSize
        scheduleGeometry(frame, final: true)
    }

    private func beginGeometryPresentation() {
        resizePresentationID = UUID()
        recoveringResize = false
        guard !independent, !preparingIsolation else { return }
        guard !presentationSuppressed else { return }
        finishNativeInput()
        activateSourceForInput()
        _ = AXBridge.raise(window)
        presentationSuppressed = true
        expectedPresentationPixels = nil
        resizePresentationID = UUID()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.layer?.opacity = 0
        CATransaction.commit()
        panel.hasShadow = false
    }

    private func finishGeometryPresentation(for actual: CGRect) {
        if independent {
            guard !geometryBusy, pendingFrame == nil, !picture.isManipulating, !recoveringResize,
                  independentPresentationFrame != nil else { return }
            let id = UUID(); resizePresentationID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.stopped, self.resizePresentationID == id,
                      self.independentPresentationFrame != nil, !self.picture.isManipulating else { return }
                Task { @MainActor [weak self] in await self?.recoverIndependentCapture(id: id) }
            }
            return
        }
        guard presentationSuppressed, !geometryBusy, pendingFrame == nil, !picture.isManipulating else { return }
        let scale = panel.screen?.backingScaleFactor ?? 2
        expectedPresentationPixels = CGSize(width: max(1, Int(actual.width * scale)), height: max(1, Int(actual.height * scale)))
        restorePresentationIfReady()
        guard presentationSuppressed else { return }
        let id = resizePresentationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped, self.resizePresentationID == id,
                  self.presentationSuppressed, !self.picture.isManipulating else { return }
            // Keep the usable real window rather than showing a stretched/stale mirror.
            self.onFailure?("窗口画面未及时更新，已返回原窗口")
        }
    }

    private func restorePresentationIfReady() {
        guard presentationSuppressed, !resizePending, !geometryBusy, pendingFrame == nil,
              !picture.isManipulating, let expectedPresentationPixels,
              MirrorGeometry.presentationMatches(actualPixels: latestFramePixels, expectedPixels: expectedPresentationPixels) else { return }
        presentationSuppressed = false
        self.expectedPresentationPixels = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.layer?.opacity = 1
        CATransaction.commit()
        panel.hasShadow = true
    }

    private func scheduleGeometry(_ frame: CGRect, final: Bool) {
        if independent { resizeFeedback.show(frame) }
        if !independent && frame.size != panel.frame.size { beginGeometryPresentation() }
        panel.ignoresMouseEvents = false
        pendingFrame = frame
        if final {
            geometryWork?.cancel(); geometryWork = nil
            applyGeometry()
        } else if geometryWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.geometryWork = nil
                self?.applyGeometry()
            }
            geometryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
        }
    }

    private func applyGeometry() {
        guard !stopped, !geometryBusy, let requested = pendingFrame else { return }
        pendingFrame = nil
        geometryBusy = true
        captureResizeWork?.cancel()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let target = MirrorGeometry.screenFrame(requested, desktopTop: top)
        let previous = sourceFrame
        let sourceWindow = window
        // AX is cross-process IPC: never hold up AppKit's drag/cursor handling.
        // Only one write is in flight; new samples replace pendingFrame instead of queuing.
        geometryQueue.async { [weak self] in
            let accepted = AXBridge.setFrame(target, of: sourceWindow, currentHint: previous)
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.geometryBusy = false
                if let actual = accepted {
                    self.sourceFrame = actual
                    if self.independent {
                        self.independentPresentationFrame = MirrorGeometry.screenFrame(actual, desktopTop: top)
                    } else if self.pendingFrame == nil && !self.picture.isManipulating {
                        self.panel.setFrame(MirrorGeometry.screenFrame(actual, desktopTop: top), display: true)
                        self.picture.sourceSize = actual.size
                    }
                } else if self.pendingFrame == nil {
                    self.resizeFeedback.hide()
                    self.panel.setFrame(MirrorGeometry.screenFrame(self.sourceFrame, desktopTop: top), display: true)
                    HUD.shared.flash("此应用不允许调整窗口尺寸或位置")
                }
                if self.pendingFrame != nil { self.applyGeometry() }
                else {
                    let work = DispatchWorkItem { [weak self] in self?.refreshSource() }
                    self.captureResizeWork = work
                    // During manipulation the real source is visible. Request final capture size immediately.
                    DispatchQueue.main.async(execute: work)
                    self.retryCapturePresentation()
                    self.finishGeometryPresentation(for: self.sourceFrame)
                }
            }
        }
    }

    @MainActor
    private func recoverIndependentCapture(id: UUID) async {
        guard !stopped, resizePresentationID == id, !captureRecoveryInFlight, let old = stream else { return }
        captureRecoveryInFlight = true
        defer {
            captureRecoveryInFlight = false
            if !stopped, resizePresentationID != id {
                finishGeometryPresentation(for: sourceFrame)
            }
        }
        // A completed image can be the only frame emitted for a static window.
        // Recreate the stream once; never interpret a slow resize as an unpin request.
        stream = nil
        resizePending = false
        try? await old.stopCapture()
        guard !stopped else { return }
        let requestedSize = sourceFrame.size
        let replacement = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration(size: requestedSize), delegate: self)
        stream = replacement
        do {
            try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await replacement.startCapture()
            guard !stopped else { try? await replacement.stopCapture(); return }
            sourceSize = requestedSize
            refreshSource()
        } catch {
            // Keep the last valid image and let the user retry or cancel explicitly.
            HUD.shared.flash("画面更新暂不可用，已保留悬浮")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped, self.resizePresentationID == id,
                  self.independentPresentationFrame != nil, !self.picture.isManipulating else { return }
            self.recoveringResize = true
            self.resizeFeedback.hide()
            self.independentPresentationFrame = nil
            self.pendingFrame = MirrorGeometry.screenFrame(self.lastPresentedSourceFrame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
            self.applyGeometry()
            HUD.shared.flash("原应用未及时更新，已撤回本次缩放并保留置顶")
        }
    }

    private func titleDoubleClick(_ event: NSEvent, point: CGPoint) {
        let action = (UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize").lowercased()
        if action == "none" { return }
        if action == "minimize" { minimizeSource(); return }
        // Use the existing coalescing AX geometry queue in both modes. Synthetic
        // double-clicks can be rejected on newer macOS, and delayed fallback races restore.
        let target: CGRect
        if let restore = zoomRestoreFrame {
            zoomRestoreFrame = nil
            target = restore
        } else {
            guard let screen = panel.screen else { return }
            zoomRestoreFrame = panel.frame
            target = screen.visibleFrame
        }
        titleHitCache.removeAll()
        scheduleGeometry(target, final: true)
    }

    // With identical screen geometry, native delivery preserves menus, scrolling and IME.
    // Enable click-through only after checking the actual window directly under the mirror.
    private func beginNativeInput() -> Bool {
        guard !independent, !preparingIsolation else { return false }
        guard !stopped, !suspended, !geometryBusy, pendingFrame == nil else { return false }
        activateSourceForInput()
        _ = AXBridge.raise(window)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let actual = AXBridge.frame(of: window),
              MirrorGeometry.sameFrame(actual, MirrorGeometry.screenFrame(panel.frame, desktopTop: top)),
              targetIsBelowMirror() else { return false }
        sourceFrame = actual
        panel.ignoresMouseEvents = true
        return true
    }

    private func targetIsBelowMirror() -> Bool {
        let p = NSEvent.mouseLocation
        let point = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let transparentTools = Set(NSApp.windows.filter { $0.windowNumber > 0 && ($0 === panel || $0.ignoresMouseEvents) }.map { UInt32($0.windowNumber) })
        for entry in entries {
            guard let number = entry[kCGWindowNumber as String] as? UInt32,
                  !transparentTools.contains(number),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return number == source.windowID
        }
        return false
    }

    private func updateNativeInput() {
        guard !independent, !preparingIsolation else {
            panel.ignoresMouseEvents = false
            return
        }
        guard !picture.hasActiveGesture, NSEvent.pressedMouseButtons == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNativeCheck >= 1.0 / 30 else { return }
        lastNativeCheck = now
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard !stopped, !suspended, receivedFrame, panel.isVisible,
              !geometryBusy, pendingFrame == nil, picture.isContent(local) else {
            panel.ignoresMouseEvents = false
            return
        }
        nativeButtons.removeAll()
        // Prepare native delivery BEFORE mouse-down/scroll. Changing the recipient
        // after receiving the first event requires postToPid, which may be dropped.
        let expected = MirrorGeometry.screenFrame(panel.frame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
        guard MirrorGeometry.sameFrame(sourceFrame, expected) else {
            panel.ignoresMouseEvents = false
            return
        }
        if !targetIsBelowMirror() {
            panel.ignoresMouseEvents = false
            // Raise only underneath the mirror; do not activate or steal keyboard focus
            // on hover. Physical mouse-down performs normal macOS activation.
            if !returningToSource, now - lastHoverRaise >= 0.25 {
                lastHoverRaise = now
                _ = AXBridge.raise(window)
            }
            return
        }
        panel.ignoresMouseEvents = true
    }

    private func finishNativeInput() {
        for (button, down) in nativeButtons {
            guard let up = down.copy() else { continue }
            up.type = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            up.setDoubleValueField(.mouseEventPressure, value: 0)
            up.postToPid(pid)
        }
        nativeButtons.removeAll()
        panel.ignoresMouseEvents = false
    }

    private func minimizeSource() {
        if independent {
            onDismiss?()
            Task { @MainActor [window] in
                await DesktopMode.shared.waitForCleanup()
                if !DesktopMode.shared.needsRecovery { _ = AXBridge.minimize(window) }
            }
            return
        }
        finishNativeInput()
        releaseButtons()
        guard AXBridge.minimize(window) else { HUD.shared.flash("原窗口无法最小化"); return }
        waitingForSourceRestore = true
        suspended = true
        returningToSource = false
        panel.orderOut(nil)
        HUD.shared.flash("已最小化 · 恢复原窗口后继续悬浮")
    }

    private func closeSource() {
        if independent {
            Task { @MainActor [weak self] in
                do {
                    try await DesktopMode.shared.visitSource()
                    guard let self, !self.stopped, let button = AXBridge.child(self.window, "AXCloseButton") else { return }
                    if AXUIElementPerformAction(button, "AXPress" as CFString) != .success { HUD.shared.flash("无法关闭该窗口") }
                    self.refreshSource()
                } catch { HUD.shared.flash(error.localizedDescription) }
            }
            return
        }
        releaseButtons()
        // Do not use the old global Command-W fallback: it can close the wrong window.
        guard let button = AXBridge.child(window, "AXCloseButton"),
              AXUIElementPerformAction(button, "AXPress" as CFString) == .success else {
            HUD.shared.flash("无法关闭该窗口，请用“原窗口”操作")
            return
        }
        visitOriginal() // Expose any unsaved-document dialog; prune removes a closed source.
    }

    func refreshSource() {
        guard !preparingIsolation, !DesktopMode.shared.busy else { return }
        guard !geometryBusy, pendingFrame == nil, independent || !picture.isManipulating else { return }
        let currentFrame = AXBridge.frame(of: window)
        if let currentFrame {
            let externallyResized = !independent && currentFrame.size != sourceFrame.size
            if externallyResized { beginGeometryPresentation() }
            if independent && currentFrame.size != sourceFrame.size && independentPresentationFrame == nil {
                var frame = panel.frame
                frame.origin.y += frame.height - currentFrame.height
                frame.size = currentFrame.size
                independentPresentationFrame = frame
            }
            sourceFrame = currentFrame
            if pendingFrame == nil && !independent {
                panel.setFrame(MirrorGeometry.screenFrame(currentFrame, desktopTop: NSScreen.screens.first?.frame.maxY ?? 0), display: true)
                picture.sourceSize = currentFrame.size
            }
            if externallyResized { finishGeometryPresentation(for: currentFrame) }
        }
        if independent {
            if DesktopMode.shared.isOnOwnedDesktop() {
                suspended = true; returningToSource = true; panel.orderOut(nil)
            } else if suspended {
                suspended = false; returningToSource = false
                if receivedFrame { panel.orderFrontRegardless() }
            }
        } else if AXBridge.bool(window, "AXMinimized") == true {
            waitingForSourceRestore = true
            finishNativeInput()
            releaseButtons()
            suspended = true
            returningToSource = false
            panel.orderOut(nil)
        } else if waitingForSourceRestore {
            resume()
        } else if returningToSource, let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != pid, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            resume()
        }
        guard !resizePending, let frame = currentFrame, frame.width > 0, frame.height > 0,
              abs(frame.width - sourceSize.width) > 1 || abs(frame.height - sourceSize.height) > 1,
              let capture = stream else { return }
        releaseButtons()
        resizePending = true
        let newSize = frame.size
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            let config = self.configuration(size: newSize)
            do {
                try await capture.updateConfiguration(config)
                guard !self.stopped, self.stream === capture else { return }
                self.sourceSize = newSize
                // View geometry always describes the accepted source frame, even if a newer resize is pending.
                if !self.independent { self.picture.sourceSize = self.sourceFrame.size }
            } catch {
                guard !self.stopped, self.stream === capture else { return }
                if self.independent { HUD.shared.flash("正在恢复缩放画面…") }
                else { self.onFailure?("窗口尺寸更新失败：\(error.localizedDescription)") }
            }
            self.resizePending = false
            self.retryCapturePresentation()
            self.restorePresentationIfReady()
            if abs(self.sourceFrame.width - self.sourceSize.width) > 1 || abs(self.sourceFrame.height - self.sourceSize.height) > 1 { self.refreshSource() }
        }
    }

    private func openContextMenu(_ event: NSEvent, at point: CGPoint) {
        guard !independent, !preparingIsolation else { return }
        guard let frame = AXBridge.frame(of: window),
              let target = MirrorGeometry.targetPoint(point, source: frame, bounds: picture.bounds, displayedSize: picture.bounds.size),
              let original = event.cgEvent,
              let down = MirrorEventRouter.addressedCopy(original, point: target, windowID: source.windowID, pid: pid),
              let up = down.copy() else { return }
        // Keep the mirror visible. Hiding it here looked exactly like a minimize.
        // Native menus belong to the source process and use its screen coordinates.
        activateSourceForInput()
        up.type = .rightMouseUp
        up.setDoubleValueField(.mouseEventPressure, value: 0)
        if beginNativeInput() {
            nativeButtons[1] = down
            down.postToPid(pid) // Physical mouse-up goes to the real window.
        } else {
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    private func activateSourceForInput() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }

    private func releaseButtons() {
        for (button, down) in pressed {
            guard let up = down.copy() else { continue }
            up.type = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            up.setDoubleValueField(.mouseEventPressure, value: 0)
            up.postToPid(pid)
        }
        pressed.removeAll()
        lastPoint = nil
    }

    private func forward(_ event: NSEvent, at point: CGPoint) {
        guard !stopped, !suspended else { return }
        guard !independent, !preparingIsolation else { return }
        // Input continues while capture resolution catches up with the real window.
        // AX queries on every scroll/drag packet can stall the main thread for hundreds of ms.
        if event.type == .leftMouseDown || event.type == .otherMouseDown {
            activateSourceForInput()
            if let current = AXBridge.frame(of: window) { sourceFrame = current }
        }
        let frame = sourceFrame
        let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        let isUp = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        let isDrag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
        let button = event.buttonNumber
        if (isUp || isDrag) && pressed[button] == nil && nativeButtons[button] == nil { return }
        guard let target = MirrorGeometry.targetPoint(point, source: frame, bounds: picture.bounds, clamp: isUp || isDrag, displayedSize: picture.bounds.size),
              let original = event.cgEvent else { return }
        let delta = isDrag ? lastPoint.map { CGPoint(x: target.x - $0.x, y: target.y - $0.y) } : nil
        guard let packet = MirrorEventRouter.addressedCopy(original, point: target, windowID: source.windowID, pid: pid, delta: delta) else { return }
        // AppKit may retain the initial overlay as the drag/up recipient even after click-through.
        if nativeButtons[button] != nil && (isDrag || isUp) {
            if isUp { nativeButtons.removeValue(forKey: button) }
            packet.postToPid(pid)
            return
        }
        if (isDown || event.type == .scrollWheel), pressed.isEmpty, beginNativeInput() {
            if isDown { nativeButtons[button] = packet }
            packet.postToPid(pid)
            return
        }
        if isDown { pressed[button] = packet }
        if isDrag { pressed[button] = packet }
        if isUp { pressed.removeValue(forKey: button) }
        lastPoint = target
        packet.postToPid(pid)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.stream === stream else { return }
            self.onFailure?("实时悬浮已停止：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              frameSlot.wait(timeout: .now()) == .success else { return }
        let input = CIImage(cvPixelBuffer: buffer)
        let contentRect = (attachments.first?[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        guard let image = context.createCGImage(input, from: input.extent) else { frameSlot.signal(); return }
        DispatchQueue.main.async { [weak self, frameSlot] in
            defer { frameSlot.signal() }
            guard let self, !self.stopped, self.stream === stream else { return }
            self.present(image, contentRect: contentRect)
        }
    }

    private func retryCapturePresentation() {
        guard let (image, rect) = latestCaptureImage else { return }
        present(image, contentRect: rect)
    }

    private func present(_ image: CGImage, contentRect: CGRect?) {
        guard !stopped else { return }
        latestCaptureImage = (image, contentRect)
        #if DEBUG
        if qaHoldFrames { return }
        #endif
        let scale = self.panel.screen?.backingScaleFactor ?? 2
        guard !self.resizePending, !self.geometryBusy, self.pendingFrame == nil,
              MirrorGeometry.coherentCapture(pixels: CGSize(width: image.width, height: image.height),
                                             content: contentRect?.size,
                                             source: self.sourceFrame.size, scale: scale) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.independent {
            // Commit new geometry and its matching image together. Never stretch the old
            // bitmap across a requested frame while the off-Space application is relaying out.
            if let frame = self.independentPresentationFrame {
                self.panel.setFrame(frame, display: false)
                self.independentPresentationFrame = nil
            }
            self.picture.sourceSize = self.sourceFrame.size
        }
        self.picture.layer?.contents = image
        lastPresentedSourceFrame = sourceFrame
        resizeFeedback.hide()
        self.latestFramePixels = CGSize(width: image.width, height: image.height)
        CATransaction.commit()
        self.restorePresentationIfReady()
        if !self.receivedFrame {
            self.receivedFrame = true
            if !self.suspended { self.panel.orderFrontRegardless() }
            HUD.shared.flash("悬浮已开启 · 长按标题栏取消 · 四边四角缩放")
        }
    }
}
