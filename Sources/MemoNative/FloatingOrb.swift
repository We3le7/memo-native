import AppKit
import SwiftUI
import Combine

// MARK: - 悬浮球
//
// 形态：面板收起时留下一颗小球（常驻、可拖动、不抢焦点）。
// 展开：点球 → 面板从球的位置展开；再点球或按 Esc → 收回成球。
// 定位：球的位置持久化，重启后回到原处；吸附到屏幕边缘内侧。

// MARK: - 球体视图
//
// 设计目标：像 Apple 自己出的东西——
//   * 靠「材质 + 光」而不是「描边 + 色块」来塑形
//   * 高光从左上打进来，底部有一点反射光，形成球体感
//   * 状态只用一个色相表达（逾期=红），其余全部走灰阶层级
//   * 所有变化都带一点弹性，但不夸张

struct OrbView: View {
    let pending: Int
    let overdue: Int
    let unread: Int
    let hovering: Bool
    /// 玻璃强度 0…1，来自设置，影响球体的通透度与轮廓强度
    var strength: Double = GlassAppearance.defaultStrength
    /// 吸入进度 0…1，展开/收起时由外部驱动
    var collapse: CGFloat = 0
    /// 按紧急程度分档的待办数，悬停时展示
    var breakdown = PriorityBreakdown()

    /// 球上的数字始终是"未完成总数"。
    ///
    /// 原来是"有逾期就显示逾期数、否则显示待办数"，同一个位置两种含义，
    /// 用户看到 3 没法知道是 3 件待办还是 3 件逾期。逾期改由颜色和下方小字表达。
    private var badge: Int { pending }
    /// 面板已展开、球正在让位。由吸入进度推导，不再单独存一个状态位。
    private var isYielding: Bool { collapse > 0.001 }
    private var isAlerting: Bool { overdue > 0 && !isYielding }

    /// 悬停时轻微放大，按下时由外层缩回——形成"被按下去"的手感
    private var scale: CGFloat {
        // 吸入过程走 OrbMotion 的曲线：先鼓一下再收，像被吸进面板。
        if collapse > 0 {
            return OrbMotion.scale(for: collapse)
        }
        return hovering ? 1.04 : 1.0
    }

    var body: some View {
        ZStack {
            // ── 1. 球体本体 ───────────────────────────────
            // 材质打底：负责"毛玻璃"的模糊与透光
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(GlassAppearance.orbMaterialOpacity(for: strength))

            // 球面本身的底色。这一层是"实心度"的来源：
            // 强度低时它接近不透明，球是一个干净的实心球；
            // 强度高时它退到很淡，桌面就能明显透上来。
            //
            // 少了这一层，球在低强度下会溶进背景——球没有实体轮廓，
            // 只剩下一圈高光，等于看不见。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.primary.opacity(0.10),
                            Color.primary.opacity(0.035)
                        ],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: OrbMetrics.bubble * 0.72
                    )
                )

            // 实心打底：跟随强度反向变化
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .opacity(GlassAppearance.orbSolidOpacity(for: strength))

            // ── 2. 边缘：上亮下暗，制造立体轮廓 ──────────
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(GlassAppearance.orbRimOpacity(for: strength)),
                            Color.primary.opacity(0.06),
                            Color.black.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )

            // ── 3. 高光：左上角一小片弧形反光 ────────────
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: OrbMetrics.bubble * 0.46, height: OrbMetrics.bubble * 0.46)
                .offset(x: -OrbMetrics.bubble * 0.13, y: -OrbMetrics.bubble * 0.15)
                .blur(radius: 2.5)
                .blendMode(.plusLighter)
                .opacity(hovering ? 0.92 : 0.70)

            // ── 4. 逾期光晕：整颗球唯一的彩色 ────────────
            if isAlerting {
                Circle()
                    .strokeBorder(Priority.urgent.tint.opacity(0.5), lineWidth: 1.5)
                    .padding(1)

                // 外扩一圈柔和的光，像系统通知那样"呼吸"
                Circle()
                    .fill(Priority.urgent.tint.opacity(0.14))
                    .blur(radius: 7)
                    .opacity(hovering ? 1.0 : 0.7)
            }

            // ── 5. 内容 ─────────────────────────────────
            content

            // ── 6. 未读提醒：右上角小圆点，带白边 ────────
            if unread > 0 && !isYielding {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2))
                    .offset(
                        x: OrbMetrics.bubble * 0.31,
                        y: -OrbMetrics.bubble * 0.31
                    )
                    .shadow(color: .red.opacity(0.35), radius: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: OrbMetrics.bubble, height: OrbMetrics.bubble)
        .clipShape(Circle())
        .overlay(
            // 内阴影：让边缘有一点厚度，不像贴纸
            Circle()
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 2.5)
                .blur(radius: 1.5)
                .mask(Circle().strokeBorder(lineWidth: 2.5))
        )
        .scaleEffect(scale)
        // 吸入时同步淡出：光靠缩小不够，球在缩到一半时边缘会显得"硬"，
        // 叠一层透明度让消失更柔和。
        .opacity(OrbMotion.opacity(for: collapse))
        // 双层阴影：近处紧实的接触阴影 + 远处柔和的投影
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.10), radius: 2, y: 1)
        .shadow(
            color: .black.opacity(hovering ? 0.22 : 0.16),
            radius: hovering ? 11 : 9,
            y: hovering ? 5 : 4
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.70), value: hovering)
        .animation(.spring(response: 0.38, dampingFraction: 0.80), value: badge)
        // 吸入用略低的阻尼：允许一点过冲，"鼓一下再收"的弹性才明显
        // 吸入比面板的展开(0.40/0.74)略快、略弹，
        // 视觉上像球被面板"吸"走，而不是两者各演各的。
        .animation(.spring(response: 0.30, dampingFraction: 0.70), value: collapse)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if hovering && !breakdown.nonEmpty.isEmpty {
            // 悬停：摊开各紧急程度的件数。
            //
            // 球只有 46pt，四行排不下，所以做成一行四组「色点 + 数字」。
            // 只展示有内容的档位——四档全列会稀释信息，空档位没有阅读价值。
            HStack(spacing: 5) {
                ForEach(breakdown.nonEmpty, id: \.priority) { entry in
                    VStack(spacing: 1) {
                        Text("\(min(entry.count, 99))")
                            .font(.system(size: entry.count > 99 ? 7.5 : 9.5,
                                          weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(entry.priority.tint)
                        Circle()
                            .fill(entry.priority.tint)
                            .frame(width: 3.5, height: 3.5)
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        } else if badge > 0 {
            VStack(spacing: -1) {
                Text("\(min(badge, 99))")
                    .font(.system(size: badge > 99 ? 13 : (badge > 9 ? 16 : 18),
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isAlerting ? Priority.urgent.tint : Color.primary.opacity(0.88))
                    .contentTransition(.numericText())

                // 有逾期时补一行极小提示，避免只看到数字不知道含义
                if isAlerting {
                    Text("逾期")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Priority.urgent.tint.opacity(0.75))
                        .transition(.opacity)
                }
            }
            .offset(y: isAlerting ? -1 : 0)
        } else {
            // 无待办：三个点改为一条更安静的细线，像"待输入"的光标
            Capsule()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 13, height: 2.2)
        }
    }
}

// MARK: - 球窗口
//
// 关键：非激活面板（nonactivatingPanel）+ 不成为 key，
// 这样点球不会打断当前正在打字的 App。

final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingOrb {
    static let shared = FloatingOrb()

    private var panel: OrbPanel?
    private var store: MemoStore?
    private var settings: AppSettings?
    private var hosting: NSHostingView<AnyView>?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverState: OrbHover?
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint?
    private var didDrag = false

    /// 用户可关闭悬浮球
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "orbEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "orbEnabled")
            newValue ? show() : hide()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }


    /// 面板据此决定从哪儿展开
    var currentFrame: NSRect? { panel?.frame }

    func configure(store: MemoStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        hoverState?.strength = settings.glassStrength

        // 设置里拖动滑杆 → 立刻反映到球上，不必重开面板。
        // 用通知而不是让 FloatingOrb 直接持有 AppSettings 的 Published：
        // 球是单例、设置是注入的，两者生命周期不同，订阅解耦更好收尾。
        glassObserver = NotificationCenter.default.addObserver(
            forName: .memoGlassStrengthChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 通知回调不在 MainActor 上，显式切回主线程改 UI 状态
            Task { @MainActor in
                guard let self, let settings = self.settings else { return }
                self.hoverState?.strength = settings.glassStrength
            }
        }
    }

    /// 玻璃强度变化的订阅句柄，deinit 里要注销
    private var glassObserver: NSObjectProtocol?

    // MARK: 生命周期

    func show() {
        guard isEnabled else { return }
        buildIfNeeded()
        guard let panel else { return }
        panel.alphaValue = 1
        panel.orderFront(nil)
        bind()
    }

    func hide() {
        panel?.orderOut(nil)
        cancellables.removeAll()
    }

    func toggleVisibility() {
        isEnabled.toggle()
    }

    /// 面板正在从球的位置展开：球先"鼓一下再被吸进去"。
    ///
    /// 和 setExpanded 分开，是因为时序不同：
    /// 这里要让球的动作与面板的展开同步，球不能提前消失，
    /// 否则用户看到的是"球没了，然后一个面板凭空出现"。
    func beginAbsorb(duration: Double = 0.24) {
        guard let hover = hoverState, let panel else { return }

        // 只驱动 SwiftUI 侧的 collapse，不碰窗口 alpha。
        //
        // 之前用 animator() 把 alpha 动画到 0，结果收起后球再也回不来：
        // 实测 endAbsorb 里把 alpha 设回 1，0.35 秒后仍是 0——
        // 窗口级 alpha 动画被打断后会停在终值，而且不再响应后续赋值。
        // 让 SwiftUI 用 scaleEffect + opacity 表达，窗口 alpha 恒为 1。
        hover.collapse = 1
        panel.ignoresMouseEvents = true
        _ = duration
    }

    /// 面板收起：球从面板方向"长回来"。
    func endAbsorb() {
        guard let hover = hoverState, let panel else { return }
        // 复位到常态。窗口 alpha 保持 1，形变全在 SwiftUI 侧，
        // 这样不会出现"球被设成透明后再也回不来"的问题。
        hover.collapse = 0
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        let target = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)
        if panel.frame.size != target {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: target), display: false)
        }
        panel.ignoresMouseEvents = false
        bind()
    }

    private func buildIfNeeded() {
        // store 只在宿主视图里通过环境注入，这里只需确认已配置
        guard panel == nil, store != nil else { return }
        let hover = OrbHover()
        // 建视图时就把当前强度带进去。
        // configure() 早于 buildIfNeeded()，那时 hoverState 还是 nil，
        // 只靠 configure 里赋值会让首帧用默认强度——表现为"改了设置但球没变"。
        hover.strength = settings?.glassStrength ?? GlassAppearance.defaultStrength
        hoverState = hover

        let root = AnyView(
            ZStack {
                OrbHitArea(
                    hover: hover,
                    onTap: { PanelController.shared.toggleFromOrb() },
                    onDragBegan: { [weak self] in self?.beginDrag() },
                    onDragMoved: { [weak self] delta in self?.moveDrag(delta) },
                    onDragEnded: { [weak self] in self?.endDrag() }
                )
            }
            .frame(width: OrbMetrics.size, height: OrbMetrics.size)
            .fixedSize()
        )

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: OrbMetrics.size, height: OrbMetrics.size)
        // 关键：不让 SwiftUI 的理想尺寸反向撑大窗口
        hosting.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hosting.setContentHuggingPriority(.defaultLow, for: .vertical)

        let panel = OrbPanel(
            contentRect: NSRect(x: 0, y: 0, width: OrbMetrics.size, height: OrbMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // 阴影由 SwiftUI 画，避免双重阴影
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.contentView = hosting
        // 明确固定窗口尺寸，防止被内容撑开
        panel.setContentSize(NSSize(width: OrbMetrics.size, height: OrbMetrics.size))
        panel.minSize = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)
        panel.maxSize = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)

        panel.title = "ORB-\(OrbMetrics.size)"
        panel.setFrame(NSRect(x: 0, y: 0, width: OrbMetrics.size, height: OrbMetrics.size), display: false)
        self.panel = panel
        self.hosting = hosting
        restorePosition()
        refreshAppearance()
    }

    private func bind() {
        guard cancellables.isEmpty, let store else { return }
        // 数据变化 → 球的数字跟着变
        store.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshAppearance() }
            }
            .store(in: &cancellables)
    }

    private func refreshAppearance() {
        guard let store, let hoverState else { return }
        let stats = store.stats
        hoverState.pending = stats.pending
        hoverState.overdue = stats.overdue
        hoverState.unread = store.unreadReminderCount
        hoverState.breakdown = PriorityBreakdown.of(store.items)
    }

    // MARK: 位置

    private func restorePosition() {
        guard let panel else { return }
        let defaults = UserDefaults.standard
        let size = panel.frame.size

        // NSScreen.main 会跟随「当前有键盘焦点的那块屏」，在副屏上工作时
        // 它会指向副屏，导致默认位置算到主屏之外。这里固定用主屏（screens[0]）。
        let primary = NSScreen.screens.first ?? NSScreen.main

        if defaults.object(forKey: "orbX") != nil, defaults.object(forKey: "orbY") != nil {
            let stored = NSRect(
                x: defaults.double(forKey: "orbX"),
                y: defaults.double(forKey: "orbY"),
                width: size.width,
                height: size.height
            )
            // 只有当整颗球都完整落在某块屏的可见区内才沿用旧坐标
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(stored) }) {
                panel.setFrameOrigin(stored.origin)
                return
            }
        }

        // 默认：主屏右上角内侧
        guard let visible = primary?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - OrbMetrics.snapInset,
            y: visible.maxY - size.height - OrbMetrics.snapInset - 40
        ))
    }

    private func savePosition() {
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: "orbX")
        UserDefaults.standard.set(Double(origin.y), forKey: "orbY")
    }

    // MARK: 拖动

    private func beginDrag() {
        guard let panel else { return }
        dragStart = NSEvent.mouseLocation
        dragOrigin = panel.frame.origin
        didDrag = false
    }

    private func moveDrag(_ delta: NSPoint) {
        guard let panel, let dragOrigin, let dragStart else { return }
        let dx = delta.x - dragStart.x
        let dy = delta.y - dragStart.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))
    }

    private func endDrag() {
        guard let panel else { return }
        defer {
            dragStart = nil
            dragOrigin = nil
            didDrag = false
        }
        // 不再吸附边缘：拖到哪就停在哪，只保证整颗球留在屏幕可见区内。
        // （原来的 snapToEdge 会把 x 强制推到最左/最右，无法自由摆放。）
        let clamped = OrbLayout.clamp(
            origin: panel.frame.origin,
            size: panel.frame.size,
            screens: NSScreen.screens.map { $0.visibleFrame }
        )
        if clamped != panel.frame.origin {
            panel.setFrameOrigin(clamped)
        }
        savePosition()
    }
}

// MARK: - 球的交互层
//
// SwiftUI 的 onTapGesture + DragGesture 在非激活面板里同时用会互相吞事件，
// 这里落到 AppKit 的 mouseDown/mouseDragged/mouseUp，判定更可靠。

struct OrbHitArea: NSViewRepresentable {
    let hover: OrbHover
    let onTap: () -> Void
    let onDragBegan: () -> Void
    let onDragMoved: (NSPoint) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> OrbContainerView {
        let view = OrbContainerView()
        view.hover = hover
        view.onTap = onTap
        view.onDragBegan = onDragBegan
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: OrbContainerView, context: Context) {
        nsView.onTap = onTap
        nsView.onDragBegan = onDragBegan
        nsView.onDragMoved = onDragMoved
        nsView.onDragEnded = onDragEnded
    }
}

@MainActor
final class OrbContainerView: NSView {
    var hover: OrbHover?
    var onTap: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var pressedAt: NSPoint?
    private var pressOrigin: NSPoint?
    private var moved = false
    private var hosting: NSHostingView<OrbContent>?

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hosting == nil, let hover else { return }
        let view = NSHostingView(rootView: OrbContent(hover: hover))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.widthAnchor.constraint(equalTo: widthAnchor),
            view.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        hosting = view
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hover?.isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hover?.isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = NSEvent.mouseLocation
        pressOrigin = window?.frame.origin
        moved = false
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        if let pressedAt, hypot(mouse.x - pressedAt.x, mouse.y - pressedAt.y) > 2 {
            moved = true
        }
        onDragMoved?(mouse)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAt = nil
            pressOrigin = nil
        }
        onDragEnded?()
        if !moved {
            onTap?()
        }
        moved = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 球的可观察状态

@MainActor
final class OrbHover: ObservableObject {
    @Published var isHovering = false
    @Published var pending = 0
    @Published var overdue = 0
    @Published var unread = 0
    /// 按紧急程度分档的待办数，悬停时展示
    @Published var breakdown = PriorityBreakdown()
    /// 玻璃强度，跟随设置
    @Published var strength: Double = GlassAppearance.defaultStrength
    /// 展开时的"吸入"进度：0 = 常态，1 = 完全收进面板。
    ///
    /// 单独一个量而不是复用 expanded：expanded 只是开关，
    /// 驱不出"先鼓一下再收回去"这种带过冲的曲线。
    @Published var collapse: CGFloat = 0
}

/// 只订阅状态、不持有点击手势（点击由 AppKit 层处理）
struct OrbContent: View {
    @ObservedObject var hover: OrbHover

    var body: some View {
        OrbView(
            pending: hover.pending,
            overdue: hover.overdue,
            unread: hover.unread,
            hovering: hover.isHovering,
            strength: hover.strength,
            collapse: hover.collapse,
            breakdown: hover.breakdown
        )
        .frame(width: OrbMetrics.size, height: OrbMetrics.size)
        .fixedSize()
        .allowsHitTesting(false)
    }
}
