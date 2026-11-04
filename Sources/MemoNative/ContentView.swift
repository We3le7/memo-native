import SwiftUI
import AppKit
import Combine


// MARK: - 视图局部状态
//
// 本机只有 Command Line Tools，没有 Xcode 的 SwiftUIMacros，
// 因此 @State 不可用（它是宏）。视图局部状态一律用 @StateObject 承载。

@MainActor
final class ComposerState: ObservableObject {
    @Published var draft: String = ""
    @Published var priority: Priority = .normal
    @Published var dueMode: DueMode = .today
    @Published var customDate: Date = Date()
    /// 新事项的工期（天）
    @Published var span: Int = 1
    @Published var filter: Filter = .all
    @Published var editingID: String?
    @Published var editingText: String = ""
    @Published var toast: String?
    @Published var now: Date = Date()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", today = "今天", pending = "未完成", done = "已完成"
        var id: String { rawValue }
    }

    /// 日期不依赖系统 DatePicker 弹出层（非激活面板里点不开），改为显式选项。
    enum DueMode: String, CaseIterable, Identifiable {
        case today = "今天"
        case tomorrow = "明天"
        case pick = "选择日期"

        var id: String { rawValue }

        var offset: Int? {
            switch self {
            case .today: return 0
            case .tomorrow: return 1
            case .pick: return nil
            }
        }
    }

    private var toastToken = 0
    private var clockTask: Task<Void, Never>?

    /// 最近一次可撤销的删除（提示条上提供「撤销」）
    @Published var undoBuffer: [Memo] = []
    var canUndo: Bool { !undoBuffer.isEmpty }

    func rememberForUndo(_ memos: [Memo]) {
        guard !memos.isEmpty else { return }
        undoBuffer = memos
    }

    func clearUndo() { undoBuffer = [] }

    func flash(_ message: String) {
        toast = message
        toastToken += 1
        let token = toastToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.toastToken == token {
                self.toast = nil
                self.clearUndo()
            }
        }
    }

    func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { @MainActor in
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    var resolvedDueKey: String {
        if let offset = dueMode.offset {
            return UILogic.dueKey(offsetDays: offset)
        }
        return DateKey.string(from: customDate)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var settings: AppSettings
    @StateObject private var ui = ComposerState()
    @FocusState private var inputFocused: Bool

    /// 展开形变状态。用 EnvironmentObject 而不是普通属性：
    /// rootView 是值类型，每次改属性都会重建 NSHostingView，
    /// 把 @StateObject 与输入焦点一起丢掉。共享一个 object 只推送变化，视图身份不变。
    @EnvironmentObject private var unfold: UnfoldState

    private var visibleItems: [Memo] {
        switch ui.filter {
        case .all:
            return store.sortedItems
        case .today:
            let today = DateKey.today
            return store.sortedItems.filter { $0.dueDate == today || (!$0.done && $0.dueDate < today) }
        case .pending:
            return store.sortedItems.filter { !$0.done }
        case .done:
            return store.sortedItems.filter(\.done)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            filterBar
            listArea
            footer
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 660)
        // 展开形变：从球所在方位长出来。
        //
        // 缩放中心用球相对面板的方位，而不是恒定的 .center——
        // 球在左边时从左边展开，球在上方时从上方展开，
        // 视觉上"起点"才和球对得上，用户看到的是连贯的一次变形。
        //
        // 缩放只做到 0.86 而不是 0：再小就会露出窗口边缘的直角，
        // 玻璃的圆角在极小尺寸下也会失真，反而显得廉价。
        .scaleEffect(
            0.86 + 0.14 * unfold.progress,
            anchor: unfold.anchor
        )
        .opacity(0.15 + 0.85 * Double(unfold.progress))
        // 背景层必须裁成圆角。
        //
        // 之前只在上面画了一圈 12pt 的描边，窗口本身仍是矩形：
        // VisualEffectView 铺满整个窗口矩形，四角就露出直角玻璃，
        // 描边只是浮在直角上方的一条弧线，看起来像"方框套了个圆弧"。
        // clipShape 把背景真正裁出来，四角才是真的弧。
        .background(
            ZStack {
                VisualEffectBackground(settings: settings)
                GlassVeil(strength: settings.glassStrength)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        )
        // 玻璃边缘：上沿一点亮、下沿一点暗，模拟光线掠过玻璃厚边。
        // 这是 Apple 系玻璃最有辨识度的一笔——没有它，玻璃就只是一块半透明色块。
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .onAppear {
            ui.customDate = Date()
            ui.startClock()
            inputFocused = true
        }
        .onDisappear { ui.stopClock() }
        .onReceive(NotificationCenter.default.publisher(for: .memoFocusInput)) { _ in
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoOpenSettings)) { _ in
            SettingsWindowController.shared.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoSetPriorityShortcut)) { note in
            if let raw = note.object as? String, let level = Priority(rawValue: raw) {
                withAnimation(.easeOut(duration: 0.18)) { ui.priority = level }
                ui.flash(level.label)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = ui.toast {
                HStack(spacing: 8) {
                    Text(toast)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)

                    // 删除类操作给一条 1.5 秒的后悔通道
                    if ui.canUndo {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: Theme.hairline, height: 11)
                        Button("撤销") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                store.restore(ui.undoBuffer)
                                ui.clearUndo()
                                ui.toast = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: Theme.hairline))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .padding(.bottom, 46)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(Theme.springSoft, value: ui.toast)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)

            // 标题 + 日期副标题构成一级视觉锚点，而不是孤零零一个词
            VStack(alignment: .leading, spacing: 1) {
                Text("备忘录")
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(0.1)
                    .foregroundStyle(Theme.ink)

                Text(UILogic.headerDateText(ui.now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }

            Spacer()

            // 系统时间：静默地作为环境信息，不与内容争抢注意力
            Text(UILogic.clockText(ui.now))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline))
                .padding(.trailing, 2)

            if store.unreadReminderCount > 0 {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .transition(.scale.combined(with: .opacity))
                    .help("\(store.unreadReminderCount) 条未读提醒")
            }

            IconGlyph(system: "bell", help: "标记提醒已读") {
                withAnimation(.easeOut(duration: 0.2)) { store.markRemindersRead() }
            }
            IconGlyph(system: "gearshape", help: "设置") {
                SettingsWindowController.shared.show()
            }
            IconGlyph(system: "xmark", help: "隐藏（Esc）") { PanelController.shared.hide() }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .animation(Theme.springSoft, value: store.unreadReminderCount)
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 10) {
            // 输入框：本界面的视觉重心。
            // 抬起感来自「浅色底 + 内描边 + 极淡外阴影」三层叠加，
            // 而不是把边框画重；聚焦时描边转为强调色并加一圈柔光。
            HStack(spacing: 9) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(inputFocused ? Theme.accent : Theme.inkQuaternary)
                    .frame(width: 16)

                TextField("记点什么…", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .regular))
                    .focused($inputFocused)
                    .onSubmit(commit)

                if !ui.draft.isEmpty {
                    Button {
                        withAnimation(Theme.easeFast) { ui.draft = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkQuaternary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // 回车提示：给「随手记录」一个可发现的出口
                Text("↵")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(inputFocused && !ui.draft.isEmpty ? Theme.accent : Theme.inkQuaternary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(inputFocused && !ui.draft.isEmpty ? Theme.accent.opacity(0.14) : Color.clear)
                    )
                    .scaleEffect(inputFocused && !ui.draft.isEmpty ? 1.06 : 1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(inputFocused ? Theme.surfaceRaised : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Theme.accent.opacity(0.55) : Theme.stroke,
                        lineWidth: inputFocused ? 1.2 : Theme.hairline
                    )
            )
            .shadow(
                color: inputFocused ? Theme.accent.opacity(0.16) : .black.opacity(0.05),
                radius: inputFocused ? 9 : 4,
                y: inputFocused ? 3 : 1
            )
            .animation(Theme.springSnappy, value: inputFocused)
            .animation(Theme.easeFast, value: ui.draft.isEmpty)

            // 一行承载：日期 + 优先级。文字优先，颜色只用于优先级圆点。
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(ComposerState.DueMode.allCases) { mode in
                        QuietChip(
                            title: mode.rawValue,
                            selected: ui.dueMode == mode
                        ) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                ui.dueMode = mode
                            }
                        }
                    }
                }

                if ui.dueMode == .pick {
                    DayStepper(date: $ui.customDate)
                        .padding(.leading, 6)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: 8)

                SpanField(span: $ui.span)
                    .padding(.trailing, 8)

                // 优先级：四档并排，带文字与色块。
                // 原来只有 17×17 的圆点，既难看清也难点中，这里整体放大。
                PriorityPicker(selected: $ui.priority)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.88), value: ui.dueMode)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 14)
    }

    // MARK: 筛选

    private var filterBar: some View {
        HStack(spacing: 0) {
            // 分段控件读数比下划线更快：底色直接标出「当前在哪一档」
            HStack(spacing: 2) {
                ForEach(ComposerState.Filter.allCases) { option in
                    SegmentTab(
                        title: option.rawValue,
                        selected: ui.filter == option
                    ) {
                        withAnimation(Theme.springSnappy) {
                            ui.filter = option
                        }
                    }
                }
            }
            .padding(2)
            .background(
                Capsule().fill(Theme.surface)
            )
            .overlay(
                Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline)
            )

            Spacer(minLength: 8)

            Text(summary)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var summary: String {
        var parts = ["\(store.stats.pending) 待办"]
        if store.stats.overdue > 0 { parts.append("\(store.stats.overdue) 逾期") }
        if store.stats.done > 0 { parts.append("\(store.stats.done) 完成") }
        return parts.joined(separator: " · ")
    }

    // MARK: 列表

    private var listArea: some View {
        Group {
            if visibleItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.pendingGroupSlices(visibleItems), id: \.key) { group in
                            Section {
                                ForEach(group.items) { item in
                                    MemoRow(
                                        item: item,
                                        isEditing: ui.editingID == item.id,
                                        editingText: $ui.editingText,
                                        onToggle: {
                                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                                                store.toggleDone(item.id)
                                            }
                                        },
                                        onDelete: {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                if let removed = store.delete(item.id) {
                                                    ui.rememberForUndo([removed])
                                                    ui.flash("已删除")
                                                }
                                            }
                                        },
                                        onCyclePriority: { cyclePriority(item) },
                                        onSetSpan: { days in
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                store.setSpan(item.id, to: days)
                                            }
                                        },
                                        onSetPriority: { level in
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                store.setPriority(item.id, to: level)
                                            }
                                        },
                                        onBeginEdit: {
                                            ui.editingID = item.id
                                            ui.editingText = item.title
                                        },
                                        onCommitEdit: {
                                            store.rename(item.id, to: ui.editingText)
                                            ui.editingID = nil
                                        },
                                        onCancelEdit: { ui.editingID = nil }
                                    )
                                    // 增删时整行淡入并轻微上移，而不是瞬间闪现
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity
                                                .combined(with: .move(edge: .top))
                                                .combined(with: .scale(scale: 0.97, anchor: .top)),
                                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))
                                        )
                                    )
                                }
                            } header: {
                                GroupHeader(key: group.key, items: group.items)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // 用 id 序列驱动动画：只有增删/换序才动，改文字不闪
                    .animation(Theme.rowInsert, value: visibleItems.map(\.id))
                    .animation(Theme.easeMedium, value: ui.filter)
                }
                .scrollIndicators(.never)
                .background(Color.clear)
            }
        }
        .animation(Theme.easeMedium, value: visibleItems.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            // 图标放进柔和的圆形底里，比孤零零一个线条更有分量
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 54, height: 54)
                Circle()
                    .strokeBorder(Theme.stroke, lineWidth: Theme.hairline)
                    .frame(width: 54, height: 54)
                Image(systemName: ui.filter == .done ? "checkmark" : "square.and.pencil")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.inkQuaternary)
            }

            VStack(spacing: 3) {
                Text(ui.filter == .all ? "写下第一件事" : "这里还是空的")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)

                Text(ui.filter == .all ? "回车即存，⌥Space 随时召唤" : "换个筛选看看")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkQuaternary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 16) {
            QuietAction(title: "清理已完成") {
                let removed = store.clearDone()
                if !removed.isEmpty {
                    ui.rememberForUndo(removed)
                    ui.flash("已清理 \(removed.count) 条")
                }
            }

            QuietAction(title: "测试提醒") {
                Task { @MainActor in
                    await ReminderService.shared.fireNow(store: store, force: true)
                    ui.flash("已发送")
                }
            }

            Spacer()

            Text(store.lastError ?? "本地")
                .font(.system(size: 10))
                .foregroundStyle(store.lastError == nil ? Color.secondary.opacity(0.5) : Color.red.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.fileURL.path)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(
            // 用渐变收口代替硬分割线：内容向上淡出，而不是被一条线切断
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.022)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: 行为

    private func commit() {
        let text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let dueKey = ui.resolvedDueKey
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            _ = store.add(title: text, priority: ui.priority, dueDate: dueKey, span: ui.span)
            ui.draft = ""
            ui.dueMode = .today
            // 工期不重置：连续录入同类事项时，通常还是同样的工期
            
        }
        ui.flash("已记录")
    }

    private func cyclePriority(_ item: Memo) {
        let all = Priority.allCases
        guard let index = all.firstIndex(of: item.priority) else { return }
        let next = all[(index + 1) % all.count]
        withAnimation(.easeOut(duration: 0.16)) {
            store.setPriority(item.id, to: next)
        }
    }
}

// MARK: - 顶部图标按钮（无边框，悬停才浮现）

struct IconGlyph: View {
    let system: String
    let help: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover.hovering ? Color.primary : Color.secondary.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hover.hovering ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hover.hovering = inside }
        }
    }
}

// MARK: - 安静的文字选项（日期）

struct QuietChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : (hover.hovering ? Color.secondary : Theme.inkTertiary))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.primary.opacity(0.07) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.13)) { hover.hovering = inside }
        }
    }
}

// MARK: - 优先级选择器
//
// 旧版是 4 个 17×17 的圆点：直径 5.5pt 的点、17pt 的命中区，
// 既看不清当前档位，也很难点中。现在改成 4 个并排的分段胶囊：
//   * 每段都有文字，不用背颜色含义
//   * 命中区放大到 22pt 高、每段约 44pt 宽
//   * 选中项共享一个滑动指示器，切换时平滑过渡

struct PriorityPicker: View {
    @Binding var selected: Priority

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Priority.allCases) { level in
                PrioritySegment(
                    level: level,
                    isSelected: selected == level,
                    indicatorNamespace: indicator,
                    reduceMotion: reduceMotion
                ) {
                    guard selected != level else { return }
                    if reduceMotion {
                        selected = level
                    } else {
                        withAnimation(Theme.springSnappy) { selected = level }
                    }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline))
    }
}

private struct PrioritySegment: View {
    let level: Priority
    let isSelected: Bool
    let indicatorNamespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
        @Published var pressed = false
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(level.tint.opacity(isSelected ? 1.0 : 0.80))
                    .frame(width: isSelected ? 6.5 : 5.5, height: isSelected ? 6.5 : 5.5)

                Text(level.label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    // 未选中也用本档颜色的深色版，而不是统一灰：
                    // 四档一眼可分，但仍明显弱于选中态
                    .foregroundStyle(isSelected ? level.tint : level.tint.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            // 命中区比视觉高度再高一点，避免「看着点到了其实没点到」
            .contentShape(Rectangle().inset(by: -3))
            .background {
                if isSelected {
                    Capsule()
                        .fill(level.tint.opacity(0.13))
                        .overlay(
                            Capsule().strokeBorder(level.tint.opacity(0.30), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "priorityIndicator", in: indicatorNamespace)
                } else if hover.hovering {
                    Capsule().fill(Theme.surfaceHover)
                }
            }
            .scaleEffect(hover.pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .help("⌘\(level.rank + 1) · \(level.label)")
        .onHover { inside in
            withAnimation(Theme.easeFast) { hover.hovering = inside }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !hover.pressed { withAnimation(Theme.easeFast) { hover.pressed = true } }
                }
                .onEnded { _ in
                    withAnimation(Theme.springSnappy) { hover.pressed = false }
                }
        )
        .animation(reduceMotion ? nil : Theme.springSnappy, value: isSelected)
    }
}

// MARK: - 分段标签（筛选）
//
// 比下划线更「可点」：选中有实心胶囊底，眼睛不用去追一根 1.5pt 的线。

struct SegmentTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(
                    selected ? Theme.ink
                             : (hover.hovering ? Theme.inkSecondary : Theme.inkTertiary)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(selected ? Theme.surfaceRaised : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Theme.stroke : Color.clear, lineWidth: Theme.hairline)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Theme.easeFast) { hover.hovering = inside }
        }
        .animation(Theme.springSnappy, value: selected)
    }
}

// MARK: - 日期步进器

struct DayStepper: View {
    @Binding var date: Date

    var body: some View {
        HStack(spacing: 0) {
            step("chevron.left") { shift(-1) }

            Text(displayText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 38)
                .contentTransition(.numericText())

            step("chevron.right") { shift(1) }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var displayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    private func shift(_ days: Int) {
        withAnimation(.easeOut(duration: 0.18)) {
            date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        }
    }

    private func step(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组头

struct GroupHeader: View {
    let key: String
    let items: [Memo]

    private var pendingCount: Int { items.filter { !$0.done }.count }
    private var label: DueLabel { DueLabel(dateKey: key) }

    private var isAlerting: Bool { label.isOverdue && pendingCount > 0 }

    var body: some View {
        HStack(spacing: 7) {
            // 逾期分组用一个小圆点做醒目提示，而非整行变色
            if isAlerting {
                Circle()
                    .fill(Priority.urgent.tint)
                    .frame(width: 4, height: 4)
            }

            Text(Self.display(key))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isAlerting ? Priority.urgent.tint : Theme.inkSecondary)
                .tracking(0.2)

            Text(label.text)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(isAlerting ? Priority.urgent.tint.opacity(0.85) : Theme.inkQuaternary)

            Spacer()

            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.inkTertiary)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surface))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 5)
        // pinned header 会被拉伸到滚动区整宽，任何背景都会吃掉左右留白，
        // 所以只画一条极淡的底线来分隔分组。
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: Theme.hairline)
                .padding(.horizontal, 10)
        }
    }

    static func display(_ key: String) -> String {
        guard let date = DateKey.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

// MARK: - 单行

struct MemoRow: View {
    let item: Memo
    let isEditing: Bool
    @Binding var editingText: String
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onCyclePriority: () -> Void
    let onSetSpan: (Int) -> Void
    let onSetPriority: (Priority) -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void

    @StateObject private var hover = HoverState()
    @FocusState private var editFocused: Bool

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
        @Published var pressed = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 勾选圈：悬停时浮现强调色描边，点击有轻微回弹
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            hover.hovering && !item.done ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.22),
                            lineWidth: 1.4
                        )
                        .frame(width: 15, height: 15)

                    if item.done {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 15, height: 15)
                            .transition(.scale(scale: 0.5))
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: 17, height: 17)
                // 命中区放大：17pt 的圆圈实际可点范围更大，不必精确瞄准
                .contentShape(Circle().inset(by: -4))
                .scaleEffect(hover.pressed ? 0.88 : 1)
                .animation(Theme.springBouncy, value: item.done)
            }
            .buttonStyle(.plain)
            .help(item.done ? "标记为未完成" : "标记为已完成")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !hover.pressed { withAnimation(Theme.easeFast) { hover.pressed = true } }
                    }
                    .onEnded { _ in
                        withAnimation(Theme.springBouncy) { hover.pressed = false }
                    }
            )
            .padding(.top, 0.5)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $editingText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($editFocused)
                        .onSubmit(onCommitEdit)
                        .onExitCommand(perform: onCancelEdit)
                        .onAppear { editFocused = true }
                } else {
                    Text(item.title)
                        .font(.system(size: 13, weight: .regular))
                        .strikethrough(item.done, color: Color.secondary.opacity(0.55))
                        .foregroundStyle(item.done ? Theme.inkTertiary : Theme.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: onBeginEdit)
                }

                metaLine
                    .padding(.top, 1)
            }

            Spacer(minLength: 6)

            // 操作只在悬停时出现，保持列表安静
            HStack(spacing: 1) {
                rowAction("pencil", help: "修改", action: onBeginEdit)
                rowAction("trash", help: "删除", action: onDelete)
            }
            .opacity(hover.hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: hover.hovering)

            // 优先级色条：保留但更细更淡，作为扫视时的纵向线索
            Capsule()
                .fill(item.done ? Color.clear : item.priority.tint.opacity(0.55))
                .frame(width: 2.5)
                .padding(.vertical, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hover.hovering ? Theme.surfaceHover : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hover.hovering ? Theme.stroke : Color.clear, lineWidth: Theme.hairline)
        )
        .padding(.horizontal, 2)
        .opacity(item.done ? 0.62 : 1)
        .onHover { inside in
            withAnimation(Theme.easeFast) { hover.hovering = inside }
        }
        .contextMenu {
            Button(item.done ? "标记为未完成" : "标记为已完成", action: onToggle)
            Button("修改", action: onBeginEdit)
            Divider()
            ForEach(Priority.allCases) { level in
                Button("\(level.icon) \(level.label)") { onSetPriority(level) }
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    /// 元信息：优先级标签 · 日期 · 记录时间。
    ///
    /// 优先级从「4pt 小圆点」改成带底色的胶囊 —— 圆点只够区分色相，
    /// 胶囊能同时读出颜色和文字，扫一眼就知道轻重缓急。
    /// 文字用 inkTertiary 而不是 quaternary：后者在深色下仅 2:1，读起来太吃力。
    private var metaLine: some View {
        HStack(spacing: 6) {
            if !item.done {
                // 优先级胶囊：仍是只读标签的样子，但悬停时右侧直接摊开四个色点。
                //
                // 为什么不用 Menu：这个面板是 nonactivating panel，
                // NSMenu 在它上面时常弹不出来（日期选择器踩过同一个坑）。
                // 纯视图内的展开-点选没有这层依赖，响应也更快。
                HStack(spacing: 4) {
                    Text(item.priority.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.priority.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(item.priority.tint.opacity(hover.hovering ? 0.18 : 0.12))
                        )
                        .overlay(
                            Capsule().strokeBorder(item.priority.tint.opacity(0.18), lineWidth: Theme.hairline)
                        )

                    // 四个色点：当前档位实心，其余空心，点一下即改。
                    if hover.hovering {
                        HStack(spacing: 3) {
                            ForEach(Priority.allCases) { level in
                                Button {
                                    onSetPriority(level)
                                } label: {
                                    Circle()
                                        .fill(level == item.priority
                                              ? level.tint
                                              : level.tint.opacity(0.22))
                                        .frame(width: 6, height: 6)
                                        .overlay(
                                            Circle().strokeBorder(
                                                level.tint.opacity(level == item.priority ? 0 : 0.5),
                                                lineWidth: 0.6
                                            )
                                        )
                                        // 命中区比视觉尺寸大一圈，不用瞄准
                                        .contentShape(Circle().inset(by: -3.5))
                                }
                                .buttonStyle(.plain)
                                .help(level.label)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(.easeOut(duration: 0.14), value: hover.hovering)
            }

            Text(item.dueLabel.text)
                .font(.system(size: 9.5, weight: item.dueLabel.isOverdue && !item.done ? .semibold : .regular))
                .foregroundStyle(
                    item.dueLabel.isOverdue && !item.done
                        ? Priority.urgent.tint
                        : Theme.inkTertiary
                )

            // 工期角标：多天的事项才显示，避免单日事项被噪声污染。
            // 悬停时摊开「−/+」，直接加减，不走系统菜单。
            if item.isMultiDay {
                HStack(spacing: 3) {
                    HStack(spacing: 2) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 7.5, weight: .medium))
                        Text("\(item.spanDays) 天")
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surface))

                    if hover.hovering && !item.done {
                        HStack(spacing: 2) {
                            Button { onSetSpan(item.spanDays - 1) } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 7, weight: .bold))
                                    .frame(width: 12, height: 12)
                                    .background(Circle().fill(Theme.surfaceHover))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .contentShape(Circle().inset(by: -2))
                            }
                            .buttonStyle(.plain)
                            .disabled(item.spanDays <= 1)
                            .opacity(item.spanDays <= 1 ? 0.35 : 1)
                            .help("缩短一天")

                            Button { onSetSpan(item.spanDays + 1) } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 7, weight: .bold))
                                    .frame(width: 12, height: 12)
                                    .background(Circle().fill(Theme.surfaceHover))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .contentShape(Circle().inset(by: -2))
                            }
                            .buttonStyle(.plain)
                            .help("延长一天")
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(.easeOut(duration: 0.14), value: hover.hovering)
            }

            if let created = UILogic.createdTimeText(item.createdAt) {
                Text("·")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.inkQuaternary)
                Text(created)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }

    private func rowAction(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 底部安静文字按钮

struct QuietAction: View {
    let title: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(hover.hovering ? Theme.inkSecondary : Theme.inkTertiary.opacity(0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.13)) { hover.hovering = inside }
        }
    }
}

// MARK: - 背景材质

struct VisualEffectBackground: NSViewRepresentable {
    /// 玻璃强度来自设置，改成 ObservedObject 才能实时响应滑杆拖动
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        let target = GlassAppearance.materialAlpha(for: settings.glassStrength)

        guard abs(view.alphaValue - target) > 0.001 else { return }
        // 做一点插值，拖动滑杆时不会一跳一跳的
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            view.animator().alphaValue = target
        }
    }
}

struct GlassVeil: View {
    var strength: Double

    var body: some View {
        ZStack {
            // 着色浓度随强度反向变化：越透的玻璃，越需要一点点色彩把台面压住，
            // 否则背后高对比的内容会顶穿前景文字的可读性。
            Color.white.opacity(GlassAppearance.veilOpacity(for: strength))

            // 品牌色极淡着色，避免整块中性灰
            LinearGradient(
                colors: [Theme.accent.opacity(0.05), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 顶部受光
            LinearGradient(
                colors: [Color.white.opacity(0.08), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .allowsHitTesting(false)
        .opacity(1)
    }
}

extension Notification.Name {
    static let memoFocusInput = Notification.Name("memo.focusInput")
    static let memoSetPriorityShortcut = Notification.Name("memo.setPriorityShortcut")
    static let memoOpenPanel = Notification.Name("memo.openPanel")
    static let memoMenuBarVisibilityChanged = Notification.Name("memo.menuBarVisibility")
    static let memoGlassStrengthChanged = Notification.Name("memo.glassStrengthChanged")
    static let memoOpenSettings = Notification.Name("memo.openSettings")
}

// MARK: - 工期选择

/// 工期：一件事要占用几天。
///
/// 做成「点一下开小面板」而不是下拉菜单，是因为这个面板本身是
/// nonactivating panel，系统的 NSPopUpButton / Menu 在它上面
/// 经常打不开（同样的坑在日期选择上已经踩过）。
struct SpanField: View {
    @Binding var span: Int
    @StateObject private var hover = HoverFlag()

    private static let presets = [1, 2, 3, 5, 7]
    private var title: String { span <= 1 ? "当天" : "\(span) 天" }

    var body: some View {
        // 同样不走系统菜单：改成点一下就地展开一排天数。
        // 面板是 nonactivating panel，NSMenu 在这上面不可靠。
        HStack(spacing: 3) {
            if hover.on {
                HStack(spacing: 1) {
                    ForEach(Self.presets, id: \.self) { d in
                        Button {
                            span = d
                        } label: {
                            Text(d <= 1 ? "1" : "\(d)")
                                .font(.system(size: 9.5, weight: span == d ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(span == d ? Theme.accent : Theme.inkSecondary)
                                .frame(width: 15, height: 15)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(span == d ? Theme.accent.opacity(0.16) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(d <= 1 ? "当天完成" : "\(d) 天")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            }

            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 9.5, weight: .medium))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(hover.on ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(hover.on ? Theme.surfaceHover : Theme.surface))
        }
        .animation(.easeOut(duration: 0.14), value: hover.on)
        .onHover { hover.on = $0 }
        .help("工期：这件事要占用几天")
    }
}

final class HoverFlag: ObservableObject {
    @Published var on = false
}
