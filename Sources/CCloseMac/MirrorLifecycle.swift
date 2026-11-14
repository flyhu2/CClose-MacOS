import ApplicationServices

/// A failed IPC read is not a closed window. Require corroborated invalidation.
struct MirrorLifecycle {
    private var missingChecks = 0
    mutating func sourceExists(processRunning: Bool, axResult: AXError, listed: Bool?) -> Bool {
        guard processRunning else { return false }
        guard axResult == .invalidUIElement, listed == false else {
            missingChecks = 0
            return true
        }
        missingChecks += 1
        return missingChecks < 3
    }
    static func shouldResume(waiting: Bool, minimized: Bool?) -> Bool {
        waiting && minimized == false
    }
}
