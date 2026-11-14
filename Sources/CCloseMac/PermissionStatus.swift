import AppKit
import ScreenCaptureKit

/// A preflight result is not enough to display a green check: validate usable access.
enum PermissionStatus: Equatable {
    case denied, checking, ready, unavailable
    static func resolve(preflight: Bool, usable: Bool?) -> Self {
        guard preflight else { return .denied }
        guard let usable else { return .checking }
        return usable ? .ready : .unavailable
    }
    var menuState: NSControl.StateValue { self == .ready ? .on : (self == .denied ? .off : .mixed) }
    var text: String {
        switch self {
        case .denied: return "未授权，点击开启"
        case .checking: return "正在检查"
        case .ready: return "已验证可用"
        case .unavailable: return "尚不可用，授权后请重启"
        }
    }
}

// Accessed only by AppKit main-thread callbacks.
final class PermissionChecks {
    static let shared = PermissionChecks()
    private(set) var accessibility: PermissionStatus = .checking
    private(set) var input: PermissionStatus = .checking
    private(set) var screen: PermissionStatus = .checking
    private var lastCheck = Date.distantPast
    private var checking = false
    private var lastPreflights: [Bool] = []
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !checking else { return }
        let ax = Permissions.hasAccessibility, listen = Permissions.hasInputMonitoring, capture = Permissions.hasScreenRecording
        let preflights = [ax, listen, capture]
        if preflights == lastPreflights && accessibility == .ready && input == .ready && screen == .ready { return }
        if !ax { accessibility = .denied }
        if !listen { input = .denied }
        if !capture { screen = .denied }
        guard Date().timeIntervalSince(lastCheck) >= 8 else { return }
        lastCheck = Date(); checking = true; lastPreflights = preflights
        accessibility = PermissionStatus.resolve(preflight: ax, usable: ax ? Self.canReadSystemUI() : false)
        input = PermissionStatus.resolve(preflight: listen, usable: listen ? Self.canListen() : false)
        screen = capture ? .checking : .denied
        Task { @MainActor in
            defer { checking = false }
            guard capture else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                screen = PermissionStatus.resolve(preflight: Permissions.hasScreenRecording, usable: !content.displays.isEmpty)
            } catch { screen = .unavailable }
        }
    }
    private static func canReadSystemUI() -> Bool {
        for bundle in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &value) == .success { return true }
        }
        return false
    }
    private static func canListen() -> Bool {
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                                         callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }
}
