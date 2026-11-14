import AppKit

/// Shared by the settings panel and the running mirror; values persist across launches.
enum MirrorAppearance {
    static let changed = Notification.Name("MirrorAppearanceChanged")
    static var opacity: Double {
        DesktopMode.shared.isolated ? max(0.2, min(1, UserDefaults.standard.object(forKey: "mirrorOpacity") as? Double ?? 1)) : 1
    }
    static var borderWidth: Double { max(0, min(6, UserDefaults.standard.object(forKey: "mirrorBorderWidth") as? Double ?? 1)) }
    static var borderColor: NSColor { color(UserDefaults.standard.string(forKey: "mirrorBorderColor") ?? "mint") }
    static var background: NSColor { .clear }
    static func color(_ name: String) -> NSColor {
        if name.hasPrefix("#"), let rgb = UInt32(name.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        switch name {
        case "blue": return NSColor(srgbRed: 0.58, green: 0.75, blue: 0.96, alpha: 1)
        case "lilac": return NSColor(srgbRed: 0.78, green: 0.68, blue: 0.92, alpha: 1)
        case "white": return .white
        case "dark": return NSColor(white: 0.13, alpha: 1)
        default: return NSColor(srgbRed: 0.50, green: 0.81, blue: 0.73, alpha: 1)
        }
    }
    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
}
