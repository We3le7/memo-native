import SwiftUI
import AppKit
import Combine

// MARK: - 设计基调
//
// 目标：简洁、克制、高级。
// 规则：颜色只用来表达「优先级」；其余全部走灰阶层级（primary/secondary/tertiary/quaternary）。
//      不用贯穿的分割线，靠留白与字重区分层次；边框只出现在输入框聚焦时。

enum Theme {
    static let gutter: CGFloat = 18
    static let radius: CGFloat = 10
    static let hairline: CGFloat = 0.5

    // 语义灰阶：统一用 Color.primary 叠不同不透明度，
    // 这样既能适配深浅色，也能在三元表达式里作为具体 Color 参与类型推断
    // （SwiftUI 的 .tertiary/.quaternary 是 ShapeStyle，不能当 Color 用）。
    static let ink = Color.primary
    static let inkSecondary = Color.primary.opacity(0.62)
    static let inkTertiary = Color.primary.opacity(0.42)
    static let inkQuaternary = Color.primary.opacity(0.26)
}

// 优先级配色，与 App 图标里的四个点完全一致
extension Priority {
    var tint: Color {
        switch self {
        case .urgent: return Color(red: 0.898, green: 0.282, blue: 0.302) // #E5484D
        case .high:   return Color(red: 0.941, green: 0.506, blue: 0.059) // #F0810F
        case .normal: return Color(red: 0.851, green: 0.659, blue: 0.000) // #D9A800
        case .low:    return Color(red: 0.184, green: 0.435, blue: 0.929) // #2F6FED
        }
    }
}

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
        .background(VisualEffectBackground())
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: Theme.hairline))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                .padding(.bottom, 46)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: ui.toast)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)

            Text("备忘录")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.2)

            Spacer()

            // 系统时间：静默地作为环境信息，不与内容争抢注意力
            Text(UILogic.clockText(ui.now))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.inkTertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
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
        .padding(.top, 14)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.unreadReminderCount)
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 10) {
            // 输入框：默认无边框，聚焦时才浮现一圈极淡的高亮
            TextField("记点什么…", text: $ui.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .focused($inputFocused)
                .onSubmit(commit)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(Color.primary.opacity(inputFocused ? 0.045 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(
                            inputFocused ? Color.accentColor.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                )
                .animation(.easeOut(duration: 0.2), value: inputFocused)

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

                HStack(spacing: 9) {
                    ForEach(Priority.allCases) { level in
                        DotPicker(
                            level: level,
                            selected: ui.priority == level
                        ) {
                            withAnimation(.easeOut(duration: 0.16)) { ui.priority = level }
                        }
                    }
                    Text(ui.priority.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 26, alignment: .leading)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.88), value: ui.dueMode)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 12)
    }

    // MARK: 筛选

    private var filterBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(ComposerState.Filter.allCases) { option in
                    UnderlineTab(
                        title: option.rawValue,
                        selected: ui.filter == option
                    ) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            ui.filter = option
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
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
                                }
                            } header: {
                                GroupHeader(key: group.key, items: group.items)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .animation(.spring(response: 0.34, dampingFraction: 0.85), value: visibleItems.map(\.id))
                }
                .scrollIndicators(.never)
                .background(Color.clear)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: ui.filter == .done ? "checkmark" : "tray")
                .font(.system(size: 22, weight: .ultraLight))
                .foregroundStyle(Theme.inkQuaternary)
            Text(ui.filter == .all ? "写下第一件事" : "这里还是空的")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
        .padding(.top, 8)
        .padding(.bottom, 11)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: Theme.hairline)
        }
    }

    // MARK: 行为

    private func commit() {
        let text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let dueKey = ui.resolvedDueKey
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            _ = store.add(title: text, priority: ui.priority, dueDate: dueKey)
            ui.draft = ""
            ui.dueMode = .today
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

// MARK: - 优先级圆点

struct DotPicker: View {
    let level: Priority
    let selected: Bool
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // 选中的圆点外套一圈极淡的环，替代胶囊底色
                Circle()
                    .strokeBorder(level.tint.opacity(selected ? 0.45 : 0), lineWidth: 1.2)
                    .frame(width: 15, height: 15)

                Circle()
                    .fill(level.tint.opacity(selected ? 1.0 : 0.35))
                    .frame(width: selected ? 7 : 5.5, height: selected ? 7 : 5.5)
            }
            .frame(width: 17, height: 17)
            .contentShape(Rectangle())
            .opacity(hover.hovering && !selected ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .help("⌘\(level.rank + 1) · \(level.label)")
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hover.hovering = inside }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: selected)
    }
}

// MARK: - 下划线标签页（筛选）

struct UnderlineTab: View {
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
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : (hover.hovering ? Color.secondary : Theme.inkTertiary))

                Capsule()
                    .fill(Color.primary.opacity(selected ? 0.55 : 0))
                    .frame(height: 1.5)
                    .frame(maxWidth: selected ? .infinity : 0)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.13)) { hover.hovering = inside }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selected)
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
        HStack(spacing: 6) {
            Text(Self.display(key))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.3)

            Text(label.text)
                .font(.system(size: 9.5, weight: isAlerting ? .medium : .regular))
                .foregroundStyle(isAlerting ? Priority.urgent.tint : Theme.inkTertiary)

            Spacer()

            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
    let onSetPriority: (Priority) -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void

    @StateObject private var hover = HoverState()
    @FocusState private var editFocused: Bool

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14.5, weight: .light))
                    .foregroundStyle(item.done ? Color.accentColor : Color.primary.opacity(hover.hovering ? 0.35 : 0.20))
            }
            .buttonStyle(.plain)
            .help(item.done ? "标记为未完成" : "标记为已完成")
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
                        .font(.system(size: 12.5))
                        .strikethrough(item.done, color: Color.secondary.opacity(0.6))
                        .foregroundStyle(item.done ? Color.secondary.opacity(0.75) : Color.primary)
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

            // 优先级色条：唯一常驻的颜色提示，极细
            Capsule()
                .fill(item.done ? Color.clear : item.priority.tint.opacity(0.75))
                .frame(width: 2)
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hover.hovering ? Color.primary.opacity(0.032) : Color.clear)
        )
        .padding(.horizontal, 2)
        .opacity(item.done ? 0.6 : 1)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hover.hovering = inside }
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

    /// 元信息：优先级圆点 · 日期 · 记录时间。
    /// 用 inkTertiary 而不是 quaternary —— 后者在深色下仅 2:1，读起来太吃力。
    private var metaLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(item.priority.tint.opacity(item.done ? 0.35 : 0.9))
                .frame(width: 4, height: 4)

            Text(item.dueLabel.text)
                .font(.system(size: 9.5, weight: item.dueLabel.isOverdue && !item.done ? .medium : .regular))
                .foregroundStyle(
                    item.dueLabel.isOverdue && !item.done
                        ? Priority.urgent.tint.opacity(0.9)
                        : Theme.inkTertiary
                )

            if let created = UILogic.createdTimeText(item.createdAt) {
                Text("·")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.7))
                Text(created)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary.opacity(0.7))
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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
    static let memoFocusInput = Notification.Name("memo.focusInput")
    static let memoSetPriorityShortcut = Notification.Name("memo.setPriorityShortcut")
    static let memoOpenPanel = Notification.Name("memo.openPanel")
    static let memoMenuBarVisibilityChanged = Notification.Name("memo.menuBarVisibility")
    static let memoOpenSettings = Notification.Name("memo.openSettings")
}
