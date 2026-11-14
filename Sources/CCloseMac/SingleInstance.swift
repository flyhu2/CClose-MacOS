import Foundation
import Darwin

/// 用一个进程锁兜住 LaunchServices 之外的启动路径（例如直接执行 .build 产物）。
/// 文件描述符必须存活到进程结束，flock 才会持续生效。
enum SingleInstance {

    private static var lockDescriptor: Int32 = -1

    static func acquire() -> Bool {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else {
            return true
        }
        let directory = support.appendingPathComponent("cclose-mac", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        } catch {
            fputs("cclose-mac: 无法创建单实例锁目录：\(error)\n", stderr)
            return false
        }

        let path = directory.appendingPathComponent("cclose-mac.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(0o644))
        guard descriptor >= 0 else {
            fputs("cclose-mac: 无法打开单实例锁 \(path)\n", stderr)
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        lockDescriptor = descriptor
        return true
    }
}
