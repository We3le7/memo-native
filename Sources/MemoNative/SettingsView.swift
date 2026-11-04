import SwiftUI
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var reminderHour: Int {
        didSet { UserDefaults.standard.set(reminderHour, forKey: "reminderHour"); ReminderCenter.shared.reschedule() }
    }
    @Published var reminderMinute: Int {
        didSet { UserDefaults.standard.set(reminderMinute, forKey: "reminderMinute"); ReminderCenter.shared.reschedule() }
    }
    @Published var launchAtLogin: Bool {
        didSet { LaunchAtLogin.isEnabled = launchAtLogin }
    }
    @Published var showInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
            // 立刻反映到菜单栏，不用重启。
            // 走通知而不是直接引用 AppDelegate：设置层不该知道 App 代理的存在，
            // 也让这段代码能被单元测试单独编译。
            NotificationCenter.default.post(name: .memoMenuBarVisibilityChanged, object: nil)
        }
    }
    @Published var hotkey: String {
        didSet { UserDefaults.standard.set(hotkey, forKey: "hotkey"); HotkeyManager.shared.reload() }
    }
    @Published var showFloatingOrb: Bool {
        didSet {
            UserDefaults.standard.set(showFloatingOrb, forKey: "orbEnabled")
            FloatingOrb.shared.isEnabled = showFloatingOrb
        }
    }
    @Published var dismissBehavior: PanelDismissBehavior {
        didSet {
            UserDefaults.standard.set(dismissBehavior.code, forKey: "dismissBehavior")
            PanelController.shared.behaviorDidChange()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        reminderHour = defaults.object(forKey: "reminderHour") as? Int ?? 9
        reminderMinute = defaults.object(forKey: "reminderMinute") as? Int ?? 0
        launchAtLogin = LaunchAtLogin.isEnabled
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        hotkey = defaults.string(forKey: "hotkey") ?? HotkeyManager.defaultHotkey
        dismissBehavior = PanelDismissBehavior.from(code: defaults.string(forKey: "dismissBehavior"))
        showFloatingOrb = defaults.object(forKey: "orbEnabled") as? Bool ?? true
    }

    var reminderTimeText: String { String(format: "%02d:%02d", reminderHour, reminderMinute) }

    var reminderDate: Date {
        get {
            var components = DateComponents()
            components.hour = reminderHour
            components.minute = reminderMinute
            return Calendar.current.date(from: components) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = components.hour ?? 9
            reminderMinute = components.minute ?? 0
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var settings: AppSettings
    /// 关闭自己。由承载它的窗口提供（独立窗口），不再依赖 SwiftUI 的 dismiss。
    var onClose: () -> Void = {}

    /// 打开时的快照：取消时用它回滚，避免「改了就生效、关不掉」的窘境
    @StateObject private var snapshot = SettingsSnapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("设置").font(.system(size: 15, weight: .semibold))
                Spacer()
                // 顶部关闭：不论窗口多矮、内容多长，这里始终可见
                IconGlyph(system: "xmark", help: "关闭（Esc）") { onClose() }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("每日提醒时间").font(.system(size: 12))
                        Spacer()
                        TimeField(hour: $settings.reminderHour, minute: $settings.reminderMinute)
                    }
                    Text("到点后由系统通知中心提醒所有未完成事项，App 未运行也会弹。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("全局快捷键").font(.system(size: 12))
                        Spacer()
                        Text(settings.hotkey)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    }
                    Text("在任意 App 里按下即可召唤输入面板。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("点击其他窗口时").font(.system(size: 12))
                    Picker("", selection: $settings.dismissBehavior) {
                        ForEach(PanelDismissBehavior.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(settings.dismissBehavior.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("显示悬浮球", isOn: $settings.showFloatingOrb)
                        .font(.system(size: 12))
                    Text("收起面板后留下一颗圆球，随手点开记录；可拖动到任意位置，会吸附屏幕边缘。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("登录时自动启动", isOn: $settings.launchAtLogin)
                .font(.system(size: 12))
            Toggle("在菜单栏显示图标", isOn: $settings.showInMenuBar)
                .font(.system(size: 12))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("数据文件").font(.system(size: 11, weight: .medium))
                Text(store.fileURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    .font(.system(size: 11))
                    Button("重新载入") { store.load() }
                        .font(.system(size: 11))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("恢复默认") { restoreDefaults() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkTertiary)

                Spacer()

                // 取消 = 回滚到打开时的状态并关闭
                Button("取消") {
                    snapshot.apply(to: settings)
                    onClose()
                }
                .font(.system(size: 11))
                .keyboardShortcut(.cancelAction)

                Button("完成") { onClose() }
                    .font(.system(size: 11))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 560)
        .onAppear { snapshot.capture(from: settings) }
        // Esc 关闭设置，而不是把整个面板收起
        .onExitCommand { onClose() }
    }

    private func restoreDefaults() {
        settings.reminderHour = 9
        settings.reminderMinute = 0
        settings.dismissBehavior = .demote
        settings.showFloatingOrb = true
        settings.showInMenuBar = true
    }
}


// MARK: - 提醒时间输入
//
// 原先用 DatePicker(.stepperField)，在 nonactivatingPanel 弹出的 sheet 里
// 输入框点击/键盘编辑都不可靠。改成自绘的时/分步进 + 可直接输入的数字框，
// 任何情况下都可编辑，并且严格夹取到合法范围。

struct TimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        HStack(spacing: 4) {
            UnitField(value: $hour, range: 0...23, width: 30)
            Text(":").font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            UnitField(value: $minute, range: 0...59, width: 30)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private struct UnitField: View {
        @Binding var value: Int
        let range: ClosedRange<Int>
        let width: CGFloat

        @StateObject private var holder = Holder()

        @MainActor
        final class Holder: ObservableObject {
            @Published var text: String = ""
        }

        var body: some View {
            TextField("", text: $holder.text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: width)
                .onAppear { holder.text = UILogic.formatTimeUnit(value) }
                .onChange(of: holder.text) { newValue in
                    commit(newValue)
                }
                .onChange(of: value) { newValue in
                    let formatted = UILogic.formatTimeUnit(newValue)
                    if holder.text != formatted { holder.text = formatted }
                }
        }

        private func commit(_ raw: String) {
            let digits = raw.filter(\.isNumber)
            guard !digits.isEmpty else { return }
            let bounded = UILogic.parseTimeField(raw, range: range, fallback: value)
            if bounded != value {
                value = bounded
            }
            // 两位输入完成后统一补零，避免出现 "9" 这种显示
            if digits.count >= 2 {
                let formatted = UILogic.formatTimeUnit(bounded)
                if holder.text != formatted { holder.text = formatted }
            }
        }
    }
}
