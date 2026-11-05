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
        // 必须包在 withAnimation 里：
        // 不包的话 ForEach 的增删没有事务，行是"啪"地出现/消失，
        // 上面那条 .transition 等于白写。
        var added = false
        withAnimation(Theme.rowInsert) {
            editingPoints = UILogic.appendingBullet(editingPoints, editingPointDraft)
            added = editingPoints.count > before
        }
        guard added else { return false }
        // 清空草稿用更快的曲线：它只是一行文字的消失，
        // 跟着入场动画一起慢慢淡掉会显得拖沓。
        withAnimation(Theme.hover) { editingPointDraft = "" }
        return true
    }

    func endEdit() {
        editingID = nil
        editingPoints = []
        editingPointDraft = ""
    }

    /// 失焦保存的守卫：避免 commit/cancel 之后又被延迟回调重复执行。
    private var focusLostToken = 0

    /// 编辑框失焦时该怎么办。
    ///
    /// 不能立刻保存。焦点在同一个编辑区里挪动（标题 → 要点输入框）
    /// 也会触发一次"失焦"，立刻保存会把还没写完的要点截断，
    /// 而且会让界面在两次点击之间闪一下。
    ///
    /// 所以延迟一小会儿再判断：如果那时焦点仍没回到这条事项的
    /// 编辑控件上，才算真的离开了。
    ///
    /// token 里带上事项 id。这是必须的——
    /// editingText 是全局共享的，用户完全可能在这 120ms 内
    /// 已经点到另一条事项并开始编辑。那时的 editingText 是新事项的
    /// 内容，拿它去保存旧事项，会把旧事项改成别人家的标题。
    func scheduleFocusLostCheck(for id: String, commit: @escaping () -> Void) {
        focusLostToken += 1
        let token = focusLostToken
        Task { @MainActor in
            // 让出当前 runloop，等焦点真正落定
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard token == self.focusLostToken else { return }
            // 这期间换过对象或已退出编辑，就作废
            guard self.editingID == id else { return }
            commit()
        }
    }

    /// 焦点回到编辑区时取消待执行的保存
    func cancelPendingFocusLost() {
        focusLostToken += 1
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
        var added = false
        withAnimation(Theme.rowInsert) {
            draftPoints = UILogic.appendingBullet(draftPoints, pointDraft)
            added = draftPoints.count > before
        }
        guard added else { return false }
        withAnimation(Theme.hover) { pointDraft = "" }
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
    /// 上一次的字数，用来判断是"输入"还是"删除"。
    /// 只是记个数字，不需要触发重绘，所以不是 @Published。
    @StateObject private var lengthBox = LengthBox()
    @StateObject private var inputHover = HoverFlag()
    /// 提交瞬间的脉冲：让"写完了"这件事有一个物理落点。
    ///
    /// 没有它的话，按回车后文字消失、列表多一行，
    /// 两个变化同时发生，眼睛抓不住"刚刚发生了什么"。
    /// 先缩一下再弹回，等于给这次操作画了个句号。
    @StateObject private var submitPulse = HoverFlag()
    /// 打字脉冲：每敲入一个字，图标轻轻跳一下。
    ///
    /// 这是"闪亮"的实质——不是颜色更艳，而是有生命感。
    /// 幅度必须极小（1.06 倍、0.1s），否则就成了干扰：
    /// 用户注意力该在字上，图标只是余光里的呼吸。
    @StateObject private var typePulse = HoverFlag()
    @FocusState private var pointFocused: Bool
    @StateObject private var writeBtn = PressState()

    @MainActor
    final class PressState: ObservableObject {
        @Published var pressed = false
        @Published var hovering = false
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
        // 挂在根视图上而不是列表上：面板收起时列表未必还活着
        //（空状态时 listArea 走的是 emptyState 分支），
        // 挂在子树里会有收不到通知的情况。
        .onReceive(NotificationCenter.default.publisher(for: .memoPanelWillFold)) { _ in
            commitEditingIfNeeded()
        }
        // 点到编辑区之外 → 结束编辑。
        // 不能只靠 @FocusState：点一片空白时 TextField 根本不会失焦。
        .onReceive(NotificationCenter.default.publisher(for: .memoClickOutsideEditing)) { _ in
            exitEditingIfNeeded()
        }
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
                withAnimation(Theme.tap) { ui.priority = level }
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
                            withAnimation(Theme.move) {
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
        .animation(Theme.move, value: ui.toast)
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
                withAnimation(Theme.tap) { store.markRemindersRead() }
            }
            IconGlyph(system: "gearshape", help: "设置") {
                SettingsWindowController.shared.show()
            }
            IconGlyph(system: "xmark", help: "隐藏（Esc）") { PanelController.shared.hide() }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .animation(Theme.move, value: store.unreadReminderCount)
    }

    // MARK: 输入区

    /// 输入框左侧图标的颜色。
    ///
    /// 只在主题的墨色阶里走，不引入新色相——
    /// 输入框里唯一该有颜色的是用户打的字。
    /// "闪亮"靠明度与那圈 6~10% 的强调色微光，不靠换个颜色。
    /// 图标的缩放。
    ///
    /// 三层叠加，顺序有意义：
    ///   底座  —— 静止略小(0.97)、悬停略大(1.02)，暗示"可以点/可以去"
    ///   聚焦  —— 回到 1.0
    ///   打字脉冲 —— 在此基础上再跳 1.08
    /// 乘法叠加，所以每一层都在前一层的基础上生效。
    private var iconScale: CGFloat {
        var scale: CGFloat = inputFocused ? 1.0 : (inputHover.on ? 1.02 : 0.97)
        if typePulse.on { scale *= 1.08 }
        return scale
    }

    private var iconTint: Color {
        if inputFocused { return Theme.iconActive }
        return inputHover.on ? Theme.iconHover : Theme.iconIdle
    }

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
                // 图标：放大、并给一点"亮"的感觉。
                //
                // 但"亮"不能靠加一个新颜色——输入框里唯一的颜色
                // 该是用户打的字。它是一个中性的书写入口，
                // 突然出现一个绿色/蓝色图标会立刻突兀。
                //
                // 做法是在**主题色阶内部**做文章：
                //   静止  inkQuaternary(0.24)  很淡，但形状够大看得见
                //   悬停  inkTertiary(0.44)    告知"这里有焦点可去"
                //   聚焦  inkSecondary(0.66) + 一圈极淡的发光底
                //
                // 那个"发光"是 accent 色 6% 的实心圆，不是 shadow——
                // 界面里所有浮层都不带阴影，输入框也不破例。
                // 6% 的强调绿在深色模式下几乎不可见，在浅色下
                // 是一层温热的光，刚好够"闪亮"而不抢戏。
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(inputFocused ? 0.10 : (inputHover.on ? 0.05 : 0)))
                        .frame(width: 26, height: 26)
                        .blur(radius: inputFocused ? 3 : 0)

                    Image(systemName: "pencil.line")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconTint)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 22, height: 22)
                // 聚焦时轻轻放大一点，像被"点亮"
                .scaleEffect(iconScale)
                .animation(Theme.confirm, value: inputFocused)
                .animation(Theme.hover, value: inputHover.on)
                // 打字脉冲用更短的曲线：0.1s 的跳动必须立刻收回，
                // 用 confirm(0.42s) 会拖成一串慢动作。
                .animation(Theme.hover, value: typePulse.on)
                .onHover { inside in
                    withAnimation(Theme.hover) { inputHover.on = inside }
                }

                TextField("记点什么…", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .regular))
                    .focused($inputFocused)
                    .onSubmit(commit)
                    .onChange(of: ui.draft) { newValue in
                        // 只在变长时跳。删除给同样的正反馈很怪——
                        // 退格不该有奖励感。
                        let grew = newValue.count > lengthBox.value
                        lengthBox.value = newValue.count
                        guard grew, inputFocused, !reduceMotion else { return }
                        typePulse.on = true
                        // 用代数作废旧任务。
                        //
                        // 直接 asyncAfter 0.1s 把 on 设回 false 有个坑：
                        // 连着打字时每个字符都排一个"取消"任务，
                        // 而先排的那个会在**新字符触发扭动之前**把状态清掉，
                        // 于是快速打字时脉冲根本不动——越流畅越没效果。
                        //
                        // 每次跳动换一个代数，只认最新那个的收尾。
                        lengthBox.pulseGeneration &+= 1
                        let gen = lengthBox.pulseGeneration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            guard lengthBox.pulseGeneration == gen else { return }
                            typePulse.on = false
                        }
                    }

                if !ui.draft.isEmpty {
                    Button {
                        // 清空整框给一个明确的退场动画：
                        // 文字瞬间消失会让人不确定"是清空了还是没打成"。
                        withAnimation(Theme.move) { ui.draft = "" }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(Theme.surfaceHover))
                            .contentShape(Circle().inset(by: -2))
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // 确认按钮：标题框右侧的主操作。
                //
                // 之前只有一个 ↵ 键帽提示"可以按回车"，但那需要用户
                // 把焦点放回标题框再按。按钮是直接可点的，
                // 而且它把"记下这件事"变成了一个明确动作，
                // 而不是一个要记住的快捷键。
                //
                // 配色走中性墨色，不用强调绿。
                // 绿色在这个界面里是"状态"（未完成事项的强调、
                // 低优先级的色标），不是"按钮"。一个常驻按钮染成
                // 强调色，会把用户的注意力一直吸在一个每次都要点、
                // 但已经不需要找的地方，也抢掉输入框本身的视觉重心。
                //
                // 做法是"深色实心 + 反色文字"：在深色和浅色模式下
                // 都成立，因为墨色本来就是跟随外观翻转的，
                // 反色文字自然跟着一起翻。
                // 有内容才展开文字。
                //
                // 空输入框时只留一个勾号，宽度收窄——
                // 没东西可确认的时候，"确认"两个字是纯噪音，
                // 而且它一直占着位置，让输入框显得拥挤。
                //
                // 有内容时文字滑出来，同时按钮变实心：
                // 一个动作在"可执行"的瞬间变大、变亮，
                // 是比常驻更清楚的提示。
                Button(action: commit) {
                    HStack(spacing: canWrite ? 4 : 0) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        if canWrite {
                            Text("确认")
                                .font(.system(size: 11, weight: .semibold))
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                        }
                    }
                    .foregroundStyle(canWrite ? Theme.panelBackgroundInverted : Theme.inkQuaternary)
                    .padding(.horizontal, canWrite ? 10 : 7)
                    .frame(height: 24)
                    .animation(Theme.confirm, value: canWrite)
                    .background(
                        Capsule().fill(
                            canWrite
                                ? AnyShapeStyle(Theme.ink.opacity(0.88))
                                : AnyShapeStyle(Theme.surfaceHover)
                        )
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
                .help("确认并记下（回车）")
                // 中性按钮比强调色按钮更需要悬停反馈：
                // 没有颜色托底，"能点"这件事只能靠明度变化表达。
                .brightness(writeBtn.hovering && canWrite ? 0.05 : 0)
                .onHover { inside in
                    withAnimation(Theme.hover) { writeBtn.hovering = inside }
                }
                .scaleEffect(writeBtn.pressed ? 0.95 : 1)
                .animation(Theme.confirm, value: writeBtn.pressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !writeBtn.pressed { withAnimation(Theme.hover) { writeBtn.pressed = true } }
                        }
                        .onEnded { _ in
                            withAnimation(Theme.confirm) { writeBtn.pressed = false }
                        }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            // 聚焦时整框极轻微地"提起来"。
            //
            // 1pt 的上移 + 0.4% 放大，几乎看不出来，但配合底色抬起，
            // 会让人觉得这个框离眼睛近了一点——这就是"被唤起"的感觉。
            // 再大就会显得轻浮，输入框不该在眼前跳。
            //
            // 用 move（较慢）而不是 tap（很快）：
            // 位置变化比颜色变化需要更多时间才显得自然，
            // 颜色该立刻响应，位移慢半拍才有重量。
            .offset(y: inputFocused ? -1 : 0)
            .scaleEffect(inputFocused ? 1.004 : 1, anchor: .center)
            .animation(Theme.move, value: inputFocused)
            // 提交脉冲：轻微收缩。这里用 confirm（带回弹）而不是
            // 平缓曲线——收回去的过程本身就该有一点弹性，
            // 像把东西按进抽屉。
            .scaleEffect(submitPulse.on ? 0.985 : 1)
            .animation(Theme.confirm, value: submitPulse.on)
            .background(
                // 聚焦时底色抬起：这是"这个框现在活了"最主要的一层。
                //
                // 不用阴影。界面里所有浮层都不带阴影，
                // 输入框深陷在面板里，投影会立刻暴露它是个"贴上去的块"。
                // 用明度差表达层次更干净——深色模式下抬到
                // surfaceRaised 已经足够分辨。
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(inputFocused ? Theme.surfaceRaised : Theme.surface)
            )
            .overlay(
                // 描边：聚焦时加深并加宽一点点
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Theme.inkQuaternary : Theme.stroke,
                        lineWidth: inputFocused ? 1.0 : Theme.hairline
                    )
            )
            .overlay(alignment: .top) {
                // 顶部一道 1px 高光：像光从上方打在框沿上。
                //
                // 这一笔很轻（7% 墨色），但正是它让框看起来"鼓起来"了，
                // 比阴影省事也干净。聚焦时更亮一些。
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.ink.opacity(inputFocused ? 0.10 : 0.055),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
                    .padding(.horizontal, Theme.radius)
                    .opacity(inputFocused ? 1 : 0.6)
            }
            .animation(Theme.tap, value: inputFocused)
            .animation(Theme.hover, value: ui.draft.isEmpty)

            // 子要点区：常驻，不折叠。
            //
            // 早先是"点开才出现"，那样每次记要点都要多一步；
            // 上限收到 3 条之后，这块的高度最多 4 行，
            // 常驻也不会把输入区顶高，没有折叠的必要了。
            VStack(alignment: .leading, spacing: 5) {
                // 已加的要点：每条右侧一个删除键（悬停才显形）
                ForEach(Array(zip(UILogic.bulletIdentities(ui.draftPoints), ui.draftPoints.enumerated())),
                        id: \.0) { _, pair in
                    let (index, point) = pair
                    DraftPointRow(
                        text: point,
                        onChange: { newText in
                            ui.draftPoints = UILogic.replacingBullet(
                                ui.draftPoints, at: index, with: newText
                            )
                        },
                        onDelete: {
                            withAnimation(Theme.tap) {
                                withAnimation(Theme.rowRemove) {
                                    ui.draftPoints = UILogic.removingBullet(ui.draftPoints, at: index)
                                }
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
                            // 整张列表要换掉，不是一个小控件的状态变化，
                            // 用 move（中尺度）而不是 tap（即时反馈）。
                            withAnimation(Theme.move) { ui.filter = option }
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
                    // 列表 ↔ 卡片交叉淡入，并沿切换方向轻微错位：
                    // 卡片"铺开"，列表"收起"。
                    // 只淡入淡出会显得两张列表叠在一起化掉，
                    // 加一点位移才有"换了一种摊法"的感觉。
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity
                                .combined(with: .scale(scale: 1.01, anchor: .top))
                        )
                    )
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
                    .animation(Theme.move, value: ui.filter)
                }
                .scrollIndicators(.never)
                .background(Color.clear)
                // 与卡片对称：列表"收起"时略微收拢，卡片"铺开"时略放大。
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 1.01, anchor: .top)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.98, anchor: .top))
                    )
                )
            }
        }
        .animation(Theme.move, value: visibleItems.isEmpty)
        // 这里**不能**写 .animation(value: ui.layout)。
        //
        // 试过，会让面板根本展不开：容器级的隐式动画会把整棵布局树
        // 卷进一个事务，而面板展开时尺寸从 0 变到 600×660，
        // 这个动画和窗口的逐帧尺寸设置互相拉扯，首次布局卡死。
        // 分支的 transition 靠 LayoutToggle 里那圈 withAnimation 驱动，够了。
    }

    /// 单张卡片。同样为了避开类型检查超时而抽出来。
    private func memoCard(for item: Memo, index: Int) -> some View {
        MemoCard(
            item: item,
            isEditing: ui.editingID == item.id,
            editingText: $ui.editingText,
            editingPoints: $ui.editingPoints,
            editingPointDraft: $ui.editingPointDraft,
            onAddPoint: { ui.appendEditingPoint() },
            onToggle: {
                withAnimation(Theme.confirm) {
                    store.toggleDone(item.id)
                }
            },
            onDelete: {
                withAnimation(Theme.rowRemove) {
                    if let removed = store.delete(item.id) {
                        ui.rememberForUndo([removed])
                        ui.flash("已删除")
                    }
                }
            },
            onBeginEdit: {
                withAnimation(Theme.move) { ui.beginEdit(item) }
            },
            onCommitEdit: { commitEdit(item) },
            onCancelEdit: { ui.endEdit() },
            onFocusLost: {
                ui.scheduleFocusLostCheck(for: item.id) { commitEdit(item) }
            },
            onFocusInPoints: { ui.cancelPendingFocusLost() },
            onSetSpan: { days in
                withAnimation(Theme.tap) { store.setSpan(item.id, to: days) }
            },
            onSetPriority: { level in
                withAnimation(Theme.tap) {
                    store.setPriority(item.id, to: level)
                }
            }
        )
        .editingRegion(ui.editingID == item.id)
        .modifier(CardFlyIn(index: index, enabled: !reduceMotion))
        // 进出场不对称：进来时轻轻放大到位，离开时缩得更小、并往下沉一点。
        // 缩得更小是为了让"消失"读起来像被抽走，而不是原地变透明——
        // 同尺寸的淡出在密集网格里很像闪烁。
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.86, anchor: .center))
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
                // 顶部留 3pt：悬停时卡片会上浮 1.5pt，
                // 不留空间第一行会被 ScrollView 裁掉上边缘。
                .padding(.top, 3)
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
            onAddPoint: { ui.appendEditingPoint() },
            onToggle: {
                withAnimation(Theme.confirm) {
                    store.toggleDone(item.id)
                }
            },
            onDelete: {
                withAnimation(Theme.rowRemove) {
                    if let removed = store.delete(item.id) {
                        ui.rememberForUndo([removed])
                        ui.flash("已删除")
                    }
                }
            },
            onCyclePriority: { cyclePriority(item) },
            onSetSpan: { days in
                withAnimation(Theme.tap) {
                    store.setSpan(item.id, to: days)
                }
            },
            onSetPriority: { level in
                withAnimation(Theme.tap) {
                    store.setPriority(item.id, to: level)
                }
            },
            onBeginEdit: {
                withAnimation(Theme.move) { ui.beginEdit(item) }
            },
            onCommitEdit: { commitEdit(item) },
            onCancelEdit: { ui.endEdit() },
            onFocusLost: {
                ui.scheduleFocusLostCheck(for: item.id) { commitEdit(item) }
            },
            onFocusInPoints: { ui.cancelPendingFocusLost() }
        )
        .editingRegion(ui.editingID == item.id)
        // 增删时整行淡入并轻微上移，而不是瞬间闪现
        // 列表行更瘦，横向抽出比缩放更贴合"一条被拿掉"。
        .transition(
            .asymmetric(
                insertion: .opacity
                    .combined(with: .move(edge: .top))
                    .combined(with: .scale(scale: 0.97, anchor: .top)),
                removal: .opacity
                    .combined(with: .move(edge: .leading))
                    .combined(with: .scale(scale: 0.94, anchor: .leading))
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
        withAnimation(Theme.rowInsert) {
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
        // 缩一下再弹回。0.09s 足够被感知，又不会拖慢连续录入。
        submitPulse.on = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            submitPulse.on = false
        }

        ui.flash(pointCount == 0 ? "已记录" : "已记录，含 \(pointCount) 条要点")
    }

    /// 添加一条要点。空内容不做事，也不收起键盘——用户可以继续输。
    private func addPoint() {
        guard ui.appendPoint() else { return }
        // 不移动焦点：连续加要点时焦点留在原处最顺手
    }

    /// 保存正在编辑的标题与要点，并退出编辑态。
    ///
    /// 抽成方法是因为回车提交、失焦提交、点完成按钮三条路
    /// 都要做同样的事——两份实现迟早会有一处漏掉要点。
    /// 面板即将收起时，把正在编辑的内容存下来。
    ///
    /// 面板一收，窗口失去 key，SwiftUI 的 @FocusState 未必会
    /// 走 onChange（窗口级失焦和控件级失焦不是一回事）。
    /// 用户改了一半标题、点别处让面板收起——不存就等于白改。
    /// 点到别处：保存并退出编辑。
    ///
    /// 和失焦保存走同一条路（commitEdit），
    /// 区别只是触发源不同——这里是明确的点击，不需要再延迟判断。
    private func exitEditingIfNeeded() {
        guard let id = ui.editingID,
              let item = store.items.first(where: { $0.id == id }) else { return }
        // 取消可能在排队的失焦保存，避免同一件事存两遍
        ui.cancelPendingFocusLost()
        commitEdit(item)
    }

    private func commitEditingIfNeeded() {
        guard let id = ui.editingID,
              let item = store.items.first(where: { $0.id == id }) else { return }
        commitEdit(item)
    }

    private func commitEdit(_ item: Memo) {
        // 用动画包住：编辑态进出时，文字和输入框要交叉淡入淡出，
        // 不然就是一帧硬切——标题"啪"地变成输入框。
        withAnimation(Theme.move) {
            store.rename(item.id, to: ui.editingText)
            store.setNote(item.id, to: Memo.noteText(from: ui.editingPoints))
            ui.endEdit()
        }
    }

    private func cyclePriority(_ item: Memo) {
        let all = Priority.allCases
        guard let index = all.firstIndex(of: item.priority) else { return }
        let next = all[(index + 1) % all.count]
        withAnimation(Theme.tap) {
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
            withAnimation(Theme.hover) { hover.hovering = inside }
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
                        withAnimation(Theme.tap) { selected = level }
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
            withAnimation(Theme.hover) { hover.hovering = inside }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !hover.pressed { withAnimation(Theme.hover) { hover.pressed = true } }
                }
                .onEnded { _ in
                    withAnimation(Theme.tap) { hover.pressed = false }
                }
        )
        .animation(reduceMotion ? nil : Theme.tap, value: isSelected)
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
            withAnimation(Theme.hover) { hover.hovering = inside }
        }
        .animation(Theme.tap, value: isSelected)
    }
}

// MARK: - 编辑区标记

extension View {
    /// 编辑态时，把整块区域登记为"编辑区"。
    ///
    /// 必须覆盖**整个**编辑区域，不能只盖标题框——
    /// 点了要点输入框却被判成"点在外面"，编辑会立刻被关掉，
    /// 用户连一条要点都加不进去。
    func editingRegion(_ active: Bool) -> some View {
        overlay(alignment: .topLeading) {
            if active {
                GeometryReader { _ in
                    // .frame(maxWidth:.infinity, maxHeight:.infinity)
                    // 不能省：NSViewRepresentable 默认按自身尺寸布局，
                    // GeometryReader 里不撑开就会拿到 0 尺寸，
                    // 登记上去的矩形是空的，判定永远为"点在外面"。
                    EditingRegionMarker()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// 记录"编辑区"在窗口里的位置。
///
/// 目的：点击监控要能回答"这一下是点在编辑里，还是点在外面"。
///
/// 一开始想走响应链——给标记视图设个 layer name，点击后沿
/// superview 往上找。行不通：标记是叠加层、不是 TextField 的祖先，
/// 而且它为了让鼠标穿透必须 hitTest 返回 nil，那就更不会出现在
/// 命中链里了。
///
/// 改成登记表：标记视图自己登记矩形，点击时比一下坐标。
final class EditingRegionRegistry {
    static let shared = EditingRegionRegistry()

    /// 当前处于编辑态的区域（窗口坐标）。通常只有 0 或 1 个。
    private var regions: [ObjectIdentifier: NSRect] = [:]

    func register(_ view: NSView) {
        regions[ObjectIdentifier(view)] = frameInWindow(view)
    }

    func unregister(_ view: NSView) {
        regions.removeValue(forKey: ObjectIdentifier(view))
    }

    /// 刷新（布局变化后矩形会变）
    func refresh(_ view: NSView) {
        guard regions[ObjectIdentifier(view)] != nil else { return }
        regions[ObjectIdentifier(view)] = frameInWindow(view)
    }

    /// 点在这个点上算不算"在编辑区内"。
    /// 判定本身交给 UILogic（纯逻辑，可测）。
    func contains(windowPoint: NSPoint) -> Bool {
        let regions = regions.values.compactMap { rect -> UILogic.Region? in
            guard rect.width > 0, rect.height > 0 else { return nil }
            return UILogic.Region(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.width),
                height: Double(rect.height)
            )
        }
        return UILogic.hitTest(
            point: (x: Double(windowPoint.x), y: Double(windowPoint.y)),
            regions: regions
        )
    }

    func clear() { regions.removeAll() }

    private func frameInWindow(_ view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        let inWindow = view.convert(view.bounds, to: nil)
        // convert(to: nil) 给的是窗口坐标
        _ = window
        return inWindow
    }
}

/// 把一块 SwiftUI 视图登记为"编辑区"。
///
/// 透明、不拦截鼠标，只负责把自己的矩形报上去。
struct EditingRegionMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) { nsView.refresh() }

    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                EditingRegionRegistry.shared.register(self)
            } else {
                EditingRegionRegistry.shared.unregister(self)
            }
        }

        override func layout() {
            super.layout()
            refresh()
        }

        func refresh() {
            EditingRegionRegistry.shared.refresh(self)
        }
    }
}

// MARK: - 要点编辑器

/// 已有事项的要点编辑区：列出全部要点，可改可删，底部一行添加。
///
/// 列表和卡片共用同一个组件——两套实现迟早会走偏。
/// 要点行里的圆形小按钮（加号 / 叉号）。
///
/// 抽出来是为了两者**必然**长一样。
/// 之前加号是 18pt 带底色的圆、叉号是 7.5pt 的裸图标，
/// 并排看着像两个不同时代的控件。
///
/// 尺寸取舍：可见 16pt、可点 22pt。
/// 这一行本身不到 20pt 高，按钮再大就会把行撑开；
/// 再小则点不中——它是纯鼠标目标，没有键盘捷径。
struct PointIconButton: View {
    let symbol: String
    let help: String
    /// 主操作（加号）高亮，删除（叉号）保持安静
    var prominent: Bool = false
    /// 可点
    var enabled: Bool = true
    let action: () -> Void

    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(Circle().fill(fill))
                .overlay(
                    Circle().strokeBorder(border, lineWidth: Theme.hairline)
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { inside in
            withAnimation(Theme.hover) { hover.on = inside }
        }
        .animation(Theme.tap, value: enabled)
    }

    private var tint: Color {
        guard enabled else { return Theme.inkQuaternary }
        // 叉号是删除，不该比加号更抢眼
        return prominent ? Theme.ink : (hover.on ? Theme.inkSecondary : Theme.inkTertiary)
    }

    private var fill: Color {
        guard enabled else { return .clear }
        if prominent { return Theme.selectionFill }
        return hover.on ? Theme.surfaceHover : .clear
    }

    private var border: Color {
        guard enabled else { return Theme.stroke }
        return prominent ? Theme.selectionStroke : Theme.stroke
    }
}

/// 一个可发布的 Bool。工具链没有 @State 宏，只能用 ObservableObject 兜。
final class InputModeFlag: ObservableObject {
    @Published var on = false
}

/// 只用来在多次 onChange 之间记一个数字，不需要触发重绘。
final class LengthBox: ObservableObject {
    var value = 0
    /// 每次打字脉冲递增，用来作废上一轮的"取消"任务
    var pulseGeneration = 0
}

struct PointsEditor: View {
    @Binding var points: [String]
    @Binding var draft: String
    /// 点加号时添加一条。不叫 onSubmit：它现在已经不是
    /// 回车触发的了，名字得跟着行为走。
    let onAdd: () -> Void
    /// 焦点进入要点区时调用。
    /// 用来取消"标题失焦即保存"的待执行动作——
    /// 从标题点进要点输入框，不该被当成离开了编辑。
    var onFocusGained: () -> Void = {}

    @FocusState private var focused: Bool
    @StateObject private var hoverPrompt = HoverFlag()

    /// 还能不能再加一条
    private var canAdd: Bool { UILogic.canAddBullet(points) }

    /// 能不能提交：还有空位，且输入框里有内容
    private var canCommit: Bool {
        canAdd && UILogic.normalizeBullet(draft) != nil
    }

    /// 用户主动要求展开输入行。
    ///
    /// 不能直接用 `focused` 控制展开——那是个循环依赖：
    /// focused 为 true 才渲染 TextField，而 TextField 出现之前
    /// `.focused($focused)` 无从建立，焦点就丢了。
    /// 所以用一个独立的状态先把它"展开出来"，
    /// 渲染完再把焦点送进去。
    @StateObject private var inputMode = InputModeFlag()

    /// 要不要把输入行展开。
    ///
    /// 一条要点都没有时，不默认撑出一个空输入框——
    /// 那个空框会让人以为"这里必须填点什么"，
    /// 而要点本来是可选的分点补充。
    ///
    /// 收起时只留一行很轻的"加一条要点"，点它才展开。
    /// 已经开始输入就保持展开，否则打字打到一半框会消失。
    private var showsInput: Bool {
        !points.isEmpty || inputMode.on || !draft.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(zip(UILogic.bulletIdentities(points), points.enumerated())),
                    id: \.0) { _, pair in
                let (index, point) = pair
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
                    .onTapGesture { onFocusGained() }

                    PointIconButton(symbol: "xmark", help: "删除这条要点") {
                        // 删除用退场曲线，不是 tap——
                        // 这是一行要消失，不是一个小开关变状态。
                        withAnimation(Theme.rowRemove) {
                            points = UILogic.removingBullet(points, at: index)
                        }
                    }
                }
                // 进出场不对称：新的一条从上滑入并展开，
                // 删掉的那条向左缩走——和列表行删除同一套语言，
                // 整个界面里"东西没了"都是这个动作。
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .top))
                            .combined(with: .scale(scale: 0.96, anchor: .leading)),
                        removal: .opacity
                            .combined(with: .move(edge: .leading))
                            .combined(with: .scale(scale: 0.92, anchor: .leading))
                    )
                )
            }

            if showsInput {
            // 添加行：输入框 + 加号按钮，**回车不添加**。
            //
            // 编辑已有事项时，回车常常只是"输完了、手离开键盘"，
            // 并不等于"确认新增这一条"。自动添加会让人在
            // 只想改标题、顺手按了下回车时，凭空多出一条要点。
            //
            // 新增是需要明确表达的动作，所以只认那个加号。
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.inkQuaternary)
                    .frame(width: 3, height: 3)
                    .padding(.leading, 1)

                TextField(
                    canAdd
                        ? "加一条要点"
                        : "已达 \(UILogic.maxBulletPoints) 条上限",
                    text: $draft
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .disabled(!canAdd)
                .onChange(of: focused) { isFocused in
                    if isFocused { onFocusGained() }
                }

                // 加号按钮：只在输入框有内容时才亮起来。
                // 与叉号用同一个组件，保证两个按钮必然一致。
                PointIconButton(
                    symbol: "plus",
                    help: canAdd ? "添加这条要点" : "已达 \(UILogic.maxBulletPoints) 条上限",
                    prominent: true,
                    enabled: canCommit
                ) {
                    onAdd()
                    // 加完之后把焦点还给输入框：
                    // 点按钮会让输入框失焦，不还回去的话
                    // 想连加第二条还得重新点一下输入框。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        focused = true
                    }
                }
            }
            .padding(.vertical, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
            } else if canAdd {
                // 收起态：一行很轻的入口。
                //
                // 它不抢视线，但点得到——这是"想加点什么"的起点。
                Button {
                    // 先展开，再送焦点。
                    // 同一帧里既展开又聚焦是不行的：
                    // TextField 还没被创建，焦点无处可落。
                    withAnimation(Theme.move) { inputMode.on = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        focused = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .semibold))
                        Text("加一条要点")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.inkQuaternary)
                    .padding(.leading, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加一条要点（可选）")
                .onHover { inside in
                    withAnimation(Theme.hover) {
                        hoverPrompt.on = inside
                    }
                }
                .foregroundStyle(hoverPrompt.on ? Theme.inkSecondary : Theme.inkQuaternary)
                .transition(.opacity)
            }
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
    @StateObject private var hoverPrompt = HoverFlag()

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
            withAnimation(Theme.hover) { hover.on = inside }
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
                        withAnimation(Theme.move) {
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
        .animation(reduceMotion ? nil : Theme.tap, value: selected)
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
    let onAddPoint: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    /// 编辑框失去焦点时调用（用于"点别处即保存"）
    let onFocusLost: () -> Void
    /// 焦点进入要点区时调用（取消待执行的失焦保存）
    let onFocusInPoints: () -> Void
    let onSetSpan: (Int) -> Void
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
                // 悬停时顶带横向"涨"一点：从 88% 宽度回到满宽。
                // 比整块变色含蓄，但眼睛能捕捉到卡片"醒了"。
                .scaleEffect(x: hover.hovering ? 1 : 0.88, y: 1, anchor: .leading)
                .animation(Theme.move, value: hover.hovering)

            VStack(alignment: .leading, spacing: 7) {
                // ── 第一行：标题 + 勾选 ──
                HStack(alignment: .top, spacing: 6) {
                    if isEditing {
                        TextField("", text: $editingText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .transition(.opacity)
                            .focused($editFocused)
                            .onSubmit(onCommitEdit)
                            .onExitCommand(perform: onCancelEdit)
                            .onAppear { editFocused = true }
                            // 失焦即保存：点别处就当确认修改。
                            // 备忘录是轻量的，让"点一下别处"顺手存下改动，
                            // 比要求用户必须按回车更符合随手记的直觉。
                            .onChange(of: editFocused) { focused in
                                guard !focused else { return }
                                onFocusLost()
                            }
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
                            .lineLimit(UILogic.cardTitleLines)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            // 不再预留三行：标题一行就占一行的高度。
                            // 段落对齐靠要点区的固定额度，不靠这里留白——
                            // 标题长短一眼能看出来，留白反而显得空。
                            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                            // 填充圆：用 scale 从中心长出来，而不是整块淡入。
                            // 淡入在 13pt 的尺寸上看不出"生长"，
                            // 缩放才读得出"这一下被填满了"。
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 13, height: 13)
                                .scaleEffect(item.done ? 1 : 0.1)
                                .opacity(item.done ? 1 : 0)

                            // 勾：比填充晚一点出现，形成"先填满、再打勾"的两拍。
                            // 同一时刻一起出来的话，视觉上只是一团色块闪了一下，
                            // 看不出打过勾。
                            // 延迟只在勾选时给；取消勾选要立刻消失，
                            // 否则会有"点掉了但还对勾着"的一瞬。
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .scaleEffect(item.done ? 1 : 0.4)
                                .opacity(item.done ? 1 : 0)
                                .animation(
                                    item.done
                                        ? Theme.confirm.delay(0.08)
                                        : Theme.hover,
                                    value: item.done
                                )
                        }
                        .frame(width: 15, height: 15)
                        .contentShape(Circle().inset(by: -3))
                        .scaleEffect(hover.pressed ? 0.88 : 1)
                        // 外层只管填充圆的那一拍。勾有自己的动画
                        //（带延迟），挂在这里会被覆盖掉。
                        .animation(Theme.confirm, value: item.done)
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
                        onAdd: onAddPoint,
                        onFocusGained: onFocusInPoints
                    )
                } else if item.hasPoints {
                    // 有要点：固定占三行的高度。
                    //
                    // 要点条数不同会让日期行错位，而日期是扫视时
                    // 最先找的东西——为它付这块留白是值的。
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.bulletPoints.prefix(UILogic.cardPointSlots).enumerated()),
                                id: \.offset) { _, point in
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
                    .frame(
                        maxWidth: .infinity,
                        minHeight: UILogic.cardPointsBlockHeight,
                        alignment: .topLeading
                    )
                    .padding(.top, 1)
                } else {
                    // 没有要点：不留那 39pt。
                    // 这块留白没人读，纯属空格子——
                    // 空要点卡的日期行比其他卡靠上，反而更好扫。
                }

                // ── 第二行：日期 + 工期 ──
                //
                // 日期是卡片相对列表多出来的信息，用图标领起，
                // 逾期时整段转为警示色——扫视时最先看到的就是它。
                HStack(spacing: 4) {
                    Image(systemName: item.dueLabel.isOverdue ? "exclamationmark.circle.fill" : "calendar")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(dueTint)

                    Text(UILogic.dateLine(relative: item.dueLabel.text, dateKey: item.endDate))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(dueTint)

                    // 工期：始终显示，单日也可改。
                    // 悬停时展开 −/+，和列表行同一套交互。
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.inkQuaternary)

                    HStack(spacing: 3) {
                        Text("\(item.spanDays) 天")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .monospacedDigit()

                        if hover.hovering && !isEditing && !item.done {
                            HStack(spacing: 2) {
                                cardSpanButton("minus", help: "缩短一天", enabled: item.spanDays > 1) {
                                    onSetSpan(item.spanDays - 1)
                                }
                                cardSpanButton("plus", help: "延长一天", enabled: true) {
                                    onSetSpan(item.spanDays + 1)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .animation(Theme.hover, value: hover.hovering)

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
        // 基线高度，不是固定高度。
        //
        // 曾经钉死 186pt 来消除参差，代价是短标题的卡片大片留白，
        // 一屏少放一整行卡。
        //
        // 现在只保证最短摆得下（标题 1 行 + 要点 3 条），
        // 标题长了卡片自己长高。
        //
        // 不写 maxHeight：实测 LazyVGrid 会把同一行的单元拉到行高，
        // 卡片跟着撑满单元格，加不加 maxHeight: .infinity 结果一致
        //（离屏实测同排均为 128pt）。少一个不确定因素。
        .frame(minHeight: UILogic.cardBaseHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover.hovering ? Theme.surfaceRaised : Theme.surface)
                .animation(Theme.hover, value: hover.hovering)
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
        // 悬停：整张卡轻轻上浮。
        //
        // 不用阴影——这个界面的所有浮层都不带阴影，卡片也不该破例。
        // 用"上移 1.5pt + 放大 1.2%"表达浮起，配合描边加深，
        // 三层叠加比单改背景色有存在感得多。
        //
        // offset 用 move（较慢）而背景色用 hover（很快）：
        // 颜色该立刻响应，位移稍慢一点才有重量感。
        // 两个节奏错开，动作看起来就不是生硬的一起变。
        .offset(y: hover.hovering ? -1.5 : 0)
        .scaleEffect(hover.hovering ? 1.012 : 1)
        .animation(Theme.move, value: hover.hovering)
        .scaleEffect(hover.pressed ? 0.975 : 1)
        .animation(Theme.confirm, value: hover.pressed)
        .onHover { inside in
            withAnimation(Theme.hover) { hover.hovering = inside }
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
    /// 卡片的工期加减键。与列表行同一套观感（12pt 圆形小键），
    /// 只是这里空间宽裕，能直接给到 14pt。
    private func cardSpanButton(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .frame(width: 13, height: 13)
                .background(Circle().fill(Theme.surfaceHover))
                .foregroundStyle(Theme.inkSecondary)
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

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
    let onAddPoint: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onCyclePriority: () -> Void
    let onSetSpan: (Int) -> Void
    let onSetPriority: (Priority) -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    /// 编辑框失去焦点时调用（用于"点别处即保存"）
    let onFocusLost: () -> Void
    /// 焦点进入要点区时调用（取消待执行的失焦保存）
    let onFocusInPoints: () -> Void

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
                .animation(Theme.confirm, value: item.done)
            }
            .buttonStyle(.plain)
            .help(item.done ? "标记为未完成" : "标记为已完成")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !hover.pressed { withAnimation(Theme.hover) { hover.pressed = true } }
                    }
                    .onEnded { _ in
                        withAnimation(Theme.confirm) { hover.pressed = false }
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
                        // 失焦即保存，理由同列表行
                        .onChange(of: editFocused) { focused in
                            guard !focused else { return }
                            onFocusLost()
                        }
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
                        onAdd: onAddPoint,
                        onFocusGained: onFocusInPoints
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
            .animation(Theme.hover, value: hover.hovering)

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
            withAnimation(Theme.hover) { hover.hovering = inside }
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
                .animation(Theme.hover, value: hover.hovering)
            }

            Text(UILogic.dateLine(relative: item.dueLabel.text, dateKey: item.endDate))
                .font(.system(size: 9.5, weight: item.dueLabel.isOverdue && !item.done ? .semibold : .regular))
                .foregroundStyle(
                    item.dueLabel.isOverdue && !item.done
                        ? Priority.urgent.tint
                        : Theme.inkTertiary
                )

            // 工期角标：**始终显示**，单日也要显示。
            //
            // 早先只在多天时出现，理由是"避免单日事项被噪声污染"。
            // 但那等于把单日事项的工期变成只读的——
            // 今天到期的事想改成一个更宽松的期限，界面里根本没有入口。
            // 噪声可以用样式压下去，功能不能靠隐藏来实现。
            //
            // 悬停时摊开「−/+」，直接加减，不走系统菜单。
            spanBadge
                // 单日事项的工期保持低调：悬停时才完全亮起来。
                // 用透明度压噪声，而不是用隐藏来省事。
                .opacity(item.isMultiDay || hover.hovering ? 1 : 0.5)

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

    /// 工期角标：读数 + 悬停时摊开的「−/+」。
    ///
    /// **单日事项也显示**。今天到期的事想改成宽松一点的期限，
    /// 早先根本没有入口——工期 1 天时角标整个不出现，
    /// 等于把工期做成了只读。
    private var spanBadge: some View {
        HStack(spacing: 3) {
            HStack(spacing: 2) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 7.5, weight: .medium))
                Text("\(item.spanDays) 天")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(item.spanDays > 1 ? Theme.inkSecondary : Theme.inkTertiary)
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
        .animation(Theme.hover, value: hover.hovering)
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
            withAnimation(Theme.hover) { hover.hovering = inside }
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
    /// 面板即将折叠：给正在编辑的控件一个保存的机会
    static let memoPanelWillFold = Notification.Name("memo.panelWillFold")
    /// 点到编辑区之外：结束当前编辑
    static let memoClickOutsideEditing = Notification.Name("memo.clickOutsideEditing")
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
                        withAnimation(Theme.tap) { span = d }
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
            withAnimation(Theme.hover) { hover.hovering = inside }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !hover.pressed { withAnimation(Theme.hover) { hover.pressed = true } }
                }
                .onEnded { _ in
                    withAnimation(Theme.tap) { hover.pressed = false }
                }
        )
        .animation(reduceMotion ? nil : Theme.tap, value: isSelected)
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
            .animation(Theme.confirm, value: configuration.isPressed)
    }
}
