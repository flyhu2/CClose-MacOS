import AppKit
import SwiftUI

// MARK: - 菜单栏应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var settingsPanel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private let settingsModel = SettingsModel()
    private let engine = GestureEngine()
    private var watchTimer: Timer?
    private var permissionAlertShown = false
    /// 权限有了但事件 tap 建不起来（listenOnly 需要「输入监控」），也要能看出来
    private var engineFailed = false
    private var didAnnounceStart = false
    private var terminationPending = false
    private var restartOnExit = false
    private var terminationSignals: [DispatchSourceSignal] = []

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development updates and normal process termination must use the same desktop cleanup.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // terminateLater may enter an AppKit modal loop. Leave the main-dispatch
                // handler before entering it so async desktop restoration can still execute.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
            }
            source.resume()
            terminationSignals.append(source)
        }
        setupStatusItem()
        wireEngine()
        HUD.shared.prepare()

        PermissionChecks.shared.refresh()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "permissionOnboardingV2")
        UserDefaults.standard.set(true, forKey: "permissionOnboardingV2")
        if firstLaunch || !Permissions.allRequiredGranted || !Permissions.hasScreenRecording {
            presentPermissionAlert(needsAccessibility: !Permissions.hasAccessibility,
                                   needsInputMonitoring: !Permissions.hasInputMonitoring,
                                   needsScreenRecording: !Permissions.hasScreenRecording)
        }

        startEngine()
        if DesktopMode.shared.needsRecovery && Permissions.hasAccessibility { DesktopMode.shared.requestFinish() }
        DispatchQueue.main.async { [weak self] in self?.toggleSettings() }

        watchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        // 退出前把所有置顶还原，避免留下「漂浮窗口」
        PinManager.shared.unpinAll()
        if restartOnExit {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "while kill -0 \"$2\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"", "cclose-restart", Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
            try? task.run()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard DesktopMode.shared.lease != nil || DesktopMode.shared.busy || DesktopMode.shared.needsRecovery else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        engine.stop()
        PinManager.shared.unpinAll()
        Task { @MainActor [weak self] in
            await DesktopMode.shared.waitForCleanup()
            var shouldQuit = true
            if DesktopMode.shared.needsRecovery {
                let alert = NSAlert()
                alert.messageText = "独立桌面尚未恢复"
                alert.informativeText = DesktopMode.shared.status + "\n退出会保留恢复记录，下次启动继续恢复。"
                alert.addButton(withTitle: "返回恢复")
                alert.addButton(withTitle: "保留记录并退出")
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            self?.terminationPending = false
            if !shouldQuit { self?.restartOnExit = false; _ = self?.startEngine() }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsPanel?.isVisible != true { toggleSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: 启动 / 守护

    @discardableResult
    private func startEngine() -> Bool {
        if GestureEngine.debugEnabled {
            logPermissionStatus(taps: nil)
        }
        guard Permissions.allRequiredGranted else {
            engineFailed = true
            updateStatusIcon()
            return false
        }
        let ok = engine.start()
        engineFailed = !ok
        if GestureEngine.debugEnabled {
            logPermissionStatus(taps: ok)
        }
        updateStatusIcon()
        return ok
    }

    private func logPermissionStatus(taps: Bool?) {
        let tapText = taps.map(String.init) ?? "not-attempted"
        let summary = """
        [cclose-mac] 权限 AX=\(Permissions.hasAccessibility) \
        Input=\(Permissions.hasInputMonitoring) \
        Post=\(Permissions.canPostEvents) \
        taps=\(tapText) pid=\(ProcessInfo.processInfo.processIdentifier)

        """
        FileHandle.standardError.write(Data(summary.utf8))
    }

    private func tick() {
        PermissionChecks.shared.refresh()
        PinManager.shared.prune()
        if settingsPanel?.isVisible == true { settingsModel.refresh() }
        let permitted = Permissions.allRequiredGranted
        if permitted, !engine.isRunning {
            if startEngine(), !didAnnounceStart {
                didAnnounceStart = true
                HUD.shared.flash("cclose-mac 已启动")
            }
        } else if !permitted, engine.isRunning {
            engine.stop()
            updateStatusIcon()
        }
    }

    private func wireEngine() {
        engine.onTogglePin = { [weak self] hit in
            self?.togglePin(for: hit)
        }
        engine.onPinArmed = { hit in
            let action = PinManager.shared.isPinned(hit.window) ? "取消置顶" : "置顶"
            HUD.shared.flash("松开以\(action) · \(hit.appName)", near: hit.anchorPoint)
        }
        engine.onMinimize = { hit in
            if AXBridge.minimize(hit.window) {
                HUD.shared.flash("已最小化 · \(hit.appName)", near: hit.anchorPoint)
            } else {
                HUD.shared.flash("最小化失败 · \(hit.appName)", near: hit.anchorPoint)
            }
        }
        engine.onClose = { hit in
            if AXBridge.close(hit.window) {
                HUD.shared.flash("已关闭 · \(hit.appName)", near: hit.anchorPoint)
            } else {
                HUD.shared.flash("关闭失败 · \(hit.appName)", near: hit.anchorPoint)
            }
        }
        engine.onCloseFrontmost = { [weak self] in
            self?.closeFrontmostWindow()
        }
    }

    private func togglePin(for hit: WindowHit) {
        PinManager.shared.toggle(hit.window, title: hit.title)
    }

    private func closeFrontmostWindow() {
        guard let window = AXBridge.frontmostWindow() else {
            HUD.shared.flash("没有可关闭的前台窗口")
            return
        }
        if let subrole = AXBridge.string(window, "AXSubrole"), subrole == "AXSheet" || subrole == "AXDialog" {
            HUD.shared.flash("当前是对话框，已跳过")
            return
        }
        if AXBridge.close(window) {
            HUD.shared.flash("已关闭前台窗口")
        } else {
            HUD.shared.flash("关闭失败")
        }
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 534),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "CClose-MscOS 设置"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: SettingsContent(model: settingsModel))
        settingsPanel = panel
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissSettingsIfOutside()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.dismissSettingsIfOutside()
            return event
        }
        settingsModel.reload = { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu.items
        }
        item.button?.target = self
        item.button?.action = #selector(toggleSettings)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusIcon()
    }

    private func dismissSettingsIfOutside() {
        guard let panel = settingsPanel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        if NSColorPanel.shared.isVisible && NSColorPanel.shared.frame.contains(point) { return }
        if statusItem?.button?.window?.frame.contains(point) == true { return }
        panel.orderOut(nil)
    }

    @objc private func toggleSettings() {
        guard statusItem?.button != nil, let panel = settingsPanel else { return }
        if panel.isVisible { panel.orderOut(nil) }
        else {
            settingsModel.refresh()
            positionSettings()
        }
    }

    private func positionSettings(attempt: Int = 0) {
        guard let panel = settingsPanel, let button = statusItem?.button else { return }
        guard let host = button.window, host.frame.width > 0, host.frame.height > 0 else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.positionSettings(attempt: attempt + 1) }
            }
            return
        }
        let anchor = host.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // The status-item host briefly reports (0,0) during launch. Do not show at that placeholder.
        guard anchor.minY >= visible.maxY - 4 else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.positionSettings(attempt: attempt + 1) }
            }
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let origin = MirrorGeometry.settingsOrigin(anchor: anchor, size: panel.frame.size, visible: visible)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.setFrameOrigin(origin)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if Prefs.shared.paused {
            symbol = "pause.circle"
        } else if !Permissions.allRequiredGranted || engineFailed {
            symbol = "exclamationmark.triangle"
        } else {
            button.image = StatusIcon.image(pinned: PinManager.shared.pinnedCount > 0)
            button.toolTip = tooltip()
            return
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "CClose-MscOS 窗口置顶") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "CC"
        }
        statusItem?.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if Prefs.shared.paused { return "cclose-mac 已暂停" }
        if !Permissions.hasAccessibility { return "cclose-mac 需要辅助功能权限" }
        if !Permissions.hasInputMonitoring { return "cclose-mac 需要输入监控权限" }
        if engineFailed { return "cclose-mac 事件采集失败，运行 --probe 查看原因" }
        return PinManager.shared.pinnedCount > 0 ? "CClose-MscOS · 窗口已置顶 · 左键或右键打开设置" : "CClose-MscOS · 长按标题栏置顶 · 左键或右键打开设置"
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        PinManager.shared.prune()

        let checks = PermissionChecks.shared
        for (title, selector, status) in [
            ("辅助功能", #selector(openAccessibilitySettings), checks.accessibility),
            ("输入监控", #selector(openInputMonitoringSettings), checks.input),
            ("屏幕录制", #selector(openScreenRecordingSettings), checks.screen)
        ] {
            let item = add(menu, "\(title)：\(status.text)", selector)
            item.state = status.menuState
        }

        let paused = Prefs.shared.paused
        add(menu, "暂停所有手势", #selector(togglePaused), state: paused)
        menu.addItem(.separator())

        add(menu, "实时悬浮（左键长按标题栏）", #selector(togglePinEnabled), state: Prefs.shared.pinEnabled)
        add(menu, "最小化（右键标题栏）", #selector(toggleRightClick), state: Prefs.shared.rightClickMinimize)
        add(menu, "关闭（中键标题栏）", #selector(toggleMiddleClick), state: Prefs.shared.middleClickClose)
        add(menu, "关闭前台窗口（双击 Esc）", #selector(toggleDoubleEsc), state: Prefs.shared.doubleEscClose)

        add(menu, "兼容自绘标题栏", #selector(toggleTolerant), state: Prefs.shared.tolerantTitleBar)
        add(menu, "触控板移动容差", #selector(toggleTrackpadCompatibility), state: Prefs.shared.trackpadCompatibility)

        let holdItem = NSMenuItem(title: "长按判定时间", action: nil, keyEquivalent: "")
        let holdMenu = NSMenu()
        for seconds in [0.6, 0.9, 1.2, 1.5] {
            let item = NSMenuItem(title: String(format: "%.1f 秒", seconds), action: #selector(selectHold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = abs(Prefs.shared.holdSeconds - seconds) < 0.01 ? .on : .off
            holdMenu.addItem(item)
        }
        holdItem.submenu = holdMenu
        menu.addItem(holdItem)

        menu.addItem(.separator())

        let count = PinManager.shared.pinnedCount
        add(menu, "恢复悬浮（保留位置和大小）", #selector(resumeMirror), enabled: count > 0)
        add(menu, "临时操作原窗口", #selector(visitMirrorSource), enabled: count > 0)
        add(menu, "悬浮画面恢复原尺寸", #selector(resetMirrorSize), enabled: count > 0)
        add(menu, "取消所有置顶（\(count)）", #selector(unpinAll), enabled: count > 0 || PinManager.shared.isStarting)

        let frontApp = NSWorkspace.shared.frontmostApplication
        let name = frontApp?.localizedName ?? "当前 App"
        add(menu, "把「\(name)」加入黑名单", #selector(blacklistFrontmostApp))
        add(menu, "清空黑名单（\(Prefs.shared.blacklist.count)）", #selector(clearBlacklist),
            enabled: !Prefs.shared.blacklist.isEmpty)

        menu.addItem(.separator())

        add(menu, "开机自动启动", #selector(toggleLoginItem), state: LoginItem.isEnabled, enabled: LoginItem.canInstall)
        add(menu, "重新启动 cclose-mac", #selector(restartApplication))
        add(menu, "手势说明", #selector(showHelp))
        add(menu, "复制诊断信息", #selector(copyDiagnostics))

        menu.addItem(.separator())
        add(menu, "退出 cclose-mac", #selector(quit))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, state: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    // MARK: 菜单动作

    @objc private func openAccessibilitySettings() {
        _ = Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openInputMonitoringSettings() {
        _ = Permissions.requestInputMonitoring()
        Permissions.openInputMonitoringSettings()
    }

    @objc private func openScreenRecordingSettings() {
        if !Permissions.hasScreenRecording { _ = CGRequestScreenCaptureAccess() }
        Permissions.openScreenRecordingSettings()
    }

    @objc private func togglePaused() {
        Prefs.shared.paused.toggle()
        updateStatusIcon()
        HUD.shared.flash(Prefs.shared.paused ? "手势已暂停" : "手势已恢复")
    }

    @objc private func togglePinEnabled() {
        Prefs.shared.pinEnabled.toggle()
    }

    @objc private func toggleRightClick() {
        Prefs.shared.rightClickMinimize.toggle()
    }

    @objc private func toggleMiddleClick() {
        Prefs.shared.middleClickClose.toggle()
    }

    @objc private func toggleDoubleEsc() {
        Prefs.shared.doubleEscClose.toggle()
    }

    @objc private func toggleTolerant() {
        Prefs.shared.tolerantTitleBar.toggle()
        HUD.shared.flash(Prefs.shared.tolerantTitleBar ? "自绘标题栏兼容已开" : "自绘标题栏兼容已关")
    }

    @objc private func toggleTrackpadCompatibility() {
        Prefs.shared.trackpadCompatibility.toggle()
        HUD.shared.flash(Prefs.shared.trackpadCompatibility ? "触控板移动容差已开" : "触控板移动容差已关")
    }

    @objc private func selectHold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        Prefs.shared.holdSeconds = seconds
    }

    @objc private func resumeMirror() { PinManager.shared.resume() }
    @objc private func visitMirrorSource() { PinManager.shared.visitOriginal() }
    @objc private func resetMirrorSize() { PinManager.shared.resetSize() }

    @objc private func unpinAll() {
        PinManager.shared.unpinAll()
        HUD.shared.flash("已取消所有置顶")
    }

    @objc private func blacklistFrontmostApp() {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            HUD.shared.flash("无法识别当前 App")
            return
        }
        Prefs.shared.addToBlacklist(bundleId)
        HUD.shared.flash("已加入黑名单 · \(bundleId)")
    }

    @objc private func clearBlacklist() {
        Prefs.shared.clearBlacklist()
        HUD.shared.flash("黑名单已清空")
    }

    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled {
            LoginItem.disable()
            HUD.shared.flash("已取消开机启动")
        } else if LoginItem.enable() {
            HUD.shared.flash("已设置开机启动")
        } else {
            HUD.shared.flash("开机启动设置失败（需以 .app 方式运行）")
        }
    }

    @objc private func restartApplication() {
        restartOnExit = true
        NSApp.terminate(nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "CClose-MscOS 手势"
        alert.informativeText = """
        标题栏：长按置顶 / 取消，右键最小化，中键关闭。
        镜像：点击、滚动和拖选；拖标题或留白移动，拖四边四角缩放。
        外观：面板可调背景、边框和透明度。
        内容右键保留镜像，菜单位置由原应用决定。
        ⌘ 单击临时操作原窗口，切换应用后恢复悬浮。
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func copyDiagnostics() {
        let text = Diagnostics.report().joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        HUD.shared.flash("诊断信息已复制到剪贴板")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 首次授权引导

    private func presentPermissionAlert(needsAccessibility: Bool, needsInputMonitoring: Bool, needsScreenRecording: Bool) {
        guard !permissionAlertShown else { return }
        permissionAlertShown = true

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "首次使用与权限检查"
            var missing: [String] = []
            if needsAccessibility {
                missing.append("辅助功能：识别标题栏并最小化 / 关闭窗口")
            }
            if needsInputMonitoring {
                missing.append("输入监控：接收鼠标和键盘手势")
            }
            if needsScreenRecording { missing.append("屏幕录制：生成实时镜像，不保存或上传画面") }
            if missing.isEmpty { missing.append("系统预检已有授权，面板将继续验证实际访问能力。") }
            alert.informativeText = """
            请在「系统设置 → 隐私与安全性」中允许 cclose-mac：

            \(missing.joined(separator: "\n"))

            面板对勾表示已验证可用，感叹号表示未授权，省略号表示待检查或需重启。点击面板权限按钮可申请授权。更新前请退出旧版，授权后请重新打开本应用。
            """
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if needsAccessibility {
                    self.openAccessibilitySettings()
                } else if needsInputMonitoring {
                    self.openInputMonitoringSettings()
                } else if needsScreenRecording {
                    self.openScreenRecordingSettings()
                }
            }
        }
    }
}
