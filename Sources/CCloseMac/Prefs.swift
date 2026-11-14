import Foundation

/// 全部可调参数集中在这里，默认值对齐 cclose 原版行为：
/// - 原版长按阈值 1s（这里默认 0.9s，可在菜单里改）
/// - 原版右键"按住超过 0.4s 视为普通右键"（这里默认 0.35s）
/// - 原版双击 Esc 间隔 0.4s（这里默认 0.5s）
enum PrefsKey: String, CaseIterable {
    case pinEnabled
    case rightClickMinimize
    case middleClickClose
    case doubleEscClose
    case holdSeconds
    case rightClickDelay
    case escInterval
    case blacklist
    case paused
    case tolerantTitleBar
    case trackpadCompatibility
}

final class Prefs {
    static let shared = Prefs()

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults.standard
        defaults.register(defaults: [
            PrefsKey.pinEnabled.rawValue: true,
            PrefsKey.rightClickMinimize.rawValue: true,
            PrefsKey.middleClickClose.rawValue: true,
            PrefsKey.doubleEscClose.rawValue: true,
            PrefsKey.holdSeconds.rawValue: 0.9,
            PrefsKey.rightClickDelay.rawValue: 0.35,
            PrefsKey.escInterval.rawValue: 0.5,
            PrefsKey.blacklist.rawValue: [String](),
            PrefsKey.paused.rawValue: false,
            PrefsKey.tolerantTitleBar.rawValue: true,
            PrefsKey.trackpadCompatibility.rawValue: true
        ])
    }

    var pinEnabled: Bool {
        get { defaults.bool(forKey: PrefsKey.pinEnabled.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.pinEnabled.rawValue) }
    }

    var rightClickMinimize: Bool {
        get { defaults.bool(forKey: PrefsKey.rightClickMinimize.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.rightClickMinimize.rawValue) }
    }

    var middleClickClose: Bool {
        get { defaults.bool(forKey: PrefsKey.middleClickClose.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.middleClickClose.rawValue) }
    }

    var doubleEscClose: Bool {
        get { defaults.bool(forKey: PrefsKey.doubleEscClose.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.doubleEscClose.rawValue) }
    }

    var holdSeconds: Double {
        get { defaults.double(forKey: PrefsKey.holdSeconds.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.holdSeconds.rawValue) }
    }

    var rightClickDelay: Double {
        get { defaults.double(forKey: PrefsKey.rightClickDelay.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.rightClickDelay.rawValue) }
    }

    var escInterval: Double {
        get { defaults.double(forKey: PrefsKey.escInterval.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.escInterval.rawValue) }
    }

    var blacklist: [String] {
        get { defaults.array(forKey: PrefsKey.blacklist.rawValue) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: PrefsKey.blacklist.rawValue) }
    }

    var paused: Bool {
        get { defaults.bool(forKey: PrefsKey.paused.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.paused.rawValue) }
    }

    /// 兼容模式：把窗口顶部条带里非控件的元素也当作标题栏（给自绘标题栏的 App 用）
    var tolerantTitleBar: Bool {
        get { defaults.bool(forKey: PrefsKey.tolerantTitleBar.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.tolerantTitleBar.rawValue) }
    }

    /// 触控板的按下位置和拖动事件常有几个像素的抖动，使用更宽容的移动阈值。
    var trackpadCompatibility: Bool {
        get { defaults.bool(forKey: PrefsKey.trackpadCompatibility.rawValue) }
        set { defaults.set(newValue, forKey: PrefsKey.trackpadCompatibility.rawValue) }
    }

    /// 手势是否应对该应用生效
    func isBlacklisted(_ bundleId: String?) -> Bool {
        guard let bundleId = bundleId else { return false }
        return blacklist.contains(bundleId)
    }

    func addToBlacklist(_ bundleId: String) {
        guard !bundleId.isEmpty else { return }
        var list = blacklist
        guard !list.contains(bundleId) else { return }
        list.append(bundleId)
        blacklist = list
    }

    func clearBlacklist() {
        blacklist = []
    }
}
