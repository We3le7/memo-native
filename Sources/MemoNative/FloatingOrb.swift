import AppKit
import SwiftUI
import Combine

// MARK: - 悬浮球
//
// 形态：面板收起时留下一颗小球（常驻、可拖动、不抢焦点）。
// 展开：点球 → 面板从球的位置展开；再点球或按 Esc → 收回成球。
// 定位：球的位置持久化，重启后回到原处；吸附到屏幕边缘内侧。

// MARK: - 球体视图

struct OrbView: View {
    let pending: Int
    let overdue: Int
    let unread: Int
    let expanded: Bool
    let hovering: Bool

    private var badge: Int { overdue > 0 ? overdue : pending }

    var body: some View {
        ZStack {
            // 底：材质 + 极淡描边，保持与面板一致的克制
            Circle()
                .fill(.regularMaterial)

            Circle()
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)

            // 有逾期时外圈浮现一圈红晕，是整颗球上唯一的高饱和色
            if overdue > 0 && !expanded {
                Circle()
                    .strokeBorder(Priority.urgent.tint.opacity(0.55), lineWidth: 1.5)
                    .padding(1.5)
            }

            // 内容：数字为主，没有数字时显示极简的点阵
            if badge > 0 {
                Text("\(min(badge, 99))")
                    .font(.system(size: badge > 9 ? 15 : 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(overdue > 0 ? Priority.urgent.tint : Color.primary)
                    .contentTransition(.numericText())
            } else {
                // 无待办：安静的三点，表示"这里还有东西"
                HStack(spacing: 3.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.primary.opacity(index == 0 ? 0.55 : 0.28))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
            }

            // 未读提醒：右上角一个小点
            if unread > 0 {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(x: 16, y: -16)
                    .transition(.scale.combined(with: .opacity))
            }

            // 展开态的指示：底部一条极短横线
            if expanded {
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 12, height: 2)
                    .offset(y: 16)
                    .transition(.opacity)
            }
        }
        .frame(width: OrbMetrics.bubble, height: OrbMetrics.bubble)
        .scaleEffect(hovering ? 1.05 : 1.0)
        .shadow(
            color: .black.opacity(hovering ? 0.22 : 0.14),
            radius: hovering ? 10 : 7,
            y: hovering ? 4 : 3
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: expanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: badge)
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
    }

    // MARK: 生命周期

    func show() {
        guard isEnabled else { return }
        buildIfNeeded()
        guard let panel else { return }
        panel.alphaValue = hoverState?.expanded == true ? 0 : 1
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

    /// 展开/折叠的唯一入口。
    ///
    /// 两者互斥：面板展开时球淡出，面板收起时球淡入。
    /// 这既是「折叠」的语义，也避开了一个层级问题——
    /// 球常驻 floating，而面板失焦会降到 normal，球会永远压在面板上。
    func setExpanded(_ expanded: Bool) {
        hoverState?.expanded = expanded
        expanded ? fadeOut() : fadeIn()
    }

    private func fadeIn() {
        // 用户关掉悬浮球后，收起面板不应再把它叫回来
        guard isEnabled else {
            panel?.alphaValue = 0
            panel?.ignoresMouseEvents = true
            return
        }
        buildIfNeeded()
        guard let panel else { return }

        // 回到「可见 + 不透明 + 可点击」这个确定状态。
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        // 尺寸可能被系统重置（orderOut 后 orderFront 会变 0x0），这里兜底修回
        let target = NSSize(width: OrbMetrics.size, height: OrbMetrics.size)
        if panel.frame.size != target {
            let origin = panel.frame.origin
            panel.setFrame(NSRect(origin: origin, size: target), display: false)
        }
        panel.ignoresMouseEvents = false
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        panel.alphaValue = 1
        bind()
    }

    private func fadeOut() {
        guard let panel else { return }
        // 只置透明、不移出屏幕。
        // orderOut 之后再 orderFront 会让窗口丢掉尺寸（变 0x0），
        // 球下次就"消失"了；alpha=0 的窗口不接受点击，效果等价且安全。
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    private func buildIfNeeded() {
        guard panel == nil, let store else { return }
        let hover = OrbHover()
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
        hoverState.pending = store.stats.pending
        hoverState.overdue = store.stats.overdue
        hoverState.unread = store.unreadReminderCount
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
        // 拖动结束后吸附到最近的屏幕边缘，避免悬在奇怪的位置
        snapToEdge(panel)
        savePosition()
    }

    private func snapToEdge(_ panel: NSPanel) {
        let size = panel.frame.size
        var origin = panel.frame.origin
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        let inset = OrbMetrics.snapInset
        // 水平：靠左或靠右
        let distLeft = abs(origin.x - visible.minX)
        let distRight = abs(visible.maxX - (origin.x + size.width))
        if distLeft < distRight {
            origin.x = visible.minX + inset
        } else {
            origin.x = visible.maxX - size.width - inset
        }

        // 垂直：夹取在可见区内，留出 Dock 与菜单栏
        let minY = visible.minY + inset
        let maxY = visible.maxY - size.height - inset
        origin.y = maxY >= minY ? min(origin.y, maxY) : minY
        origin.y = max(minY, origin.y)

        panel.setFrameOrigin(origin)
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
    @Published var expanded = false {
        didSet { if oldValue != expanded { sync() } }
    }
    @Published var pending = 0
    @Published var overdue = 0
    @Published var unread = 0

    private func sync() {}
}

/// 只订阅状态、不持有点击手势（点击由 AppKit 层处理）
struct OrbContent: View {
    @ObservedObject var hover: OrbHover

    var body: some View {
        OrbView(
            pending: hover.pending,
            overdue: hover.overdue,
            unread: hover.unread,
            expanded: hover.expanded,
            hovering: hover.isHovering
        )
        .frame(width: OrbMetrics.size, height: OrbMetrics.size)
        .fixedSize()
        .allowsHitTesting(false)
    }
}
