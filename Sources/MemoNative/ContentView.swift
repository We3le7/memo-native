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

    /// 正在录入的子要点（标题之下、发出去之前的暂存）
    @Published var draftPoints: [String] = []
    /// 要点输入行的当前文字
    @Published var pointDraft: String = ""
    @Published var priority: Priority = .normal
    /// 新事项的工期（天）
    @Published var span: Int = 1
    @Published var filter: Filter = .all
    @Published var editingID: String?
    @Published var editingText: String = ""
    /// 正在编辑的事项的子要点（进入编辑时从 item.bulletPoints 复制）
    @Published var editingPoints: [String] = []
    /// 编辑要点时的当前输入
    @Published var editingPointDraft: String = ""

    /// 进入编辑：把标题和要点都复制进来
    func beginEdit(_ item: Memo) {
        editingID = item.id
        editingText = item.title
        editingPoints = item.bulletPoints
        editingPointDraft = ""
    }

    /// 追加一条要点到正在编辑的事项
    @discardableResult
    func appendEditingPoint() -> Bool {
        let before = editingPoints.count
        editingPoints = UILogic.appendingBullet(editingPoints, editingPointDraft)
        guard editingPoints.count > before else { return false }
        editingPointDraft = ""
        return true
    }

    func endEdit() {
        editingID = nil
        editingPoints = []
        editingPointDraft = ""
    }

    @Published var toast: String?
    @Published var now: Date = Date()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", today = "今天", pending = "未完成", done = "已完成"
        var id: String { rawValue }
    }

    /// 列表 / 卡片两种排布。
    ///
    /// 卡片不是"列表换个样子"——它服务于另一种扫视方式：
    /// 列表适合逐条读文字，卡片适合一眼看清有多少件事、
    /// 各自多急。条数少时卡片更舒服，条数多时列表更高效。
    /// 所以这个开关交给用户，不替他决定。
    @Published var layout: Layout = .list {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "memoLayout") }
    }

    enum Layout: String, CaseIterable, Identifiable {
        case list = "列表"
        case card = "卡片"
        var id: String { rawValue }
        var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "memoLayout"),
           let saved = Layout(rawValue: raw) {
            layout = saved
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

    /// 追加一条草稿要点。返回是否成功（空内容或已满则失败）。
    @discardableResult
    func appendPoint() -> Bool {
        let before = draftPoints.count
        draftPoints = UILogic.appendingBullet(draftPoints, pointDraft)
        guard draftPoints.count > before else { return false }
        pointDraft = ""
        return true
    }

    /// 清空要点相关的全部暂存状态
    func resetPoints() {
        draftPoints = []
        pointDraft = ""
    }

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

    /// 新事项的日期。
    ///
    /// 固定为今天：界面上已不再提供日期选择键（只保留工期）。
    /// 想改日期可以在记下之后行内编辑，比录入时先选日期更顺手。
    var resolvedDueKey: String {
        UILogic.dueKey(offsetDays: 0)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @ObservedObject var store: MemoStore
    @ObservedObject var settings: AppSettings
    @StateObject private var ui = ComposerState()
    @FocusState private var inputFocused: Bool
    @FocusState private var pointFocused: Bool
    @StateObject private var writeBtn = PressState()

    @MainActor
    final class PressState: ObservableObject {
        @Published var pressed = false
    }

    /// 能不能写入：标题非空即可。
    /// 要点是可选的，不影响能否提交。
    private var canWrite: Bool {
        !ui.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            // composer 抬到最上层：工期滚轮是从输入区向下弹出的浮层，
            // 不抬高就会被下面的筛选栏和列表挡住。
            // zIndex 只在同一层 VStack 的子视图之间比较，所以加在这里。
            composer
                .zIndex(2)
            filterBar
            listArea
            footer
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 660)
        // 展开形变交给 Core Animation（见 PanelController.playUnfold/playFold）。
        //
        // 原来这里是 .scaleEffect(...) + .opacity(...)，由 @Published 逐帧驱动：
        // 每一帧 SwiftUI 都要重算这一千多行的视图树，还要重新栅格化
        // NSVisualEffectView 那层玻璃，帧率被压得很低，看起来一顿一顿的。
        //
        // 现在视图内容是静态的，窗口图层的 transform 由 CA 驱动——
        // 合成发生在渲染服务里，SwiftUI 一次都不用重算，能跑满刷新率。
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
            // 这里不画阴影。
            //
            // 也不要交回给窗口：NSWindow.hasShadow 由窗口服务按**窗口矩形**
            // 绘制，不随内容图层的 transform 缩放——展开/折叠时内容缩到 0.06，
            // 阴影却保持完整的 600×660 轮廓留在原地，看着像"底下还有一层页面"。
            //
            // 面板不带阴影，靠圆角描边和玻璃本身的明度差与桌面分层。
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
                .contentTransition(.opacity)
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
            //
            // 之前的问题：
            //   · 清空按钮和 ↵ 提示都挤在框内，和文字抢位置
            //   · 三个元素（铅笔画、文字、两个按钮）平铺在一行，没有主次
            //   · 聚焦时整框描边变强调色，但紫色描边 + 紫色柔光有些过重
            //
            // 现在：
            //   · 左侧铅笔改为**聚焦时填充色块**——不看文字也知道焦点在哪
            //   · 文字独占中间，两侧只放最必要的
            //   · 回车提示改成独立胶囊，像真的键帽；只在有内容时才亮
            HStack(spacing: 10) {
                // 图标只用文字色阶，不加色块。
                // 输入框里唯一的"颜色"就是用户打的字，其余都该退到背后。
                Image(systemName: "pencil.line")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(inputFocused ? Theme.inkSecondary : Theme.inkQuaternary)
                    .frame(width: 17, height: 19)
                    // 聚焦时轻轻弹一下，给出"可以打字了"的即时反馈
                    .scaleEffect(inputFocused ? 1.0 : 0.94)
                    .animation(Theme.springBouncy, value: inputFocused)

                TextField("记点什么…", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .regular))
                    .focused($inputFocused)
                    .onSubmit(commit)

                if !ui.draft.isEmpty {
                    Button {
                        withAnimation(Theme.easeFast) { ui.draft = "" }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(Theme.surfaceHover))
                            .contentShape(Circle().inset(by: -2))
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // 写入按钮：标题框右侧的主操作。
                //
                // 之前只有一个 ↵ 键帽提示"可以按回车"，但那需要用户
                // 把焦点放回标题框再按。按钮是直接可点的，
                // 而且它把"写入备忘录"这件事变成了一个明确动作，
                // 而不是一个要记住的快捷键。
                //
                // 图标用箭头向下入托盘：动作方向是"把内容收进去"，
                // 比一个勾更贴切（勾暗示"确认/完成"，这里是"收录"）。
                Button(action: commit) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("写入")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(canWrite ? Color.white : Theme.inkQuaternary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(canWrite ? Theme.accent : Theme.surfaceHover)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            canWrite ? Color.clear : Theme.stroke,
                            lineWidth: Theme.hairline
                        )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canWrite)
                .help("写入备忘录（回车）")
                .scaleEffect(writeBtn.pressed ? 0.95 : 1)
                .animation(Theme.springBouncy, value: writeBtn.pressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !writeBtn.pressed { withAnimation(Theme.easeFast) { writeBtn.pressed = true } }
                        }
                        .onEnded { _ in
                            withAnimation(Theme.springBouncy) { writeBtn.pressed = false }
                        }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(inputFocused ? Theme.surfaceRaised : Theme.surface)
            )
            .overlay(
                // 聚焦靠"描边加深 + 底色抬起"，不靠染色。
                // 输入框里唯一该有颜色的是文字本身。
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Theme.inkQuaternary : Theme.stroke,
                        lineWidth: inputFocused ? 1.0 : Theme.hairline
                    )
            )
            .shadow(
                color: .black.opacity(inputFocused ? 0.07 : 0.05),
                radius: inputFocused ? 8 : 4,
                y: inputFocused ? 2 : 1
            )
            .animation(Theme.springSnappy, value: inputFocused)
            .animation(Theme.easeFast, value: ui.draft.isEmpty)

            // 子要点区：常驻，不折叠。
            //
            // 早先是"点开才出现"，那样每次记要点都要多一步；
            // 上限收到 3 条之后，这块的高度最多 4 行，
            // 常驻也不会把输入区顶高，没有折叠的必要了。
            VStack(alignment: .leading, spacing: 5) {
                // 已加的要点：每条右侧一个删除键（悬停才显形）
                ForEach(Array(ui.draftPoints.enumerated()), id: \.offset) { index, point in
                    DraftPointRow(
                        text: point,
                        onChange: { newText in
                            ui.draftPoints = UILogic.replacingBullet(
                                ui.draftPoints, at: index, with: newText
                            )
                        },
                        onDelete: {
                            withAnimation(Theme.springSnappy) {
                                ui.draftPoints = UILogic.removingBullet(ui.draftPoints, at: index)
                            }
                        }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.94))
                        )
                    )
                }

                // 要点输入行
                HStack(spacing: 7) {
                    // 圆点：和列表里要点用同一个符号，形成呼应
                    Circle()
                        .fill(Theme.inkQuaternary)
                        .frame(width: 3.5, height: 3.5)
                        .padding(.leading, 2)

                    TextField(
                        UILogic.canAddBullet(ui.draftPoints)
                            ? "加一条要点，回车添加"
                            : "最多 \(UILogic.maxBulletPoints) 条",
                        text: $ui.pointDraft
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($pointFocused)
                    .disabled(!UILogic.canAddBullet(ui.draftPoints))
                    .onSubmit(addPoint)

                    if !ui.draftPoints.isEmpty {
                        Text(UILogic.bulletSummary(ui.draftPoints))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkQuaternary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            pointFocused ? Theme.inkQuaternary : Theme.stroke,
                            lineWidth: pointFocused ? 1 : Theme.hairline
                        )
                )
            }

            // 一行承载：日期 + 优先级。文字优先，颜色只用于优先级圆点。
            HStack(spacing: 0) {
                // 工期放在最左，且直接展开——不用先悬停再点。
                // 它是这一行里最常调的东西，藏在悬停后面等于每次
                // 都多一步；常驻反而更快，也让这一行有个自然的起点。
                // 图标留在选择器左侧：一眼看出这一排调的是工期，
                // 而不是另一个"分几档"的抽象选项。
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 16)
                        .help("工期")

                    SpanPicker(span: $ui.span)
                }
                .padding(.trailing, 10)

                Spacer(minLength: 8)

                // 优先级：四档并排，带文字与色块。
                // 原来只有 17×17 的圆点，既难看清也难点中，这里整体放大。
                PriorityPicker(selected: $ui.priority)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 14)
    }

    // MARK: 筛选

    @Namespace private var filterIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filterBar: some View {
        HStack(spacing: 0) {
            // 分段控件读数比下划线更快：底色直接标出「当前在哪一档」。
            // 用 matchedGeometryEffect 让选中底块在档位之间滑动，
            // 与右侧优先级选择器完全同一套手感——同一个界面里的
            // 两个同构控件应该用同一种动效，否则会觉得哪里不对劲。
            HStack(spacing: 2) {
                ForEach(ComposerState.Filter.allCases) { option in
                    FilterSegment(
                        title: option.rawValue,
                        isSelected: ui.filter == option,
                        indicatorNamespace: filterIndicator
                    ) {
                        guard ui.filter != option else { return }
                        if reduceMotion {
                            ui.filter = option
                        } else {
                            withAnimation(Theme.springSnappy) { ui.filter = option }
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
                .contentTransition(.opacity)

            // 排布切换。放在读数右边、紧挨内容区，
            // 因为它影响的是"下面怎么排"，不是筛什么。
            LayoutToggle(selected: $ui.layout, reduceMotion: reduceMotion)
                .padding(.leading, 10)
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
            } else if ui.layout == .card {
                cardArea
            } else {
                ScrollView {
                    // 不再按日期分组。
                    //
                    // 分组曾经是有道理的：那时排序也是日期优先，分组头和
                    // 排序规则一致，读起来是"今天的事 / 明天的事"。
                    // 现在排序改成紧急程度优先，再按日期分组就会出现
                    // 「紧急」那一组里混着今天和下周的事，分组反而打断阅读。
                    //
                    // 日期信息没有丢：它现在显示在每行的元信息里
                    //（逾期会标红），是"这条事项的属性"而不是"组织方式"。
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleItems) { item in
                            memoRow(for: item)
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

    /// 单张卡片。同样为了避开类型检查超时而抽出来。
    private func memoCard(for item: Memo, index: Int) -> some View {
        MemoCard(
            item: item,
            isEditing: ui.editingID == item.id,
            editingText: $ui.editingText,
            editingPoints: $ui.editingPoints,
            editingPointDraft: $ui.editingPointDraft,
            onSubmitPoint: { ui.appendEditingPoint() },
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
            onBeginEdit: { ui.beginEdit(item) },
            onCommitEdit: {
                store.rename(item.id, to: ui.editingText)
                store.setNote(item.id, to: Memo.noteText(from: ui.editingPoints))
                ui.endEdit()
            },
            onCancelEdit: { ui.endEdit() },
            onSetPriority: { level in
                withAnimation(.easeOut(duration: 0.16)) {
                    store.setPriority(item.id, to: level)
                }
            }
        )
        .modifier(CardFlyIn(index: index, enabled: !reduceMotion))
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.94)),
                removal: .opacity.combined(with: .scale(scale: 0.94))
            )
        )
    }

    /// 卡片网格。
    ///
    /// 卡片视图不做日期分组——分组标题在网格里会把连续感切断，
    /// 而卡片的意义正是"一眼看全"。
    private var cardArea: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let horizontalPadding: CGFloat = 8
            let usable = geo.size.width - horizontalPadding * 2
            let columns = UILogic.cardColumnCount()
            let cardWidth = UILogic.cardWidth(
                available: Double(usable),
                columns: columns,
                spacing: Double(spacing)
            )

            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top),
                        count: columns
                    ),
                    spacing: spacing
                ) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        memoCard(for: item, index: index)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 8)
                .animation(Theme.rowInsert, value: visibleItems.map(\.id))
            }
            .scrollIndicators(.never)
        }
    }

    /// 单行列表项。
    ///
    /// 抽成方法而不是写在 ForEach 里：闭包串太长会让
    /// Swift 的类型检查器超时（compiler unable to type-check
    /// in reasonable time）。拆开后每个函数的表达式规模可控。
    private func memoRow(for item: Memo) -> some View {
        MemoRow(
            item: item,
            isEditing: ui.editingID == item.id,
            editingText: $ui.editingText,
            editingPoints: $ui.editingPoints,
            editingPointDraft: $ui.editingPointDraft,
            onSubmitPoint: { ui.appendEditingPoint() },
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
            onBeginEdit: { ui.beginEdit(item) },
            onCommitEdit: {
                store.rename(item.id, to: ui.editingText)
                store.setNote(item.id, to: Memo.noteText(from: ui.editingPoints))
                ui.endEdit()
            },
            onCancelEdit: { ui.endEdit() }
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

        // 要点输入行里还有没提交的文字，一并收进去——
        // 用户写完最后一条要点直接回车，不该丢掉它。
        if let pending = UILogic.normalizeBullet(ui.pointDraft) {
            ui.draftPoints = UILogic.appendingBullet(ui.draftPoints, pending)
        }

        let dueKey = ui.resolvedDueKey
        let note = Memo.noteText(from: ui.draftPoints)
        // 先记下条数：下面 resetPoints() 会把 draftPoints 清空，
        // 之后再读就是 0，提示语会永远显示"已记录"。
        let pointCount = ui.draftPoints.count
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            _ = store.add(
                title: text,
                priority: ui.priority,
                dueDate: dueKey,
                span: ui.span,
                note: note
            )
            ui.draft = ""
            ui.resetPoints()
            // 工期不重置：连续录入同类事项时，通常还是同样的工期
        }
        ui.flash(pointCount == 0 ? "已记录" : "已记录，含 \(pointCount) 条要点")
    }

    /// 添加一条要点。空内容不做事，也不收起键盘——用户可以继续输。
    private func addPoint() {
        guard ui.appendPoint() else { return }
        // 不移动焦点：连续加要点时焦点留在原处最顺手
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
                    .foregroundStyle(isSelected ? level.tint : level.tint.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            // 命中区比视觉高度再高一点，避免「看着点到了其实没点到」
            .contentShape(Rectangle().inset(by: -3))
            .background {
                if isSelected {
                    // 底块与描边用动态色：深色模式需要更实的填充和描边，
                    // 否则选中的胶囊在深灰背景上几乎看不出边界。
                    Capsule()
                        .fill(level.tint.opacity(0.20))
                        .overlay(
                            Capsule().strokeBorder(level.tint.opacity(0.75), lineWidth: 1)
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
/// 筛选档位：与 PrioritySegment 同一套结构与动效。
///
/// 右栏的优先级选择器、左栏的筛选器，是同一种控件（一排互斥档位）。
/// 它们必须用同一种动效——底块从旧位置滑到新位置，而不是各自淡入淡出。
/// 同一个界面里两个同构控件手感不同，会让人下意识觉得哪里不对。
struct FilterSegment: View {
    let title: String
    let isSelected: Bool
    let indicatorNamespace: Namespace.ID
    let action: () -> Void

    @StateObject private var hover = HoverState()

    @MainActor
    final class HoverState: ObservableObject {
        @Published var hovering = false
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(
                    isSelected ? Theme.ink
                               : (hover.hovering ? Theme.inkSecondary : Theme.inkTertiary)
                )
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 22)
                .contentShape(Rectangle().inset(by: -3))
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.surfaceRaised)
                            .overlay(
                                Capsule().strokeBorder(Theme.stroke, lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "filterIndicator", in: indicatorNamespace)
                    } else if hover.hovering {
                        Capsule().fill(Theme.surfaceHover)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Theme.easeFast) { hover.hovering = inside }
        }
        .animation(Theme.springSnappy, value: isSelected)
    }
}

// MARK: - 单行

// MARK: - 要点编辑器

/// 已有事项的要点编辑区：列出全部要点，可改可删，底部一行添加。
///
/// 列表和卡片共用同一个组件——两套实现迟早会走偏。
struct PointsEditor: View {
    @Binding var points: [String]
    @Binding var draft: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.inkTertiary)
                        .frame(width: 3, height: 3)
                        .padding(.leading, 1)

                    TextField(
                        "",
                        text: Binding(
                            get: { point },
                            set: { points = UILogic.replacingBullet(points, at: index, with: $0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)

                    Button {
                        withAnimation(Theme.springSnappy) {
                            points = UILogic.removingBullet(points, at: index)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Theme.inkQuaternary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("删除这条要点")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.inkQuaternary)
                    .padding(.leading, 1)

                TextField("加一条要点，回车添加", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($focused)
                    .disabled(!UILogic.canAddBullet(points))
                    .onSubmit(onSubmit)
            }
            .padding(.vertical, 2)
        }
        .padding(.top, 3)
    }
}

// MARK: - 草稿要点行

/// 输入区里已添加的一条要点。
///
/// 双击可就地改写——加了几条之后发现打错字，
/// 不该只能删掉重打。
private struct DraftPointRow: View {
    let text: String
    let onChange: (String) -> Void
    let onDelete: () -> Void

    @StateObject private var hover = HoverFlag()
    @StateObject private var edit = EditState()
    @FocusState private var focused: Bool

    @MainActor
    final class EditState: ObservableObject {
        @Published var editing = false
        @Published var buffer = ""
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.inkTertiary)
                .frame(width: 3.5, height: 3.5)
                .padding(.leading, 2)

            if edit.editing {
                TextField("", text: $edit.buffer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { edit.editing = false }
                    .onAppear { focused = true }

                Button(action: commit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("保存")
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        edit.buffer = text
                        edit.editing = true
                    }

                if hover.on {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Theme.surfaceHover))
                            .contentShape(Circle().inset(by: -2))
                    }
                    .buttonStyle(.plain)
                    .help("删除这条要点")
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover.on || edit.editing ? Theme.surface : Color.clear)
        )
        .onHover { inside in
            withAnimation(Theme.easeFast) { hover.on = inside }
        }
    }

    private func commit() {
        onChange(edit.buffer)
        edit.editing = false
    }
}

// MARK: - 排布切换

/// 列表 / 卡片切换。
///
/// 用图标而不是文字：两个图标是通用隐喻，不占宽度，
/// 也让筛选栏的右侧不至于又多一排文字。
/// 选中态沿用 FilterSegment 的滑动底块，保证同一界面里
/// 所有"几选一"控件的手感一致。
struct LayoutToggle: View {
    @Binding var selected: ComposerState.Layout
    let reduceMotion: Bool

    @Namespace private var indicator
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ComposerState.Layout.allCases) { option in
                Button {
                    guard selected != option else { return }
                    if reduceMotion {
                        selected = option
                    } else {
                        // 切换整体给一个稍长的时长：卡片要靠 onAppear
                        // 触发的飞入动画，事务太短会让它来不及起步。
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            selected = option
                        }
                    }
                } label: {
                    Image(systemName: option.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected == option ? Theme.inkSecondary : Theme.inkQuaternary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle().inset(by: -2))
                        .background {
                            if selected == option {
                                Capsule()
                                    .fill(Theme.surfaceRaised)
                                    .overlay(
                                        Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline)
                                    )
                                    .matchedGeometryEffect(id: "layoutIndicator", in: indicator)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(option == .list ? "列表视图" : "卡片视图")
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline))
        .animation(reduceMotion ? nil : Theme.springSnappy, value: selected)
    }
}

// MARK: - 卡片飞入

/// 卡片逐个飞入。
///
/// 为什么不用 matchedGeometryEffect 让卡片"从列表行的位置长出来"：
/// 列表是 LazyVStack（带分组 Section），卡片是 LazyVGrid，
/// 两者的布局容器完全不同，Lazy 容器里的元素在切换瞬间
/// 未必都已布局，几何匹配会闪、会错位。
///
/// 所以改成错位飞入：每张卡从下方 18pt、缩放 0.92 淡入，
/// 按序号延迟，读起来像"一叠卡片被摊开"。
/// 这个效果不依赖跨容器的几何信息，稳定且每帧都能跑满。
private struct CardFlyIn: ViewModifier {
    let index: Int
    let enabled: Bool

    @StateObject private var state = FlyState()

    @MainActor
    final class FlyState: ObservableObject {
        @Published var landed = false
    }

    /// 每张比前一张晚这么久。太快会糊成一片，太慢会显得卡。
    private static let stagger: Double = 0.022
    /// 最多错开 8 张。再多的话最后几张要等太久，
    /// 后面的卡与前面的同时落位反而更利落。
    private static let maxStaggered = 8

    private var delay: Double {
        guard enabled else { return 0 }
        return Double(min(index, Self.maxStaggered)) * Self.stagger
    }

    func body(content: Content) -> some View {
        content
            .opacity(state.landed ? 1 : 0)
            .scaleEffect(state.landed ? 1 : 0.92, anchor: .top)
            .offset(y: state.landed ? 0 : 18)
            // 用 .task 而不是 .onAppear：
            //
            // onAppear 里直接改状态，SwiftUI 可能把它和首帧提交合并，
            // 于是没有"从 0 到 1"的中间态，卡片直接闪现而不是飞入。
            // 先 yield 一次，让 landed=false 的那一帧真正渲染出来，
            // 再启动动画，起止状态就都确立了。
            .task {
                guard enabled else {
                    state.landed = true
                    return
                }
                await Task.yield()
                withAnimation(
                    .spring(response: 0.38, dampingFraction: 0.82).delay(delay)
                ) {
                    state.landed = true
                }
            }
            // 不在 onDisappear 里重置：LazyVGrid 滚出屏幕会触发它，
            // 滚回来时卡片会再飞一次，看着像界面在抽动。
            // 切回列表时整个卡片子树被销毁，@StateObject 自然丢弃，
            // 下次进来照样从 0 开始——重置这一步本来就是多余的。
    }
}

// MARK: - 卡片视图

/// 卡片：两列网格，比列表多显示日期，支持原地编辑。
///
/// 和 MemoRow 的分工：
///   · 行 —— 逐条读文字，条数多时效率高
///   · 卡片 —— 一眼看全局，同时保留足够的元信息（日期、工期、优先级）
///
/// 两列（约 280pt）而不是三列：三列塞不下日期，
/// 而日期是"这件事什么时候该做"的核心信息，不该在卡片里缺席。
struct MemoCard: View {
    let item: Memo
    let isEditing: Bool
    @Binding var editingText: String
    @Binding var editingPoints: [String]
    @Binding var editingPointDraft: String
    let onSubmitPoint: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onSetPriority: (Priority) -> Void

    @StateObject private var hover = Hover()
    @FocusState private var editFocused: Bool

    @MainActor
    final class Hover: ObservableObject {
        @Published var hovering = false
        @Published var pressed = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部色带：卡片的"情绪值"。
            // 不用整张卡着色——那会让并排的卡糊成一片；
            // 一条 3pt 的顶边足够区分，又不干扰读标题。
            Rectangle()
                .fill(item.done ? Theme.inkQuaternary.opacity(0.5) : item.priority.tint)
                .frame(height: 3)

            VStack(alignment: .leading, spacing: 7) {
                // ── 第一行：标题 + 勾选 ──
                HStack(alignment: .top, spacing: 6) {
                    if isEditing {
                        TextField("", text: $editingText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .focused($editFocused)
                            .onSubmit(onCommitEdit)
                            .onExitCommand(perform: onCancelEdit)
                            .onAppear { editFocused = true }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.surfaceHover)
                            )
                    } else {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .strikethrough(item.done, color: Color.secondary.opacity(0.55))
                            .foregroundStyle(item.done ? Theme.inkTertiary : Theme.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            // 单击即编辑：卡片面积大，双击反而多余；
                            // 列表用双击是因为行很窄，单击容易误触。
                            .onTapGesture(count: 2, perform: onBeginEdit)
                    }

                    Button(action: onToggle) {
                        ZStack {
                            Circle()
                                .strokeBorder(
                                    hover.hovering && !item.done
                                        ? Theme.accent.opacity(0.7)
                                        : Theme.inkQuaternary,
                                    lineWidth: 1.2
                                )
                                .frame(width: 13, height: 13)
                            if item.done {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 13, height: 13)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 15, height: 15)
                        .contentShape(Circle().inset(by: -3))
                        .scaleEffect(hover.pressed ? 0.88 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(item.done ? "标记为未完成" : "标记为已完成")
                }

                Spacer(minLength: 2)

                // ── 子要点 ──
                // 卡片比列表宽裕，显示全部。
                if isEditing {
                    PointsEditor(
                        points: $editingPoints,
                        draft: $editingPointDraft,
                        onSubmit: onSubmitPoint
                    )
                } else if item.hasPoints {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.bulletPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 5) {
                                Circle()
                                    .fill(Theme.inkQuaternary)
                                    .frame(width: 2.5, height: 2.5)
                                    .padding(.top, 5)
                                Text(point)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 1)
                }

                // ── 第二行：日期 + 工期 ──
                //
                // 日期是卡片相对列表多出来的信息，用图标领起，
                // 逾期时整段转为警示色——扫视时最先看到的就是它。
                HStack(spacing: 4) {
                    Image(systemName: item.dueLabel.isOverdue ? "exclamationmark.circle.fill" : "calendar")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(dueTint)

                    Text(item.dueLabel.text)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(dueTint)

                    if item.isMultiDay {
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.inkQuaternary)
                        Text("\(item.spanDays) 天")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                    }

                    Spacer(minLength: 4)

                    if hover.hovering && !isEditing {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                        .transition(.opacity)
                    }
                }

                // ── 第三行：优先级 ──
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(item.done ? Theme.inkQuaternary : item.priority.tint)
                        .frame(width: 3, height: 8)
                    Text(item.priority.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.done ? Theme.inkTertiary : item.priority.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        // 不写死高度：标题最多三行，1 行与 3 行相差 34pt。
        // 网格里同一行的卡片会被 LazyVGrid 拉齐到最高者，
        // 所以视觉上仍然整齐，不会参差。
        .frame(minHeight: UILogic.cardMinHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover.hovering ? Theme.surfaceRaised : Theme.surface)
                .animation(Theme.easeFast, value: hover.hovering)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isEditing ? Theme.inkQuaternary
                              : (hover.hovering ? Theme.strokeStrong : Theme.stroke),
                    lineWidth: isEditing ? 1 : Theme.hairline
                )
        )
        .opacity(item.done ? 0.62 : 1)
        .scaleEffect(hover.pressed ? 0.975 : 1)
        .animation(Theme.springBouncy, value: hover.pressed)
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

    /// 日期颜色：逾期用警示红，今天用强调色，其余中性。
    private var dueTint: Color {
        if item.done { return Theme.inkTertiary }
        if item.dueLabel.isOverdue { return Priority.urgent.tint }
        if item.dueLabel.isToday { return Theme.accent }
        return Theme.inkTertiary
    }
}
struct MemoRow: View {
    let item: Memo
    let isEditing: Bool
    @Binding var editingText: String
    @Binding var editingPoints: [String]
    @Binding var editingPointDraft: String
    let onSubmitPoint: () -> Void
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

                // 子要点：列表里只显示前三条，超出折叠成"+N"。
                // 行高有限，全部铺开会把列表变得很长；
                // 想看全的切到卡片视图。
                if isEditing {
                    // 编辑态：要点可改可删可加
                    PointsEditor(
                        points: $editingPoints,
                        draft: $editingPointDraft,
                        onSubmit: onSubmitPoint
                    )
                } else if item.hasPoints {
                    VStack(alignment: .leading, spacing: 1.5) {
                        ForEach(Array(item.bulletPoints.prefix(3).enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 5) {
                                Circle()
                                    .fill(Theme.inkQuaternary)
                                    .frame(width: 2.5, height: 2.5)
                                    .padding(.top, 5)
                                Text(point)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                        if item.bulletPoints.count > 3 {
                            Text("还有 \(item.bulletPoints.count - 3) 条")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.inkQuaternary)
                                .padding(.leading, 7.5)
                        }
                    }
                    .padding(.top, 3)
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
                        // 每格 16×16 方形命中区，视觉圆点仍是 8pt。
                        //
                        // 16pt 帧 + 2pt 间距，圆心距 18pt；
                        // 视觉间隙 = (16-8)/2*2 + 2 = 10pt？不是——着色只在
                        // 中间 8pt，所以圆与圆的空白是 2 + 2 + 2 = 6pt，
                        // 稍微比原来的 3pt 松一点，但换来的命中区大得多：
                        // 256pt² vs 原来 133pt²，几乎翻倍。
                        //
                        // 为什么不用 contentShape(Circle().inset(by:)) 外扩：
                        // 外扩会让相邻命中区互相重叠（点间距 13pt、
                        // 外扩后命中直径 18pt，重叠 5pt），
                        // 点在两个圆之间时选中哪个是不确定的。
                        // 方形帧 + 1pt 间距刚好相接不重叠，四角也能点。
                        HStack(spacing: UILogic.dotHitSpacing) {
                            ForEach(Priority.allCases) { level in
                                Button {
                                    onSetPriority(level)
                                } label: {
                                    // 胶囊：两端正半圆，中间一段平直。
                                    //
                                    // 正圆看着是"一个点"，圆角方块偏硬，
                                    // 胶囊是这两者之间最像"档位块"的形状——
                                    // 四个并排时像一排小开关，扫视时很容易
                                    // 认出这是四个可选项。
                                    Capsule(style: .continuous)
                                    .fill(level == item.priority
                                          ? level.tint
                                          : level.tint.opacity(0.22))
                                    .frame(
                                        width: UILogic.dotVisualWidth,
                                        height: UILogic.dotVisualSize
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                        .strokeBorder(
                                            level.tint.opacity(level == item.priority ? 0 : 0.5),
                                            lineWidth: 0.7
                                        )
                                    )
                                        .frame(
                                            width: UILogic.dotHitFrame,
                                            height: UILogic.dotHitFrame
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(level.label)
                            }
                        }
                        // 固定行高：色点放大后不能把整行撑高，
                        // 否则鼠标移入/移出时列表会跳一下。
                        .frame(height: 12)
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

// MARK: - 工期选择（与优先级同构）

/// 工期选择：结构与 PriorityPicker 完全一致。
///
/// 同一个输入行里并排两个互斥档位控件，必须用同一套结构：
/// 同样的胶囊外壳、同样的 matchedGeometryEffect 滑动底块、
/// 同样的悬停/按下/弹簧参数。任何一处不同，
/// 眼睛都会立刻觉得"这两个不是一类东西"。
struct SpanPicker: View {
    @Binding var span: Int

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 快捷档位。和优先级一样是有限的几档——
    /// 常用工期其实只有这几个，给无限可调反而增加决策成本。
    static let presets = [1, 2, 3, 5, 7]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.presets, id: \.self) { d in
                SpanSegment(
                    days: d,
                    isSelected: span == d,
                    indicatorNamespace: indicator,
                    reduceMotion: reduceMotion
                ) {
                    guard span != d else { return }
                    if reduceMotion {
                        span = d
                    } else {
                        withAnimation(Theme.springSnappy) { span = d }
                    }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: Theme.hairline))
    }
}

private struct SpanSegment: View {
    let days: Int
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

    /// 工期选择器整体走中性色，不引入色相。
    ///
    /// 理由：它和输入框是同一件事的两半——都是"这条事项是什么"，
    /// 而不是"这条事项有多急"。优先级必须用颜色区分四档，
    /// 工期只是同一个值的几个常见档位，染色反而抢注意力。
    /// 选中由底块 + 描边 + 加粗表达，够了。
    private var tint: Color { Theme.ink }

    private var label: String { days <= 1 ? "当天" : "\(days) 天" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // 圆点与优先级同位同尺寸，保持两排节奏一致
                Circle()
                    .fill(isSelected ? tint : Theme.inkTertiary)
                    .frame(width: isSelected ? 6.5 : 5.5, height: isSelected ? 6.5 : 5.5)

                Text(label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? tint : Theme.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .contentShape(Rectangle().inset(by: -3))
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.selectionFill)
                        .overlay(
                            Capsule().strokeBorder(Theme.selectionStroke, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "spanIndicator", in: indicatorNamespace)
                } else if hover.hovering {
                    Capsule().fill(Theme.surfaceHover)
                }
            }
            .scaleEffect(hover.pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .help(days <= 1 ? "当天完成" : "\(days) 天")
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

final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// 工期数字的按压反馈：按下时轻微下沉，松开回弹。
///
/// 15pt 的方块太小，光靠颜色变化反馈不够明确；
/// 这点位移让人确信"点到了"。
struct SpanPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
