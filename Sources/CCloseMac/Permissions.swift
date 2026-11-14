import AppKit
import CoreGraphics

// macOS 把连续手势需要的权限拆成了两项：
//   - Accessibility：读取窗口信息、执行关闭 / 最小化
//   - Input Monitoring：接收其他 App 的鼠标 / 键盘事件
// 只授权其中一项时，应用可能看似正常启动，但手势完全收不到。
enum Permissions {

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static var hasAccessibility: Bool {
        AXBridge.isTrusted()
    }

    static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    static var allRequiredGranted: Bool {
        hasAccessibility && hasInputMonitoring
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        AXBridge.isTrusted(prompt: true)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        if hasInputMonitoring { return true }
        return CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
