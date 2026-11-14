import AppKit

// cclose-mac —— cclose(AutoHotkey/@chaohershi) 的 macOS 原生复刻
// 入口：菜单栏常驻服务，无 Dock 图标（LSUIElement）。

let arguments = CommandLine.arguments

if arguments.contains("--probe") {
    // 手势没反应时先跑这个：打印权限、事件采集能否建立、当前鼠标位置的判定链
    var probePoint: CGPoint?
    if let pointIndex = arguments.firstIndex(of: "--point"),
       arguments.indices.contains(pointIndex + 2),
       let x = Double(arguments[pointIndex + 1]),
       let y = Double(arguments[pointIndex + 2]) {
        probePoint = CGPoint(x: x, y: y)
    }
    Probe.run(at: probePoint)
    exit(0)
}

if arguments.contains("--debug") {
    GestureEngine.debugEnabled = true
}

if arguments.contains("--diagnose") || arguments.contains("-d") {
    Diagnostics.run()
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    cclose-mac \(Version.string)

    用法:
      cclose-mac              以菜单栏服务方式启动
      cclose-mac --probe      手势没反应时用：打印权限 + 事件采集自检 + 当前鼠标位置的标题栏判定链
      cclose-mac --probe --point 300 80
                              按指定屏幕坐标检查标题栏判定（不移动鼠标）
      cclose-mac --debug      带日志启动（日志走 stderr，配合 scripts/debug.sh 看）
      cclose-mac --diagnose   打印环境 / 权限 / 实时悬浮诊断（只读）
      cclose-mac --help       显示本帮助

    手势:
      左键长按标题栏  = 实时悬浮；画面可滚动 / 点击 / 拖选
      悬浮原标题区域  = 拖动移动、再次长按取消、右键最小化、中键关闭
      悬浮右下角手柄  = 调整宽高；⌘单击临时返回，切走后恢复
      右键标题栏      = 最小化窗口
      中键标题栏      = 关闭窗口
      双击 Esc        = 关闭前台窗口
    """)
    exit(0)
}

if arguments.contains("--version") {
    print("cclose-mac \(Version.string)")
    exit(0)
}

// A newly opened copy must not silently hand control to an older binary.
// Ask existing instances to quit normally so their independent desktops are restored.
var acquired = SingleInstance.acquire()
if !acquired, let bundleID = Bundle.main.bundleIdentifier {
    let old = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    old.forEach { _ = $0.terminate() }
    let deadline = Date().addingTimeInterval(12)
    while !acquired && Date() < deadline && !old.isEmpty {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        acquired = SingleInstance.acquire()
    }
}
guard acquired else {
    let alert = NSAlert()
    alert.messageText = "旧实例尚未退出"
    alert.informativeText = "请先在旧版菜单中退出，或完成独立桌面恢复，再打开新版。为避免丢失窗口恢复记录，本次没有强制结束旧进程。"
    alert.addButton(withTitle: "好")
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
