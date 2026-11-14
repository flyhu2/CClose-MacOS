import AppKit
import CoreGraphics

enum Version {
    static let string = "1.0.1"
    static let build = "3"
}

// MARK: - 诊断
//
// 输出环境和权限；不会修改窗口层级或向其他应用发送事件。
// 终端：cclose-mac --diagnose ；菜单栏：复制诊断信息。

enum Diagnostics {

    static func run() {
        print(report().joined(separator: "\n"))
    }

    static func report() -> [String] {
        var lines: [String] = []

        lines.append("== cclose-mac 诊断 ==")
        lines.append("版本        : \(Version.string) (build \(Version.build))")
        lines.append("系统        : macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("架构        : \(architecture)")
        let launchedByLaunchServices = getppid() == 1
        lines.append("启动上下文  : \(launchedByLaunchServices ? "双击 / LaunchServices" : "命令行（权限结果可能继承父终端）")")
        lines.append("辅助功能权限: \(Permissions.hasAccessibility ? "已授权" : "未授权（系统设置 → 隐私与安全性 → 辅助功能）")")
        lines.append("输入监控权限: \(Permissions.hasInputMonitoring ? "已允许" : "未允许（系统设置 → 隐私与安全性 → 输入监控）")")
        lines.append("合成事件权限: \(Permissions.canPostEvents ? "已允许" : "未允许")")
        lines.append("长按 / 右键阈值: \(Prefs.shared.holdSeconds)s / \(Prefs.shared.rightClickDelay)s")
        lines.append("自绘标题栏兼容: \(Prefs.shared.tolerantTitleBar ? "已开" : "已关")")
        lines.append("触控板移动容差: \(Prefs.shared.trackpadCompatibility ? "已开" : "已关")")
        lines.append("可执行文件  : \(Bundle.main.executablePath ?? "?")")
        if !launchedByLaunchServices {
            lines.append("提示        : 请以菜单栏 App 自己的图标 / 菜单状态为准；授权后使用「重新启动 cclose-mac」")
        }
        lines.append("")

        lines.append("置顶后端    : ScreenCaptureKit 实时悬浮（单窗口、鼠标交互）")
        lines.append("屏幕录制权限: \(Permissions.hasScreenRecording ? "已授权" : "未授权；仅悬浮需要")")
        lines.append("SIP / yabai : 无需修改 SIP，无需 yabai")
        lines.append("诊断模式    : 只读，不改变任何窗口层级")
        return lines
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
