import Foundation
import AppKit
import CoreGraphics

// MARK: - 手势引擎
//
// 两套 CGEventTap：
//   1) 只监听（listenOnly）抓左键，用于「长按标题栏」——不拦截，零副作用；
//   2) 可拦截（defaultTap）抓右键 / 中键 / Esc，命中标题栏时吞掉原事件。
//
// 与 cclose(AutoHotkey) 的对应关系：
//   ~LButton + 定时 KeyWait 1s  →  左键按下后起定时器，抬起或移动即取消
//   RButton + KeyWait 0.4s      →  0.35s 内抬起=最小化；超时=还原为普通右键
//   MButton::PostMessage SC_CLOSE → 中键吞掉并关闭窗口
//   ~Esc 双击                  →  两次 Esc 在 0.5s 内 = 关闭前台窗口

final class GestureEngine {

    /// 自己合成的鼠标事件打上标记，避免被自己二次处理
    private let syntheticMagic: Int64 = 0x4343_4C53  // "CCLS"

    private var listenTap: CFMachPort?
    private var actionTap: CFMachPort?
    private var listenSource: CFRunLoopSource?
    private var actionSource: CFRunLoopSource?

    // 左键
    private var leftDownPoint: CGPoint?
    private var leftHeld = false
    private var holdTimer: DispatchWorkItem?
    private var pendingPinHit: WindowHit?

    // 右键
    private var rightSwallowed = false
    private var rightHit: WindowHit?
    private var rightDownPoint: CGPoint?
    private var rightSyntheticSent = false
    private var rightTimer: DispatchWorkItem?

    // 中键
    private var middleSwallowed = false

    // Esc
    private var lastEscTime: CFTimeInterval = 0

    // MARK: 对外回调（都切到主线程执行，避免 AX 调用阻塞事件流）

    var onTogglePin: ((WindowHit) -> Void)?
    var onPinArmed: ((WindowHit) -> Void)?
    var onMinimize: ((WindowHit) -> Void)?
    var onClose: ((WindowHit) -> Void)?
    var onCloseFrontmost: (() -> Void)?

    /// 鼠标左键移动超过这个距离就认为用户在拖窗，不算长按。
    static let moveCancelDistance: CGFloat = 8.0
    /// 触控板的按下位置与随后拖动事件常有细微偏差。
    static let trackpadMoveCancelDistance: CGFloat = 12.0
    /// --debug 时打印每一个事件的处理结论
    static var debugEnabled = false

    var isRunning: Bool { listenTap != nil && actionTap != nil }

    private func dbg(_ message: String) {
        guard GestureEngine.debugEnabled else { return }
        let stamp = String(format: "%.2f", ProcessInfo.processInfo.systemUptime)
        if let data = "[\(stamp)] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func dbgTrace(_ trace: [String]) {
        guard GestureEngine.debugEnabled else { return }
        for line in trace { dbg("  " + line) }
    }

    // MARK: 生命周期

    @discardableResult
    func start() -> Bool {
        stop()
        AXBridge.prepare()
        guard AXBridge.isTrusted() else { return false }

        let listenMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)

        let actionMask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let listen = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: listenMask,
                                             callback: GestureEngine.tapCallback,
                                             userInfo: userInfo),
              let action = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: actionMask,
                                             callback: GestureEngine.tapCallback,
                                             userInfo: userInfo)
        else {
            dbg("事件 tap 创建失败（listen 或 action），检查辅助功能权限")
            return false
        }

        dbg("事件 tap 创建成功，开始采集")

        listenTap = listen
        actionTap = action
        listenSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, listen, 0)
        actionSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, action, 0)

        if let listenSource = listenSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), listenSource, .commonModes)
        }
        if let actionSource = actionSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), actionSource, .commonModes)
        }

        CGEvent.tapEnable(tap: listen, enable: true)
        CGEvent.tapEnable(tap: action, enable: true)
        return true
    }

    func stop() {
        holdTimer?.cancel()
        holdTimer = nil
        rightTimer?.cancel()
        rightTimer = nil

        if let listenSource = listenSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), listenSource, .commonModes)
        }
        if let actionSource = actionSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), actionSource, .commonModes)
        }
        if let listenTap = listenTap {
            CGEvent.tapEnable(tap: listenTap, enable: false)
            CFMachPortInvalidate(listenTap)
        }
        if let actionTap = actionTap {
            CGEvent.tapEnable(tap: actionTap, enable: false)
            CFMachPortInvalidate(actionTap)
        }

        listenSource = nil
        actionSource = nil
        listenTap = nil
        actionTap = nil
        leftHeld = false
        pendingPinHit = nil
        rightSwallowed = false
        rightHit = nil
        rightDownPoint = nil
        rightSyntheticSent = false
        middleSwallowed = false
    }

    // MARK: Tap 回调

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let engine = Unmanaged<GestureEngine>.fromOpaque(userInfo).takeUnretainedValue()
        return engine.handle(type: type, event: event, proxy: proxy)
    }

    private func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        // 自己合成的事件直接放行
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMagic {
            return Unmanaged.passUnretained(event)
        }

        // 系统因超时/用户输入关闭了 tap，自动重开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            dbg("系统临时关闭了 tap（\(type == .tapDisabledByTimeout ? "超时" : "用户输入")），已重新开启")
            if let listenTap = listenTap { CGEvent.tapEnable(tap: listenTap, enable: true) }
            if let actionTap = actionTap { CGEvent.tapEnable(tap: actionTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if Prefs.shared.paused {
            return Unmanaged.passUnretained(event)
        }

        // AX hit-testing can see through our nonactivating mirror to a source title bar.
        // Let our own views route these presses; never run global window gestures twice.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
            let point = NSPoint(x: event.location.x, y: screenTop - event.location.y)
            if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) && ($0 is MirrorPanel || $0.level == .popUpMenu) }) {
                return Unmanaged.passUnretained(event)
            }
        }

        switch type {
        case .leftMouseDown:
            handleLeftDown(event)
        case .leftMouseDragged:
            handleLeftDragged(event)
        case .leftMouseUp:
            handleLeftUp(event)
        case .rightMouseDown:
            return handleRightDown(event)
        case .rightMouseUp:
            return handleRightUp(event)
        case .rightMouseDragged:
            return handleRightDragged(event)
        case .otherMouseDown:
            return handleOtherDown(event)
        case .otherMouseUp:
            return handleOtherUp(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: 左键长按 → 置顶

    private func handleLeftDown(_ event: CGEvent) {
        guard Prefs.shared.pinEnabled else { return }
        leftHeld = true
        leftDownPoint = event.location
        dbg("左键 down @ \(Int(event.location.x)),\(Int(event.location.y))，起 \(Prefs.shared.holdSeconds)s 定时器")

        holdTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireHold() }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.shared.holdSeconds, execute: work)
    }

    private func handleLeftDragged(_ event: CGEvent) {
        guard leftHeld, let start = leftDownPoint else { return }
        let current = event.location
        let distance = hypot(current.x - start.x, current.y - start.y)
        let cancelDistance = currentMoveCancelDistance
        if distance > cancelDistance {
            dbg("左键拖动了 \(String(format: "%.1f", distance))px > \(Int(cancelDistance))px，取消长按")
            cancelHold()
        }
    }

    private func handleLeftUp(_ event: CGEvent) {
        let pending = pendingPinHit
        let start = leftDownPoint
        leftHeld = false
        pendingPinHit = nil
        cancelHold()

        guard let hit = pending,
              let start = start,
              hypot(event.location.x - start.x, event.location.y - start.y) <= currentMoveCancelDistance
        else { return }

        // 等原窗口的鼠标抬起/拖动会话结束后，再创建镜像，避免捕获中间状态。
        dbg("长按已松开，准备切换置顶")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.onTogglePin?(hit)
        }
    }

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
        pendingPinHit = nil
    }

    private func fireHold() {
        guard leftHeld, Prefs.shared.pinEnabled, !Prefs.shared.paused else { return }
        guard let start = leftDownPoint else { return }

        let current = CGEvent(source: nil)?.location ?? start
        let cancelDistance = currentMoveCancelDistance
        guard hypot(current.x - start.x, current.y - start.y) <= cancelDistance else {
            dbg("长按到期时鼠标已经移动，不触发")
            return
        }

        // 触控板拖动事件可能自带几个像素的坐标偏差。先判定按下点，再以当前点兜底。
        let candidatePoints = Prefs.shared.trackpadCompatibility && current != start
            ? [start, current]
            : [current]
        let evaluation = firstTitleBarEvaluation(at: candidatePoints)
        dbg("长按到期，开始判定 @ \(Int(evaluation.point.x)),\(Int(evaluation.point.y))")
        dbgTrace(evaluation.trace)

        guard let hit = evaluation.hit, hit.isTitleBar else {
            dbg("  → 不是标题栏，不置顶")
            return
        }
        guard !Prefs.shared.isBlacklisted(hit.bundleId) else {
            dbg("  → \(hit.bundleId ?? "?") 在黑名单里，跳过")
            return
        }

        pendingPinHit = hit
        DispatchQueue.main.async { [weak self] in
            self?.onPinArmed?(hit)
        }
    }

    // MARK: 右键 → 最小化（长按还原为普通右键）

    private func handleRightDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Prefs.shared.rightClickMinimize else {
            return Unmanaged.passUnretained(event)
        }
        let evaluation = AXBridge.evaluate(at: event.location)
        guard let hit = evaluation.hit, hit.isTitleBar, !Prefs.shared.isBlacklisted(hit.bundleId) else {
            if GestureEngine.debugEnabled {
                dbg("右键 down：不处理")
                dbgTrace(evaluation.trace)
            }
            return Unmanaged.passUnretained(event)
        }
        dbg("右键 down 命中标题栏「\(hit.appName)」，\(Prefs.shared.rightClickDelay)s 内抬起即最小化")

        rightSwallowed = true
        rightHit = hit
        rightDownPoint = event.location
        rightSyntheticSent = false

        rightTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.replayRightClick(at: nil) }
        rightTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.shared.rightClickDelay, execute: work)

        return nil  // 吞掉 down
    }

    /// 按住超过阈值：补发一个真实右键，保证「长按右键」仍然是普通右键菜单
    private func replayRightClick(at requestedPoint: CGPoint?) {
        guard rightSwallowed, !rightSyntheticSent else { return }

        let location = requestedPoint ?? CGEvent(source: nil)?.location ?? rightDownPoint ?? .zero
        guard let source = CGEventSource(stateID: .hidSystemState),
              let synthetic = CGEvent(mouseEventSource: source,
                                      mouseType: .rightMouseDown,
                                      mouseCursorPosition: location,
                                      mouseButton: .right)
        else {
            dbg("右键长按：无法补发系统右键事件")
            return
        }
        synthetic.setIntegerValueField(.eventSourceUserData, value: syntheticMagic)
        synthetic.post(tap: .cghidEventTap)
        rightSyntheticSent = true
    }

    private func handleRightDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard rightSwallowed, let start = rightDownPoint else {
            return Unmanaged.passUnretained(event)
        }
        if hypot(event.location.x - start.x, event.location.y - start.y) > currentMoveCancelDistance {
            rightTimer?.cancel()
            rightTimer = nil
            dbg("右键发生拖动，还原为普通系统右键")
            replayRightClick(at: start)
            return rightSyntheticSent ? Unmanaged.passUnretained(event) : nil
        }
        return nil
    }

    private func handleRightUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        rightTimer?.cancel()
        rightTimer = nil

        guard rightSwallowed else {
            return Unmanaged.passUnretained(event)
        }
        let start = rightDownPoint

        if let start = start,
           hypot(event.location.x - start.x, event.location.y - start.y) > currentMoveCancelDistance {
            replayRightClick(at: start)
            rightSwallowed = false
            rightDownPoint = nil
            rightHit = nil
            return rightSyntheticSent ? Unmanaged.passUnretained(event) : nil
        }

        // 已经补发过右键：这次抬起交给系统，形成一次完整的右键点击
        if rightSyntheticSent {
            rightSwallowed = false
            rightDownPoint = nil
            rightSyntheticSent = false
            rightHit = nil
            return Unmanaged.passUnretained(event)
        }

        let hit = rightHit
        rightSwallowed = false
        rightDownPoint = nil
        rightHit = nil
        if let hit = hit {
            DispatchQueue.main.async { [weak self] in
                self?.onMinimize?(hit)
            }
        }
        return nil  // 吞掉 up
    }

    // MARK: 中键 → 关闭

    private func handleOtherDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Prefs.shared.middleClickClose else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }
        let evaluation = AXBridge.evaluate(at: event.location)
        guard let hit = evaluation.hit, hit.isTitleBar, !Prefs.shared.isBlacklisted(hit.bundleId) else {
            if GestureEngine.debugEnabled {
                dbg("中键 down：不处理")
                dbgTrace(evaluation.trace)
            }
            return Unmanaged.passUnretained(event)
        }
        dbg("中键 down 命中标题栏「\(hit.appName)」，关闭窗口")

        middleSwallowed = true
        DispatchQueue.main.async { [weak self] in
            self?.onClose?(hit)
        }
        return nil
    }

    private func handleOtherUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard middleSwallowed, event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }
        middleSwallowed = false
        return nil
    }

    // MARK: 双击 Esc → 关闭前台窗口

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Prefs.shared.doubleEscClose else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let now = CFAbsoluteTimeGetCurrent()
        dbg("Esc 按下（距上次 \(String(format: "%.2f", lastEscTime > 0 ? now - lastEscTime : -1))s）")
        if lastEscTime > 0, now - lastEscTime <= Prefs.shared.escInterval {
            lastEscTime = 0
            DispatchQueue.main.async { [weak self] in
                self?.onCloseFrontmost?()
            }
        } else {
            lastEscTime = now
        }
        // Esc 本身放行，避免破坏输入框 / 编辑器的取消语义
        return Unmanaged.passUnretained(event)
    }

    // MARK: 辅助

    private var currentMoveCancelDistance: CGFloat {
        Prefs.shared.trackpadCompatibility
            ? GestureEngine.trackpadMoveCancelDistance
            : GestureEngine.moveCancelDistance
    }

    private func firstTitleBarEvaluation(at points: [CGPoint])
        -> (point: CGPoint, trace: [String], hit: WindowHit?) {
        var fallbackTrace: [String] = []
        var fallbackPoint = points.first ?? .zero
        for point in points {
            let evaluation = AXBridge.evaluate(at: point)
            fallbackPoint = point
            fallbackTrace = evaluation.trace
            if evaluation.hit?.isTitleBar == true {
                return (point, evaluation.trace, evaluation.hit)
            }
        }
        return (fallbackPoint, fallbackTrace, nil)
    }
}
