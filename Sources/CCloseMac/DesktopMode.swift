import AppKit
import Combine

struct DesktopLease: Codable {
    var bootID: String
    var pid: Int32
    var bundleID: String
    var launched: Double
    var origin: UInt64
    var owned: UInt64?
    var display: String
    var sourceWindow: UInt32
    var phase: String
    var existingIDs: [UInt64] = []

    func matches(pid: Int32, bundleID: String?, launched: Date?) -> Bool {
        self.pid == pid && self.bundleID == bundleID && launched.map { abs($0.timeIntervalSince1970 - self.launched) < 0.01 } == true
    }
    static func mayRemove(owned: UInt64, origin: UInt64, before: Set<UInt64>, occupied: Bool) -> Bool {
        owned != 0 && owned != origin && !before.contains(owned) && !occupied
    }
}

/// Main-run-loop coordinator. Exactly one journal and one owned Space, matching the single mirror.
final class DesktopMode: ObservableObject {
    static let shared = DesktopMode()
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var isolated = false
    @Published private(set) var needsRecovery = false
    private(set) var lease: DesktopLease?
    private let bridge = DesktopBridge.shared
    private let dock = DesktopDockUI()
    private var cancelled = false
    private var cleanupTask: Task<Void, Never>?
    private let journalKey = "independentDesktopRecoveryV1"
    var enabled: Bool { UserDefaults.standard.bool(forKey: "independentDesktopEnabled") }
    var supported: Bool { bridge.available }

    private init() {
        if let data = UserDefaults.standard.data(forKey: journalKey) {
            lease = try? JSONDecoder().decode(DesktopLease.self, from: data)
            needsRecovery = true
            status = lease == nil ? "恢复记录无法读取；独立桌面已停用" : "有待恢复的独立桌面"
        }
    }
    private static func bootID() throws -> String {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0 else { throw DesktopFailure("无法读取启动标识，未操作桌面") }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { throw DesktopFailure("无法读取启动标识") }
        return String(cString: bytes)
    }
    private func save(_ value: DesktopLease) throws {
        let data = try JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: journalKey)
        guard UserDefaults.standard.synchronize() else { throw DesktopFailure("恢复记录保存失败，未继续迁移") }
        lease = value
        needsRecovery = true
    }
    private func clear() {
        UserDefaults.standard.removeObject(forKey: journalKey)
        UserDefaults.standard.synchronize()
        lease = nil; needsRecovery = false; isolated = false; status = ""
    }
    private func checkCancellation() throws {
        if cancelled { throw DesktopFailure("独立桌面准备已取消，正在恢复") }
    }
    private func settle(pid: pid_t, desktop: UInt64, witness: UInt32?) async throws {
        for _ in 0..<30 {
            let windows = try bridge.windows().filter { $0.pid == pid && $0.layer == 0 }
            if witness == nil && windows.isEmpty { return }
            let memberships = windows.map { bridge.spaces(of: $0.id) }.filter { !$0.isEmpty }
            let witnessOK = witness.map { bridge.spaces(of: $0).contains(desktop) } ?? true
            if !memberships.isEmpty, memberships.allSatisfy({ $0 == [desktop] }), witnessOK { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw DesktopFailure("系统未确认全部窗口迁移完成，恢复记录已保留")
    }
    func prepare(pid: pid_t, windowID: UInt32) async throws {
        await waitForCleanup()
        guard !busy, lease == nil, !needsRecovery else { throw DesktopFailure("请先完成独立桌面恢复") }
        guard supported else { throw DesktopFailure("当前 macOS 不支持独立桌面接口") }
        guard let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier, let launched = app.launchDate,
              pid != ProcessInfo.processInfo.processIdentifier else { throw DesktopFailure("无法确认目标应用身份") }
        let before = try bridge.snapshot()
        let windows = try bridge.windows().filter { $0.pid == pid && $0.layer == 0 }
        let memberships = windows.map { bridge.spaces(of: $0.id) }
        let origin = try DesktopBridge.sourceDesktop(memberships: memberships, desktops: before)
        guard origin.active, bridge.spaces(of: windowID) == [origin.id] else { throw DesktopFailure("请在目标应用所在桌面启动置顶") }
        busy = true; cancelled = false; status = "正在创建独立桌面…"
        defer { busy = false }
        var record = DesktopLease(bootID: try Self.bootID(), pid: pid, bundleID: bundle, launched: launched.timeIntervalSince1970,
                                  origin: origin.id, owned: nil, display: origin.display, sourceWindow: windowID, phase: "creating", existingIDs: before.map(\.id))
        try save(record)
        do {
            let owned = try await dock.create(on: origin.display, returnTo: origin.id) { [self] id in
                guard !Set(before.map(\.id)).contains(id) else { throw DesktopFailure("新增桌面身份冲突") }
                record.owned = id; record.phase = "created"; try save(record)
            }
            try checkCancellation()
            record.phase = "moving"; try save(record)
            status = "正在迁移应用窗口…"
            try bridge.move(pid: pid, to: owned)
            try await settle(pid: pid, desktop: owned, witness: windowID)
            try checkCancellation()
            record.phase = "parked"; try save(record)
            isolated = true; status = "独立桌面 · 内容仅预览"
            MirrorAppearance.notify()
        } catch {
            status = error.localizedDescription
            throw error // Caller requests finish; defer releases the operation lock first.
        }
    }
    func isOnOwnedDesktop() -> Bool {
        guard let owned = lease?.owned else { return false }
        return (try? bridge.snapshot().contains { $0.id == owned && $0.active }) == true
    }
    func visitSource() async throws {
        guard !busy, isolated, let record = lease, let owned = record.owned else { return }
        busy = true; defer { busy = false }
        try await dock.go(to: owned)
        guard let app = NSRunningApplication(processIdentifier: record.pid), record.matches(pid: app.processIdentifier, bundleID: app.bundleIdentifier, launched: app.launchDate) else {
            throw DesktopFailure("原应用已退出")
        }
        app.activate(options: [])
        status = "操作原应用中 · 切回原桌面继续预览"
    }
    func requestFinish() {
        cancelled = true
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
            do { try await self.restore() }
            catch { self.status = error.localizedDescription; self.needsRecovery = true }
            self.cleanupTask = nil
        }
    }
    func waitForCleanup() async { await cleanupTask?.value }

    private func restore() async throws {
        guard var record = lease else {
            if needsRecovery { throw DesktopFailure("恢复记录损坏，请检查 Mission Control；不会删除任何桌面") }
            return
        }
        busy = true; isolated = false; status = "正在恢复应用与桌面…"
        defer { busy = false }
        guard record.bootID == (try Self.bootID()) else { clear(); return } // IDs are not stable across reboot.
        let snapshot = try bridge.snapshot()
        guard snapshot.contains(where: { $0.id == record.origin && $0.type == 0 }) else {
            throw DesktopFailure("原桌面已被删除，请先在 Mission Control 手动安置应用；不会猜测恢复位置")
        }
        let moving = ["moving", "parked", "restoring"].contains(record.phase)
        if moving, let app = NSRunningApplication(processIdentifier: record.pid), record.matches(pid: app.processIdentifier, bundleID: app.bundleIdentifier, launched: app.launchDate) {
            record.phase = "restoring"; try save(record)
            try bridge.move(pid: record.pid, to: record.origin)
            try await settle(pid: record.pid, desktop: record.origin, witness: nil)
        }
        record.phase = "cleanup"; try save(record)
        try await dock.go(to: record.origin)
        if let owned = record.owned, snapshot.contains(where: { $0.id == owned }) {
            let occupants = try bridge.windows().filter { $0.layer == 0 && bridge.spaces(of: $0.id).contains(owned) }
            // A user may have put another window there while the mirror was active.
            // Return the application, but relinquish the desktop rather than move unrelated windows.
            if !occupants.isEmpty {
                clear(); status = "应用已恢复；独立桌面含其他窗口，已保留"
                return
            }
            guard !record.existingIDs.isEmpty, DesktopLease.mayRemove(owned: owned, origin: record.origin, before: Set(record.existingIDs), occupied: false) else {
                throw DesktopFailure("桌面归属校验失败，已保留")
            }
            try await dock.remove(owned, returnTo: record.origin)
        }
        clear()
    }
}
