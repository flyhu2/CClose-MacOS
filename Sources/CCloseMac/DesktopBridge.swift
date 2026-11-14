import AppKit
import ApplicationServices

struct DesktopFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct ManagedDesktop: Equatable {
    let id: UInt64
    let display: String
    let type: Int
    let active: Bool
}

/// ABI declarations checked against MoveItHere's SkyLight bridge. No injection or SIP changes.
/// https://github.com/davidgeller/moveithere
final class DesktopBridge {
    static let shared = DesktopBridge()
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Spaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Assign = @convention(c) (Int32, pid_t, UInt64) -> Int32
    private let connection: Int32
    private let displays: Displays?
    private let spaces: Spaces?
    private let assign: Assign?
    let available: Bool

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func resolve<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        let getConnection = resolve("SLSMainConnectionID", Connection.self)
        connection = getConnection?() ?? 0
        displays = resolve("SLSCopyManagedDisplaySpaces", Displays.self)
        spaces = resolve("SLSCopySpacesForWindows", Spaces.self)
        assign = resolve("SLSProcessAssignToSpace", Assign.self)
        available = getConnection != nil && displays != nil && spaces != nil && assign != nil
    }

    func snapshot() throws -> [ManagedDesktop] {
        guard available, let raw = displays?(connection)?.takeRetainedValue() as? [[String: Any]], !raw.isEmpty else {
            throw DesktopFailure("当前系统无法读取桌面信息，未迁移任何窗口")
        }
        func id(_ entry: [String: Any]) -> UInt64? {
            (entry["ManagedSpaceID"] as? NSNumber ?? entry["id64"] as? NSNumber)?.uint64Value
        }
        var result: [ManagedDesktop] = []
        for display in raw {
            guard let name = display["Display Identifier"] as? String,
                  let items = display["Spaces"] as? [[String: Any]] else { continue }
            let active = (display["Current Space"] as? [String: Any]).flatMap(id)
            for item in items {
                guard let number = id(item), number != 0 else { continue }
                result.append(ManagedDesktop(id: number, display: name, type: item["type"] as? Int ?? -1, active: number == active))
            }
        }
        guard !result.isEmpty else { throw DesktopFailure("系统桌面数据格式不受支持") }
        return result
    }

    func spaces(of window: UInt32) -> Set<UInt64> {
        guard let values = spaces?(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(values.map(\.uint64Value))
    }

    struct Window {
        let id: UInt32
        let pid: pid_t
        let layer: Int
    }
    func windows() throws -> [Window] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw DesktopFailure("无法核对窗口列表，保留独立桌面以便恢复")
        }
        return raw.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return Window(id: id, pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
    func move(pid: pid_t, to desktop: UInt64) throws {
        guard desktop != 0, assign?(connection, pid, desktop) == 0 else {
            throw DesktopFailure("系统拒绝迁移应用，恢复记录已保留")
        }
    }

    static func sourceDesktop(memberships: [Set<UInt64>], desktops: [ManagedDesktop]) throws -> ManagedDesktop {
        let ids = memberships.reduce(into: Set<UInt64>()) { $0.formUnion($1) }
        guard ids.count == 1, let id = ids.first, let desktop = desktops.first(where: { $0.id == id && $0.type == 0 }) else {
            throw DesktopFailure("该应用的窗口分散在多个桌面、全屏或属于所有桌面；为确保可恢复，本次不迁移")
        }
        return desktop
    }
}

/// Dock AX identifiers/action names documented by Hammerspoon's hs.spaces implementation.
/// This is an independent bounded async implementation, not a shell/AppleScript helper.
/// https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces
final class DesktopDockUI {
    private let bridge = DesktopBridge.shared
    private func children(_ node: AXUIElement) -> [AXUIElement] {
        AXBridge.attribute(node, "AXChildren") as? [AXUIElement] ?? []
    }
    // macOS 27 moved mc.display out of Dock's empty mc stub into WindowManager.
    private func missionDisplays() throws -> [AXUIElement] {
        guard Permissions.hasAccessibility else {
            throw DesktopFailure("辅助功能尚未授权，请在设置中开启后重新启动工具")
        }
        var result: [AXUIElement] = []
        for bundle in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            result += MissionControlTree.displays(root, identifier: { AXBridge.string($0, "AXIdentifier") }, children: children)
        }
        return result
    }
    private func missionControl() throws -> AXUIElement? { try missionDisplays().first }
    private func pause() async throws { try await Task.sleep(nanoseconds: 100_000_000) }
    private func open() async throws {
        if try missionControl() != nil {
            try await Task.sleep(nanoseconds: 350_000_000)
            return
        }
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard NSWorkspace.shared.open(url) else { throw DesktopFailure("无法打开 Mission Control") }
        for _ in 0..<60 {
            try await pause()
            if try missionControl() != nil {
                try await Task.sleep(nanoseconds: 350_000_000)
                return
            }
        }
        throw DesktopFailure("未找到 Mission Control 桌面控件；请核对辅助功能权限或系统版本，未迁移窗口")
    }
    private func displayID(_ identifier: String) throws -> UInt32 {
        if identifier == "Main" { return CGMainDisplayID() }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            if CFUUIDCreateString(nil, uuid) as String == identifier { return id }
        }
        throw DesktopFailure("原显示器已断开，保留恢复记录")
    }
    private func subgroup(_ name: String, display: String) async throws -> AXUIElement {
        let id = try displayID(display)
        for _ in 0..<20 {
            let displays = try missionDisplays()
            let screen: AXUIElement?
            if let exact = displays.first(where: { (AXBridge.attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == id }) {
                screen = exact
            } else {
                // Newer systems can omit AXDisplayID. Match full Quartz display bounds,
                // never visibleFrame or a guessed screen index (multi-display safety).
                let expected = CGDisplayBounds(id)
                let matches = displays.filter { node in
                    guard let frame = AXBridge.frame(of: node) else { return false }
                    return MirrorGeometry.sameFrame(frame, expected, tolerance: 2)
                }
                screen = matches.count == 1 ? matches[0] : nil
            }
            if let screen,
               let group = children(screen).first(where: { AXBridge.string($0, "AXIdentifier") == "mc.spaces" }),
               let target = children(group).first(where: { AXBridge.string($0, "AXIdentifier") == name }) { return target }
            try await pause()
        }
        throw DesktopFailure("系统未提供桌面操作控件，未使用坐标猜测操作")
    }
    private func desktopButton(_ id: UInt64) async throws -> AXUIElement {
        let snapshot = try bridge.snapshot()
        guard let desktop = snapshot.first(where: { $0.id == id }) else { throw DesktopFailure("目标桌面已不存在") }
        let ordered = snapshot.filter { $0.display == desktop.display }
        let list = try await subgroup("mc.spaces.list", display: desktop.display)
        let buttons = children(list)
        guard let index = ordered.firstIndex(where: { $0.id == id }), buttons.count == ordered.count,
              try bridge.snapshot().filter({ $0.display == desktop.display }).map(\.id) == ordered.map(\.id) else {
            throw DesktopFailure("桌面顺序正在变化，已取消操作")
        }
        return buttons[index]
    }
    func go(to id: UInt64) async throws {
        let snapshot = try bridge.snapshot()
        if snapshot.contains(where: { $0.id == id && $0.active }) {
            // Selecting the already-active thumbnail can leave Mission Control open,
            // especially immediately after deleting its neighbour. Close the overview explicitly.
            try await Task.sleep(nanoseconds: 350_000_000)
            if try missionControl() == nil { return }
            guard NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app")) else {
                throw DesktopFailure("无法收起 Mission Control")
            }
            for _ in 0..<60 {
                try await pause()
                if try missionControl() == nil { return }
            }
            throw DesktopFailure("Mission Control 尚未收起，可重试恢复")
        }
        try await open()
        let button = try await desktopButton(id)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw DesktopFailure("无法切换到目标桌面") }
        for _ in 0..<60 {
            try await pause()
            if try bridge.snapshot().contains(where: { $0.id == id && $0.active }), try missionControl() == nil { return }
        }
        throw DesktopFailure("桌面切换未完成")
    }
    func create(on display: String, returnTo origin: UInt64, record: (UInt64) throws -> Void) async throws -> UInt64 {
        try await open()
        let before = try bridge.snapshot()
        let add = try await subgroup("mc.spaces.add", display: display)
        guard AXUIElementPerformAction(add, kAXPressAction as CFString) == .success else { throw DesktopFailure("无法创建独立桌面") }
        for _ in 0..<60 {
            try await pause()
            let added = try bridge.snapshot().filter { $0.display == display && $0.type == 0 && !Set(before.map(\.id)).contains($0.id) }
            if added.count > 1 { throw DesktopFailure("同时出现多个新增桌面，无法确认归属；未迁移应用，请检查 Mission Control") }
            if let desktop = added.first {
                try record(desktop.id) // Persist ownership before attempting any later operation.
                try await go(to: origin)
                return desktop.id
            }
        }
        throw DesktopFailure("未检测到新桌面，未迁移应用")
    }
    func remove(_ owned: UInt64, returnTo origin: UInt64) async throws {
        if !(try bridge.snapshot().contains(where: { $0.id == owned })) { return }
        try await go(to: origin)
        try await open()
        let button = try await desktopButton(owned)
        // Recheck after asynchronous Mission Control transitions, immediately before removal.
        guard try !bridge.windows().contains(where: { $0.layer == 0 && bridge.spaces(of: $0.id).contains(owned) }) else {
            try await go(to: origin)
            throw DesktopFailure("独立桌面出现其他窗口，已停止清理；移走这些窗口后可重试恢复")
        }
        guard AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success else { throw DesktopFailure("独立桌面清理失败，可稍后重试恢复") }
        for _ in 0..<60 {
            try await pause()
            if !(try bridge.snapshot().contains(where: { $0.id == owned })) {
                try await go(to: origin)
                return
            }
        }
        throw DesktopFailure("独立桌面仍存在，保留恢复记录")
    }
}

/// Bounded traversal shared by the old Dock and new WindowManager layouts.
enum MissionControlTree {
    static func displays<Node>(_ root: Node, identifier: (Node) -> String?, children: (Node) -> [Node]) -> [Node] {
        var pending: [(Node, Int)] = [(root, 0)]
        var found: [Node] = []
        var visited = 0
        while !pending.isEmpty && visited < 80 {
            let (node, depth) = pending.removeFirst(); visited += 1
            let name = identifier(node)
            if name == "mc.display" {
                if children(node).contains(where: { identifier($0) == "mc.spaces" }) { found.append(node) }
                continue
            }
            // Only traverse the root and known Mission Control containers.
            if depth == 0 || (name == "mc" && depth < 3) {
                pending += children(node).prefix(40).map { ($0, depth + 1) }
            }
        }
        return found
    }
}
