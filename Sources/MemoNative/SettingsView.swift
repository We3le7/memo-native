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
    /// 玻璃强度 0…1。数值越大，毛玻璃越"薄"、透光越多。
    ///
    /// 之所以做成 0…1 的用户向刻度而不是直接暴露 NSVisualEffectView 的
    /// alphaValue，是因为两者方向相反（alpha 越小越透），直接用会反直觉。
    /// 内部换算集中在 GlassAppearance 里，UI 与实现各自只关心自己的语义。
    @Published var glassStrength: Double {
        didSet {
            UserDefaults.standard.set(glassStrength, forKey: "glassStrength")
            NotificationCenter.default.post(name: .memoGlassStrengthChanged, object: nil)
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
        let stored = defaults.object(forKey: "glassStrength") as? Double
        glassStrength = stored.map { min(max($0, 0), 1) } ?? GlassAppearance.defaultStrength
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

// MARK: - 设置卡片
//
// 用自绘卡片替代 GroupBox：GroupBox 的系统外观和主界面的表面层次不统一，
// 放在一起像两个时代的界面。

struct SettingCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    content()
                }
            } else {
                // 无标题模式：内容自己撑满整张卡片
                content()
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Theme.hairline)
        )
    }
}

/// 分组小标题：把设置项归到"外观 / 行为 / 数据"三类，
/// 一屏铺 10 个同权重的卡片时，用户找不到东西。
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
            .textCase(.uppercase)
            .kerning(0.6)
            .padding(.leading, 2)
            .padding(.top, 6)
    }
}

struct SettingsView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var settings: AppSettings
    /// 关闭自己。由承载它的窗口提供（独立窗口），不再依赖 SwiftUI 的 dismiss。
    var onClose: () -> Void = {}

    /// 打开时的快照：取消时用它回滚，避免「改了就生效、关不掉」的窘境
    @StateObject private var snapshot = SettingsSnapshot()

    /// 顶部标题区：固定的，不随内容滚动
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("改动会立即生效")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            IconGlyph(system: "xmark", help: "关闭（Esc）") { onClose() }
        }
    }

    /// 底部操作区：固定，不随内容滚动
    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认") { restoreDefaults() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkTertiary)

            Spacer()

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

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏固定在顶部，不随内容滚动——
            // 内容变长后关闭按钮还在视野里，不用滚到顶才能退出。
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().opacity(0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHeader(title: "外观")
                    SettingCard(
                        title: "玻璃效果",
                        detail: "调整面板与悬浮球的通透程度。越往右，背后的内容越容易透上来。"
                    ) {
                        GlassStrengthField(strength: $settings.glassStrength)
                    }
                    SettingCard(
                        title: "悬浮球",
                        detail: "收起面板后留下一颗圆球，随手点开记录。可拖到屏幕上任意位置，不会被吸回边缘。"
                    ) {
                        Toggle("显示", isOn: $settings.showFloatingOrb)
                            .font(.system(size: 11.5))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }

                    SectionHeader(title: "行为")
                    SettingCard(
                        title: "每日提醒",
                        detail: "到点后由系统通知中心提醒所有未完成事项，App 未运行也会弹。"
                    ) {
                        TimeField(hour: $settings.reminderHour, minute: $settings.reminderMinute)
                    }
                    SettingCard(
                        title: "点击其他窗口时",
                        detail: settings.dismissBehavior.detail
                    ) {
                        Picker("", selection: $settings.dismissBehavior) {
                            ForEach(PanelDismissBehavior.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    SettingCard(
                        title: "全局快捷键",
                        detail: "在任意 App 里按下即可召唤输入面板。"
                    ) {
                        Text(settings.hotkey)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Theme.stroke, lineWidth: Theme.hairline)
                            )
                    }

                    // 两个开关合并进一张卡片，不再各自裸奔。
                    // 原来它们夹在悬浮球下面，看不出属于哪一组。
                    SettingCard(title: "", detail: "") {
                        VStack(alignment: .leading, spacing: 11) {
                            Toggle("登录时自动启动", isOn: $settings.launchAtLogin)
                                .font(.system(size: 12))
                            Toggle("在菜单栏显示图标", isOn: $settings.showInMenuBar)
                                .font(.system(size: 12))
                        }
                    }

                    SectionHeader(title: "数据")
                    SettingCard(title: "", detail: "") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.fileURL.path)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.inkTertiary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                QuietButton(title: "在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                                }
                                QuietButton(title: "重新载入") {
                                    store.load()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }

            Divider().opacity(0.5)

            // 操作栏固定底部，与标题栏一起夹住可滚动的中间区。
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 430, height: 596)
        // 与面板共用同一套玻璃：同样的材质、同样的强度、同样的圆角与描边。
        //
        // 之前设置窗是普通不透明 NSWindow，用系统背景，
        // 和面板摆在一起像两个 App 的窗口。
        .background(
            ZStack {
                VisualEffectBackground(settings: settings)
                GlassVeil(strength: settings.glassStrength)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.04),
                            Color.black.opacity(0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        )
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

// MARK: - 玻璃强度调节

/// 玻璃强度滑杆 + 档位文字。
///
/// 直接给一个裸 Slider 会有两个问题：拖动时没有即时反馈、也不知道"多少算合适"。
/// 所以这里补上档位名，并在两端加了图标，让用户不用试错就能定位。
struct GlassStrengthField: View {
    @Binding var strength: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkTertiary)

                Slider(value: $strength, in: 0...1)
                    .controlSize(.small)
                    .tint(Theme.accent)

                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkTertiary)

                Text(GlassAppearance.label(for: strength))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 58, alignment: .trailing)
                    .contentTransition(.opacity)
            }
        }
        .padding(.top, 1)
    }
}

/// 设置页里的轻量按钮：无边框、悬停才浮现底色。
struct QuietButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var hover = QuietHover()

    final class QuietHover: ObservableObject {
        @Published var on = false
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(hover.on ? Theme.ink : Theme.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover.on ? Theme.surfaceHover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}
