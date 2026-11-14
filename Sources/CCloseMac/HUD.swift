import AppKit

// MARK: - 轻量提示浮层
//
// cclose 用 Windows ToolTip 播报「Always on top / Not always on top」；
// macOS 这里换成鼠标附近的一个胶囊提示，1 秒后自动消失。

final class HUD {

    static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func prepare() {
        DispatchQueue.main.async { _ = self.panelInstance() }
    }

    func flash(_ text: String, near cgPoint: CGPoint? = nil) {
        if Thread.isMainThread {
            show(text, at: cgPoint)
        } else {
            DispatchQueue.main.async { self.show(text, at: cgPoint) }
        }
    }

    // MARK: 内部

    private func show(_ text: String, at cgPoint: CGPoint?) {
        let panel = panelInstance()
        guard let label = label else { return }

        label.stringValue = text
        label.sizeToFit()

        let paddingX: CGFloat = 14
        let paddingY: CGFloat = 10
        let width = label.frame.width + paddingX * 2
        let height = max(label.frame.height + paddingY * 2, 34)

        let anchor = appKitPoint(fromCG: cgPoint ?? CGEvent(source: nil)?.location ?? .zero)
        var origin = CGPoint(x: anchor.x + 16, y: anchor.y - height - 16)

        if let screen = screenContaining(appKitPoint: anchor) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        }

        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        label.setFrameOrigin(NSPoint(x: paddingX, y: (height - label.frame.height) / 2))

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
        })
    }

    private func panelInstance() -> NSPanel {
        if let panel = panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 9

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        container.addSubview(textField)

        panel.contentView = container
        self.panel = panel
        self.label = textField
        return panel
    }

    /// CG 全局坐标（左上原点）→ AppKit 全局坐标（左下原点，以主屏为基准）
    private func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }

    private func screenContaining(appKitPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
