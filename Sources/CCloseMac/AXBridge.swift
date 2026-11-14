import Foundation
import AppKit
import ApplicationServices

/// 一次点击的命中结果
struct WindowHit {
    let window: AXUIElement
    let frame: CGRect
    let pid: pid_t
    let bundleId: String?
    let title: String
    /// 触发本次手势的屏幕坐标，供 HUD 在用户按下的位置附近显示
    let anchorPoint: CGPoint
    /// 是否落在「标题栏」区域（cclose 里等价于 WM_NCHITTEST == HTCAPTION）
    let isTitleBar: Bool

    var appName: String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        return bundleId ?? "未知应用"
    }
}

// MARK: - Accessibility 封装

enum AXBridge {

    static let interactiveTitleRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTab", "AXTabButton",
        "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXSlider", "AXSegmentedControl", "AXRadioGroup", "AXLink",
        "AXMenuBar", "AXWebArea", "AXMenuItem"
    ]
    static func hasInteractiveTitleRole(_ roles: [String]) -> Bool {
        roles.contains { interactiveTitleRoles.contains($0) }
    }
    private static func titleAncestorRoles(_ element: AXUIElement) -> [String] {
        var roles: [String] = []
        var node: AXUIElement? = element
        for _ in 0..<12 {
            guard let current = node else { break }
            let role = string(current, "AXRole") ?? ""
            if role == "AXWindow" { break }
            roles.append(role)
            node = child(current, "AXParent")
        }
        return roles
    }
    /// Query the source application's tree, so the mirror itself does not obscure the hit.
    static func isSourceTitlePoint(_ point: CGPoint, window: AXUIElement, app: AXUIElement) -> Bool {
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &result) == .success,
              let hit = result, let owner = containingWindow(of: hit), CFEqual(owner, window) else { return false }
        return !hasInteractiveTitleRole(titleAncestorRoles(hit))
    }

    /// Read back the accepted frame: applications may impose their own minimum size.
    static func setFrame(_ requested: CGRect, of window: AXUIElement, currentHint: CGRect? = nil) -> CGRect? {
        var size = requested.size
        var position = requested.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else { return nil }
        let current = currentHint ?? frame(of: window)
        let sizeResult: AXError = current?.size == requested.size ? .success : AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let moveResult: AXError = current?.origin == requested.origin ? .success : AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard sizeResult == .success || moveResult == .success else { return nil }
        return frame(of: window)
    }

    static let systemWide = AXUIElementCreateSystemWide()

    /// 标题栏判定的最小高度（点）。部分新版 App 的工具栏更高，会使用红绿灯高度动态扩展。
    static let titleBarMinHeight: CGFloat = 32

    private static var didPrepare = false

    /// 统一把 AX 调用超时压到 0.2s，避免某个卡死 App 拖慢输入响应
    static func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
    }

    static func isTrusted(prompt: Bool = false) -> Bool {
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: 基础读写

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else { return nil }
        return value as? Bool
    }

    static func child(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, "AXPosition"),
              let sizeValue = attribute(element, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    // MARK: 命中判定

    /// 屏幕坐标（左上原点，与 CGEvent.location 同一坐标系）下的元素
    static func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard error == .success, let result = element else { return nil }
        return result
    }

    /// 沿 AXParent 向上找到所属窗口
    static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 16 {
            if let role = string(node, "AXRole"),
               role == "AXWindow" || role == "AXSheet" || role == "AXDialog" {
                return node
            }
            current = child(node, "AXParent")
            depth += 1
        }
        return nil
    }

    /// 完整命中测试：返回窗口信息 + 是否标题栏
    static func hitTest(at point: CGPoint) -> WindowHit? {
        evaluate(at: point).hit
    }

    /// 带判定过程的命中测试：trace 里是每一步的结论，供 --probe / --debug 打印
    static func evaluate(at point: CGPoint) -> (hit: WindowHit?, trace: [String]) {
        prepare()
        var trace: [String] = []

        func fail(_ reason: String) -> (WindowHit?, [String]) {
            trace.append(reason)
            return (nil, trace)
        }

        guard let elementAtPoint = element(at: point) else {
            return fail("① 取元素：失败 —— 这个位置没有可访问的 AX 元素")
        }
        let hitRole = string(elementAtPoint, "AXRole") ?? "(无角色)"
        let hitTitle = string(elementAtPoint, "AXTitle") ?? string(elementAtPoint, "AXDescription") ?? ""
        trace.append("① 元素：\(hitRole)\(hitTitle.isEmpty ? "" : "「\(hitTitle)」")")

        guard let window = containingWindow(of: elementAtPoint) else {
            return fail("② 找窗口：失败 —— 上溯 16 层没遇到 AXWindow（可能点在桌面 / 菜单栏 / 悬浮层上）")
        }
        guard let rect = frame(of: window) else {
            return fail("② 找窗口：找到了，但读不到 AXPosition/AXSize")
        }

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let windowTitle = string(window, "AXTitle") ?? ""
        trace.append("② 窗口：\(string(window, "AXRole") ?? "?")「\(windowTitle)」 "
            + "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)) pid=\(pid)")

        if pid == ProcessInfo.processInfo.processIdentifier {
            return fail("③ 归属：这是 cclose-mac 自己的窗口，忽略")
        }

        guard (string(window, "AXRole") ?? "") == "AXWindow" else {
            return fail("③ 窗口角色不是 AXWindow（\(string(window, "AXRole") ?? "?")），跳过")
        }
        if let subrole = string(window, "AXSubrole"), !subrole.isEmpty,
           subrole != "AXStandardWindow", subrole != "AXDialog" {
            return fail("③ 窗口子角色是 \(subrole)，不是标准窗口，跳过")
        }
        if bool(window, "AXFullScreen") == true { return fail("③ 窗口是全屏状态，跳过") }
        if bool(window, "AXMinimized") == true { return fail("③ 窗口已最小化，跳过") }

        let offsetY = point.y - rect.minY
        let titleBarHeight = captionHeight(of: window, windowFrame: rect)
        trace.append("④ 顶部偏移：\(String(format: "%.1f", offsetY))pt（标题栏阈值 \(Int(titleBarHeight))pt）")

        let isWindowItself = (hitRole == "AXWindow")
        let parentRole = child(elementAtPoint, "AXParent").map { string($0, "AXRole") ?? "?" }
        let isTitleChrome: Bool = {
            guard hitRole == "AXTitleUIElement" || hitRole == "AXStaticText" else { return false }
            return parentRole == "AXWindow"
        }()
        let parentRoleText = parentRole ?? "无"
        trace.append("⑤ 角色：命中 \(hitRole)，父元素 \(parentRoleText) → "
            + (isWindowItself ? "窗口本体" : (isTitleChrome ? "标题栏文字" : "非标题栏元素")))

        let insideBar = offsetY >= -1 && offsetY <= titleBarHeight
        let looksLikeChrome = isWindowItself || isTitleChrome

        // 兼容模式：Chrome / VS Code / Safari 这类自绘标题栏窗口，顶部常被报成 AXGroup、
        // AXTabGroup。开启后，顶部条带里只要不是明确的可交互控件，就当作标题栏处理。
        if hasInteractiveTitleRole(titleAncestorRoles(elementAtPoint)) {
            return fail("⑥ 标题区域内的标签页或控件，保留原生点击")
        }
        let tolerant = Prefs.shared.tolerantTitleBar && insideBar

        if !looksLikeChrome && !tolerant {
            trace.append("⑥ 结论：不是标题栏 —— 这一层是 \(hitRole)。"
                + "浏览器标签栏 / 工具栏按钮 / 网页正文都在这一类，按设计不处理。"
                + (insideBar ? "（点菜单「兼容自绘标题栏」可处理顶部自定义 chrome）" : ""))
            return (nil, trace)
        }
        if !insideBar {
            trace.append("⑥ 结论：不是标题栏 —— 落点离窗口顶部 \(String(format: "%.1f", offsetY))pt，超出阈值。")
            return (nil, trace)
        }

        if !looksLikeChrome && tolerant {
            trace.append("⑥ 结论：命中标题栏 ✓（兼容模式下把 \(hitRole) 视为标题栏 chrome）")
        } else {
            trace.append("⑥ 结论：命中标题栏 ✓")
        }
        let result = WindowHit(
            window: window,
            frame: rect,
            pid: pid,
            bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            title: windowTitle,
            anchorPoint: point,
            isTitleBar: true
        )
        return (result, trace)
    }

    /// 优先用窗口左上红绿灯的下沿估算标题栏高度；读不到时使用 32pt。
    private static func captionHeight(of window: AXUIElement, windowFrame: CGRect) -> CGFloat {
        guard let closeButton = child(window, "AXCloseButton"),
              let buttonFrame = frame(of: closeButton)
        else {
            return titleBarMinHeight
        }
        let candidate = buttonFrame.maxY - windowFrame.minY + 6
        return min(max(titleBarMinHeight, candidate), 48)
    }

    // MARK: 窗口动作

    /// 关闭窗口：优先按红绿灯按钮（与用户点红点等价，不会误伤同 App 的其他窗口）
    @discardableResult
    static func close(_ window: AXUIElement) -> Bool {
        if let closeButton = child(window, "AXCloseButton"),
           AXUIElementPerformAction(closeButton, "AXPress" as CFString) == .success {
            return true
        }
        return closeByCommandW(window)
    }

    /// 兜底：激活 App 后发送 ⌘W
    private static func closeByCommandW(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }

        app.activate(options: [])
        usleep(180_000)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let keyCodeW: CGKeyCode = 13
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeW, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeW, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func minimize(_ window: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, kCFBooleanTrue) == .success {
            return true
        }
        // 部分 App 不让外部直接写 AXMinimized，退回按黄色最小化按钮。
        if let minimizeButton = child(window, "AXMinimizeButton") {
            return AXUIElementPerformAction(minimizeButton, "AXPress" as CFString) == .success
        }
        return false
    }

    @discardableResult
    static func raise(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, "AXRaise" as CFString) == .success
    }

    // MARK: 窗口标识

    static func title(of window: AXUIElement) -> String? {
        string(window, "AXTitle")
    }

    /// 取得 CGWindowID（置顶必须用到）
    static func windowID(_ window: AXUIElement) -> UInt32? {
        if let getWindow = PrivateAPI.shared.axGetWindow {
            var wid: UInt32 = 0
            if getWindow(window, &wid) == 0, wid != 0 {
                return wid
            }
        }
        return matchWindowIDByGeometry(window)
    }

    /// 私有符号不可用时的兜底：按 PID + 窗口几何匹配 CGWindowID
    private static func matchWindowIDByGeometry(_ window: AXUIElement) -> UInt32? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
        guard let rect = frame(of: window) else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: (wid: UInt32, score: CGFloat)?
        for item in list {
            guard let owner = item[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            guard let number = item[kCGWindowNumber as String] as? UInt32 else { continue }
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any] else { continue }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { continue }

            let score = abs(bounds.minX - rect.minX)
                + abs(bounds.minY - rect.minY)
                + abs(bounds.width - rect.width)
                + abs(bounds.height - rect.height)
            if score <= 6 {
                if best == nil || score < best!.score {
                    best = (number, score)
                }
            }
        }
        return best?.wid
    }

    /// 前台 App 的聚焦窗口
    static func frontmostWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        return child(axApp, "AXFocusedWindow")
    }

    /// 用于判断窗口是否还活着（置顶状态清理）
    static func isAlive(_ window: AXUIElement) -> Bool {
        attribute(window, "AXRole") != nil
    }
}
