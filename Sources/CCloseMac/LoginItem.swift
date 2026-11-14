import Foundation

// MARK: - 开机自启（LaunchAgent）
//
// 不做常驻 helper，只写一个 LaunchAgent plist，卸载时删除即可，
// 用户可以在「登录项」里看到它，随时手动移除。

enum LoginItem {

    static let label = "local.jingzhe.cclose-mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 只有运行在 .app 包里才值得自启（swift run 的路径不可靠）
    static var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.executablePath != nil
    }

    @discardableResult
    static func enable() -> Bool {
        guard canInstall, let executable = Bundle.main.executablePath else { return false }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/\(label).log",
            "StandardErrorPath": "/tmp/\(label).err.log"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try data.write(to: plistURL)
        } catch {
            return false
        }

        runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return isEnabled
    }

    static func disable() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 兼容旧系统：退回 load/unload
            let legacy = Process()
            legacy.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            legacy.arguments = arguments.first == "bootstrap" ? ["load", "-w", plistURL.path] : ["unload", plistURL.path]
            legacy.standardOutput = FileHandle.nullDevice
            legacy.standardError = FileHandle.nullDevice
            try? legacy.run()
            legacy.waitUntilExit()
        }
    }
}
