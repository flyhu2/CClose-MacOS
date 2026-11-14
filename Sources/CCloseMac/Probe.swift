import AppKit
import ApplicationServices

// MARK: - --probe 手势探针
//
// 用途：手势「没反应」时，把责任落到具体一层——
//   A. 权限 / 事件采集有没有建立起来
//   B. 鼠标位置上的 AX 命中判定走到了哪一步、为什么判成「不是标题栏」
//
// 用法：./scripts/probe.sh（或 dist/cclose-mac.app/Contents/MacOS/cclose-mac --probe）

enum Probe {

    static func run(at fixedPoint: CGPoint? = nil) {
        print("== cclose-mac 手势探针 \(Version.string) ==\n")
        print("可执行文件 : \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        print("Bundle     : \(Bundle.main.bundlePath)")
        print("进程 PID   : \(ProcessInfo.processInfo.processIdentifier)")
        print("鼠标位置   : \(pointString(currentPoint()))")

        print("\n-- 权限 --")
        print("辅助功能 AX        : \(Permissions.hasAccessibility ? "已授权" : "未授权")")
        print("监听事件 ListenOnly : \(Permissions.hasInputMonitoring ? "已允许" : "未允许")")
        print("合成事件 Post      : \(Permissions.canPostEvents ? "已允许" : "未允许")")

        print("\n-- 事件采集自检（能不能收到鼠标事件）--")
        testTap(.listenOnly, "左键监听 tap (listenOnly)")
        testTap(.defaultTap, "动作 tap (defaultTap)")

        print("""

        说明：
        · tap 创建失败 = 手势一个都收不到，跟测哪个窗口无关。
          左键长按用的是 listenOnly tap，新版 macOS 要求「输入监控」权限；
          只有「辅助功能」时，动作 tap 可能建得起来、左键监听却建不起来。
        · 从终端启动时，权限检查可能反映的是"终端"本身的授权，不代表 .app 已授权。
          判断 App 自己的状态看菜单栏图标：光标 = 正常，感叹号 = 有问题（悬停看原因）。
          App 内部判断与这里不一致时，去「辅助功能」把 cclose-mac 删掉重新添加。
        · v1.1.1 起使用稳定指定签名，重新编译通常不再丢权限；升级前遗留的同名项可重置一次。

        """)

        let point: CGPoint
        if let fixedPoint = fixedPoint {
            point = fixedPoint
        } else {
            print("把鼠标停在你想要手势作用的窗口标题栏上，然后回车：", terminator: "")
            _ = readLine()
            point = currentPoint()
        }
        print("")
        print("\n-- 命中判定 @ \(pointString(point)) --")
        let evaluation = AXBridge.evaluate(at: point)
        for line in evaluation.trace {
            print("   " + line)
        }
        if let hit = evaluation.hit {
            print("\n判定结果：这里是标题栏，手势会生效")
            print("目标窗口：\(hit.appName)（\(hit.bundleId ?? "无 bundleId")）/ \(hit.title)")
            if let wid = AXBridge.windowID(hit.window) {
                print("窗口 ID  ：\(wid)（镜像不改变原窗口层级）")
            }
        } else {
            print("\n判定结果：这里不是标题栏，手势不会生效（原因见上面 ⑥）")
        }
    }

    private static func currentPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func pointString(_ point: CGPoint) -> String {
        String(format: "x=%.0f y=%.0f", point.x, point.y)
    }

    /// 建一个 tap 立刻销毁，只用来确认「有没有资格采集事件」
    private static func testTap(_ options: CGEventTapOptions, _ name: String) {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: options,
                                    eventsOfInterest: mask,
                                    callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                    userInfo: nil)
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            CFMachPortInvalidate(tap)
            print("\(name) : 创建成功 ✓")
        } else {
            print("\(name) : 创建失败 ✗ ← 手势会完全没反应的原因就是它")
        }
    }
}
