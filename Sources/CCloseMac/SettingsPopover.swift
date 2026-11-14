import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var items: [NSMenuItem] = []
    var reload: (() -> [NSMenuItem])?
    func refresh() {
        let updated = reload?() ?? []
        func signature(_ list: [NSMenuItem]) -> [String] {
            list.map { "\($0.title)|\($0.state.rawValue)|\($0.isEnabled)|\($0.submenu?.items.map { "\($0.title):\($0.state.rawValue)" }.joined(separator: ",") ?? "")" }
        }
        if signature(updated) != signature(items) { items = updated }
    }
    func item(_ selector: String) -> NSMenuItem? { items.first { $0.action.map(NSStringFromSelector) == selector } }
    func perform(_ item: NSMenuItem) {
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        refresh()
    }
    func run(_ selector: String) { if let item = item(selector) { perform(item) } }
}

struct SettingsContent: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var desktop = DesktopMode.shared
    @AppStorage("independentDesktopEnabled") private var independentDesktop = false
    @AppStorage("mirrorOpacity") private var opacity = 1.0
    @State private var holdSeconds = Prefs.shared.holdSeconds
    @AppStorage("mirrorBorderWidth") private var borderWidth = 1.0
    @AppStorage("mirrorBorderColor") private var borderColor = "mint"
    private let accent = Color(red: 0.02, green: 0.55, blue: 0.55)
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CClose-MscOS").font(.system(size: 14, weight: .semibold))
                    Text("by flyhu2 · v\(Version.string)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.run("togglePaused") } label: {
                    Label(model.item("togglePaused")?.state == .on ? "暂停" : (permissionsReady ? "运行" : "待授权"),
                          systemImage: model.item("togglePaused")?.state == .on ? "pause.fill" : "circle.fill")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(accent.opacity(0.09), in: Capsule())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                permission("辅助功能", "openAccessibilitySettings")
                permission("输入监控", "openInputMonitoringSettings")
                permission("屏幕录制", "openScreenRecordingSettings")
            }
            basicContent
            Divider()
            VStack(spacing: 0) {
                setting("自绘标题栏兼容", detail: "", selector: "toggleTolerant")
                setting("触控板容差", detail: "", selector: "toggleTrackpadCompatibility")
                setting("开机启动", detail: "", selector: "toggleLoginItem")
            }
            Divider()
            appearance
            #if DEBUG
            if let qa = NSRunningApplication.runningApplications(withBundleIdentifier: "local.flyhu2.CCloseDesktopQA").first {
                Button("验证：置顶 QA 窗口") {
                    let app = AXUIElementCreateApplication(qa.processIdentifier)
                    if let windows = AXBridge.attribute(app, "AXWindows") as? [AXUIElement], let window = windows.first {
                        PinManager.shared.toggle(window, title: "QA")
                    }
                }.font(.system(size: 10))
            }
            #endif
            if desktop.needsRecovery && !desktop.isolated && !desktop.busy {
                Button("恢复独立桌面") { desktop.requestFinish() }.font(.system(size: 11))
            }
            Text(desktop.status.isEmpty ? (independentDesktop ? "内容仅预览 · 标题栏手势可用" : "重合模式 · 直接操作窗口") : desktop.status)
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).help(desktop.status)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("即时生效 · 点击外部收起").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { model.run("quit") }.buttonStyle(.plain).font(.system(size: 11))
            }
        }.padding(12).frame(width: 290, height: 534)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private var permissionsReady: Bool {
        ["openAccessibilitySettings", "openInputMonitoringSettings", "openScreenRecordingSettings"].allSatisfy { model.item($0)?.state == .on }
    }
    private var basicContent: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                setting("实时悬浮", detail: "长按标题栏", selector: "togglePinEnabled")
                setting("最小化", detail: "右键标题栏", selector: "toggleRightClick")
                setting("关闭窗口", detail: "中键标题栏", selector: "toggleMiddleClick")
                setting("关闭前台窗口", detail: "双击 Esc", selector: "toggleDoubleEsc")
            }
            Divider()
            HStack {
                Text("长按时长").font(.system(size: 11))
                Spacer()
                Slider(value: $holdSeconds, in: 0.3...2.0, step: 0.1)
                    .tint(accent).frame(width: 116)
                    .accessibilityLabel("长按时长")
                    .onChange(of: holdSeconds) { _, value in Prefs.shared.holdSeconds = value }
                Text(String(format: "%.1f 秒", holdSeconds))
                    .font(.system(size: 11).monospacedDigit()).frame(width: 40, alignment: .trailing)
            }.padding(.vertical, 3)
            Text("长按取消 · 标题空白处拖动 · 四边缩放")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var appearance: some View {
        VStack(spacing: 8) {
            VStack(spacing: 7) {
                HStack {
                    Text("独立桌面").font(.system(size: 11))
                    Spacer()
                    Button { independentDesktop.toggle() } label: {
                        Capsule().fill(independentDesktop ? accent : Color.secondary.opacity(0.25)).frame(width: 28, height: 16)
                            .overlay(Circle().fill(.white).frame(width: 12, height: 12).offset(x: independentDesktop ? 6 : -6))
                    }.buttonStyle(.plain).accessibilityLabel("独立桌面").accessibilityValue(independentDesktop ? "开启" : "关闭")
                }
                    .disabled(!independentDesktop && (desktop.busy || desktop.needsRecovery || PinManager.shared.pinnedCount > 0 || PinManager.shared.isStarting || !desktop.supported))
                    .help("开启时迁移整个应用；关闭会取消悬浮并恢复原桌面。")
                HStack {
                    Text("不透明度")
                    Spacer()
                    if independentDesktop {
                        Slider(value: $opacity, in: 0.2...1, step: 0.05).tint(accent).frame(width: 120)
                        Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 34, alignment: .trailing)
                    } else { Text("重合模式固定 100%").foregroundStyle(.secondary) }
                }.help("透明度仅用于独立桌面；重合模式始终不透明")
            }.padding(8)
                .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 7) {
                HStack {
                    Text("边框粗细").frame(width: 58, alignment: .leading)
                    Slider(value: $borderWidth, in: 0...6, step: 0.5).tint(accent)
                    Text(String(format: "%.1f", borderWidth)).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("边框颜色").frame(width: 58, alignment: .leading)
                    swatches(selection: $borderColor, names: ["mint", "blue", "lilac"])
                    Spacer(minLength: 0)
                }

            }.padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }.font(.system(size: 10))
            .onChange(of: borderWidth) { _, _ in MirrorAppearance.notify() }
            .onChange(of: borderColor) { _, _ in MirrorAppearance.notify() }
            .onChange(of: opacity) { _, _ in MirrorAppearance.notify() }
            .onChange(of: independentDesktop) { _, enabled in
                if !enabled { PinManager.shared.unpinAll() }
            }
    }
    private func swatches(selection: Binding<String>, names: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(names, id: \.self) { name in
                Button { selection.wrappedValue = name } label: {
                    Circle().fill(Color(nsColor: MirrorAppearance.color(name))).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(selection.wrappedValue == name ? accent : Color.gray.opacity(0.25), lineWidth: selection.wrappedValue == name ? 2 : 0.5))
                }.buttonStyle(.plain).accessibilityLabel(name)
            }
            ColorPicker("自定义", selection: Binding(get: { Color(nsColor: MirrorAppearance.color(selection.wrappedValue)) }, set: { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                selection.wrappedValue = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
            }), supportsOpacity: false).labelsHidden().controlSize(.mini).help("自定义颜色")
        }
    }
    private func permission(_ title: String, _ selector: String) -> some View {
        let state = model.item(selector)?.state
        let granted = state == .on
        let pending = state == nil || state == .mixed
        return Button { model.run(selector) } label: {
            HStack(spacing: 4) {
                Image(systemName: granted ? "checkmark.circle.fill" : (pending ? "ellipsis.circle" : "exclamationmark.circle"))
                    .foregroundStyle(granted ? accent : Color.orange)
                Text(title)
            }.font(.system(size: 10)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(model.item(selector)?.title ?? "正在检查")
            .accessibilityValue(model.item(selector)?.title ?? "正在检查")
    }
    private func setting(_ title: String, detail: String, selector: String) -> some View {
        let item = model.item(selector)
        let on = item?.state == .on
        return HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            Button { model.run(selector) } label: {
                Capsule().fill(on ? accent : Color.secondary.opacity(0.25)).frame(width: 28, height: 16)
                    .overlay(Circle().fill(.white).frame(width: 12, height: 12).offset(x: on ? 6 : -6))
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(on ? "开启" : "关闭")
                .disabled(item?.isEnabled != true).frame(width: 36, alignment: .trailing)
        }.frame(height: 25)
    }
}
