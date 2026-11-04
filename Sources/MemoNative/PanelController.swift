import Cocoa
import Carbon.HIToolbox
import SwiftUI
import Combine

/// 驱动面板展开/收起的形变进度。
///
/// 单独抽出来而不是直接改 ContentView 的属性：
/// NSHostingView 的 rootView 是值类型，改一次要整体重建，
/// 会把 @StateObject 和输入焦点一起重置——打字打到一半面板重建就丢焦点了。
/// 用一个外面持有的 ObservableObject，只推送进度变化，视图身份不变。
@MainActor
final class UnfoldState: ObservableObject {
    @Published var progress: CGFloat = 1
    @Published var anchor: UnitPoint = .center
}

/// 无边框浮动面板：可成为 key window 以便输入，同时不抢 Dock、不打断当前 App。
final class MemoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 面板失焦后的行为
enum PanelDismissBehavior: String, CaseIterable, Identifiable {
    case hide
    case demote
    case pin

    var id: String { code }

    /// 稳定的持久化标识。不要用显示文字做存储键——
    /// 一旦改文案或做本地化，旧设置就会静默失效并回退默认值。
    var code: String {
        switch self {
        case .hide: return "hide"
        case .demote: return "demote"
        case .pin: return "pin"
        }
    }

    var title: String {
        switch self {
        case .hide: return "失去焦点时收起"
        case .demote: return "退到下一层"
        case .pin: return "保持置顶"
        }
    }

    static func from(code: String?) -> PanelDismissBehavior {
        guard let code else { return .demote }
        // 兼容早期按显示文字存储的旧值
        switch code {
        case "hide", "失去焦点时收起": return .hide
        case "demote", "退到下一层": return .demote
        case "pin", "保持置顶": return .pin
        default: return .demote
        }
    }

    var detail: String {
        switch self {
        case .hide:
            return "点击其他窗口或切换 App 时面板立即收起，不遮挡工作区（推荐）"
        case .demote:
            return "点击其他窗口时沉到下一层，被别的窗口盖住但不消失"
        case .pin:
            return "始终浮在所有窗口之上，直到手动关闭"
        }
    }
}

@MainActor
final class PanelController {
    static let shared = PanelController()

    private var panel: MemoPanel?
    /// 展开/收起的形变状态，跨窗口共享
    let unfold = UnfoldState()
    private var store: MemoStore?
    private var settings: AppSettings?
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var isHiding = false
    private var shownAt: Date = .distantPast
    /// 刚显示后的保护期：系统在启动/切 App 瞬间会连发失焦通知，
    /// 这段时间内的失焦不算“用户主动点了别处”。
    private let revealGrace: TimeInterval = 1.6

    private var inRevealGrace: Bool {
        Date().timeIntervalSince(shownAt) < revealGrace
    }

    func configure(store: MemoStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 供 Esc 处理判断当前是否压着 sheet（设置页）
    var hasAttachedSheet: Bool { panel?.attachedSheet != nil }

    var behavior: PanelDismissBehavior { settings?.dismissBehavior ?? .demote }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// 悬浮球点击：展开 / 收起
    func toggleFromOrb() {
        if isVisible {
            hide(restoreFocus: false)
        } else {
            show()
        }
    }

    // MARK: 显示

    func show() {
        guard let store, let settings else { return }
        if panel == nil {
            buildPanel(store: store, settings: settings)
        }
        guard let panel else { return }

        // 记住当前前台 App，收起时好把焦点还回去
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        isHiding = false
        shownAt = Date()
        applyLevel(active: true)
        // 从悬浮球展开时，面板贴着球；否则贴光标
        if let orbFrame = FloatingOrb.shared.currentFrame, FloatingOrb.shared.isVisible {
            positionNearOrb(orbFrame)
        } else {
            positionNearCursor()
        }
        // 球"被吸进面板"：鼓起再收缩淡出，与面板展开同时起势。
        // 不能用瞬时的 setExpanded(true)——那样球一闪就没，
        // 面板凭空出现，两者之间没有视觉接力。
        FloatingOrb.shared.beginAbsorb(duration: 0.24)
        // 激活必须在 makeKey 之前完成，否则窗口拿到 key 的瞬间 App 还是非激活，
        // 系统会立刻补发一次 resignActive，把刚打开的面板又收起来。
        NSApp.activate(ignoringOtherApps: true)

        // 展开动效：从 0 起势。锚点要在窗口落位之后才知道，所以放在 position 之后。
        if let orbFrame = FloatingOrb.shared.currentFrame, FloatingOrb.shared.isVisible {
            unfold.anchor = unfoldAnchor(panel: panel, orbFrame: orbFrame)
        } else {
            unfold.anchor = .center
        }
        // 淡入只走 SwiftUI 的 opacity，不再动窗口 alphaValue。
        // 两边同时驱动同一个视觉通道会打架：实测窗口 animator() 的动画
        // 被打断后停在 0，面板就再也不可见了。
        panel.alphaValue = 1
        unfold.progress = 0

        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            // 低阻尼换来过冲：面板会稍微"顶出去"再回位，
            // 配合球的吸入动作，整体像一次有弹性的呼出。
            withAnimation(.spring(response: 0.40, dampingFraction: 0.74)) {
                self.unfold.progress = 1
            }
            // 兜底：spring 有时会在恢复了 key window / 触发重排之后
            // 停在中间值（实测卡在 0.857），面板就永远是 588×648 而不是 600×660。
            // 动画时长过后直接把终值钉死，保证最终状态是确定的。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                if self.unfold.progress != 1 {
                    self.unfold.progress = 1
                }
                // 窗口尺寸兜底：scaleEffect 会让 NSHostingView 上报缩放后的尺寸，
                // 窗口可能被系统改成 588×648。面板是固定尺寸浮窗，这里钉死回 600×660。
            }
        }
        // 激活是异步的：下一轮 runloop 再确认一次 key，避免"启动即收起"
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }

        // SwiftUI 需要一次布局后 focus 才生效，先立即发一次，再补一次
        NotificationCenter.default.post(name: .memoFocusInput, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .memoFocusInput, object: nil)
        }
        installEscapeMonitor()
    }

    private func buildPanel(store: MemoStore, settings: AppSettings) {
        let view = ContentView(store: store, settings: settings)
            .environmentObject(unfold)
        let hosting = NSHostingView(rootView: view)
        // 不让 hosting 反推窗口尺寸。
        // 默认行为下 SwiftUI 会把内容尺寸报给窗口，而展开动效用 scaleEffect
        // 缩放了内容，窗口就跟着一起缩水——实测稳定在 588×648 而不是 600×660。
        // 面板是固定尺寸的浮窗，尺寸该由自己说了算。
        hosting.sizingOptions = []
        let panel = MemoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "MEMO-PANEL"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 自己接管失焦处理，系统级自动隐藏会把 Dock 图标一起藏掉
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 关键：让窗口本身透明，玻璃材质才能采到桌面内容。
        // NSPanel 默认 isOpaque = true，会先铺一层不透明底，
        // 导致 .behindWindow 材质只能采到那块底色，玻璃效果等于没有。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting

        // 窗口本体裁圆角。
        //
        // SwiftUI 的 clipShape 对这层没用：VisualEffectView 是 AppKit view，
        // 铺满整个宿主矩形，SwiftUI 的裁切作用不到它的渲染层，
        // 实测四角仍然全不透明。
        //
        // 也不能直接给 hosting.layer 加 masksToBounds：那样会把内容按
        // contentLayoutRect 布局，顶部 32pt（标题栏高度）被判为界外裁掉，
        // 实测内容从 y=32pt 才开始，面板顶部缺一条。
        //
        // 正确位置是窗口的 frameView——它覆盖整个窗口矩形、不含标题栏偏移。
        if let frameView = panel.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = Theme.radius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
        }
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        self.panel = panel
        installObservers()
    }

    // MARK: 层级

    /// 只在「正在使用」时浮在最上层；一旦失焦就退回普通层级，
    /// 让其他窗口自然盖住它，而不是永远悬在最上面。
    private func applyLevel(active: Bool) {
        guard let panel else { return }
        switch behavior {
        case .pin:
            if panel.level.rawValue != NSWindow.Level.floating.rawValue {
                panel.level = .floating
            }
        case .demote, .hide:
            let target: NSWindow.Level = active ? .floating : .normal
            if panel.level.rawValue != target.rawValue {
                panel.level = target
            }
        }
    }

    // MARK: 收起

    /// - Parameter restoreFocus: 是否把焦点交还给唤出前的 App（用户主动收起时用）
    func hide(restoreFocus: Bool = true) {
        guard let panel, !isHiding else { return }
        isHiding = true

        // 收回动效：内容缩回球的方向，同时淡出，播完再真正隐藏窗口。
        // 顺序很重要——先 orderOut 就看不到动画了；
        // 但也不能无限等，用固定时长兜底，避免动画被系统打断后窗口卡在屏幕上。
        let orbFrame = FloatingOrb.shared.currentFrame
        if let orbFrame, FloatingOrb.shared.isVisible {
            unfold.anchor = unfoldAnchor(panel: panel, orbFrame: orbFrame)
        }

        // 同样只走 SwiftUI：progress 归 0 时内容缩回球的方向并淡到 0.15，
        // 窗口 alpha 保持 1，避免两套动画互相打断。
        // 收起也带一点过冲，但比展开快、比展开收敛（damping 更高），
        // 否则关闭动作会显得拖沓。
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            unfold.progress = 0
        }

        applyLevel(active: false)
        removeEscapeMonitor()

        // 动画播完再真正撤窗口、把球叫回来。
        // 顺序必须是"面板先缩、球后现"，反过来会看到球和面板重叠一瞬。
        let target = panel
        // 等面板收到足够小再让球长回来。
        // 原来是 0.22，比 spring 的 response(0.28) 还早——球会抢在前面冒出来，
        // 和还没缩完的面板叠一瞬。0.26 让两者交接在同一拍上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self else { return }
            target.orderOut(nil)
            self.unfold.progress = 1
            FloatingOrb.shared.endAbsorb()
            self.isHiding = false
        }

        // 注意：不要用 NSApp.hide(nil)，那会把整个 App（连同 Dock 图标）一起藏起来，
        // 导致再次呼出时窗口联动错乱。

        if restoreFocus, behavior == .hide,
           let previous = previousApp,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier,
           previous.isTerminated == false {
            previous.activate()
        }
        previousApp = nil
    }

    // MARK: 焦点与窗口联动

    private func installObservers() {
        guard observers.isEmpty, let panel else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // 只认“此刻确实是 key”这一事实，防止乱序通知把旧状态写回来
                guard panel.isKeyWindow else { return }
                self.applyLevel(active: true)
            }
        })

        // 点了别的窗口（同一 App 内）→ 立刻沉到下一层
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // 设置弹窗 / 日期选择弹层接管焦点时，不当作“用户离开”
                if self.isHiding || self.inRevealGrace { return }
                // 只认“此刻确实不是 key”这一事实
                guard !panel.isKeyWindow else { return }
                if panel.attachedSheet != nil { return }
                if self.behavior == .demote || self.behavior == .hide {
                    self.applyLevel(active: false)
                }
            }
        })

        // 切回本 App → 恢复置顶，并把焦点还给面板（否则只能点一下才响应键盘）
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if self.isHiding { return }
                self.applyLevel(active: true)
                // 只调层级，不再 makeKey/取焦点：
                // 那会再触发一轮 key 通知，造成“切走又弹回”的抖动。
                if panel.isVisible, !panel.isKeyWindow, panel.attachedSheet == nil {
                    panel.orderFront(nil)
                }
            }
        })

        // 切到别的 App → 按设置收起或下沉，绝不留在原地
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if self.isHiding || self.inRevealGrace { return }
                // App 已重新激活时不再执行下沉
                guard !NSApp.isActive else { return }
                if panel.attachedSheet != nil { return }
                // 设置窗口还开着，说明只是焦点在 App 内部转移，不是用户切走了
                if SettingsWindowController.shared.isVisible { return }
                switch self.behavior {
                case .hide:
                    self.hide(restoreFocus: false)  // 被动收起，绝不把焦点抢回来
                case .demote:
                    self.applyLevel(active: false)
                case .pin:
                    break
                }
            }
        })
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                // 有 sheet（设置页）时把 Esc 让给它，
                // 否则会连带把整个面板收起，用户就找不到设置页的出口了。
                if PanelController.shared.hasAttachedSheet {
                    return event
                }
                Task { @MainActor in PanelController.shared.hide() }
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    /// 行为设置变更后立即生效
    func behaviorDidChange() {
        applyLevel(active: panel?.isKeyWindow ?? false)
        if behavior == .hide, let panel, panel.isVisible, !panel.isKeyWindow {
            hide(restoreFocus: false)
        }
    }

    /// 面板贴着悬浮球展开：优先放在球的左侧（球默认在右边），
    /// 放不下就翻到右侧；垂直居中对齐球心，再夹取到屏幕可见区。
    /// 算出球相对面板中心的方位，转成 SwiftUI 的 UnitPoint。
    ///
    /// 面板会贴在球的一侧，所以锚点几乎总在左或右边缘。
    /// 用 0.06/0.94 而不是 0/1：紧贴边缘时缩放会露出窗口直角，
    /// 稍微往里收一点，视觉上更干净。
    private func unfoldAnchor(panel: NSWindow, orbFrame: NSRect) -> UnitPoint {
        let f = panel.frame
        guard f.width > 0, f.height > 0 else { return .center }
        let dx = orbFrame.midX - f.midX
        let dy = orbFrame.midY - f.midY
        let ax = dx < -f.width * 0.2 ? 0.06 : (dx > f.width * 0.2 ? 0.94 : 0.5)
        let ay = dy < -f.height * 0.2 ? 0.06 : (dy > f.height * 0.2 ? 0.94 : 0.5)
        return UnitPoint(x: ax, y: ay)
    }

    private func positionNearOrb(_ orbFrame: NSRect) {
        guard let panel else { return }
        let size = panel.frame.size
        let gap = OrbMetrics.gap

        let center = NSPoint(x: orbFrame.midX, y: orbFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { panel.center(); return }
        let visible = screen.visibleFrame

        // orbFrame 是窗口，比球体每边大 bleed。
        // 要让面板离**球体**保持 gap，得把这段留白补回来。
        let bleed = OrbMetrics.bleed
        var origin = NSPoint(
            x: orbFrame.minX + bleed - size.width - gap,
            y: orbFrame.midY - size.height / 2
        )
        // 左边放不下 → 放到球右边
        if origin.x < visible.minX + 8 {
            origin.x = orbFrame.maxX - bleed + gap
        }
        // 右边也放不下 → 居中兜底
        if origin.x + size.width > visible.maxX - 8 {
            origin.x = visible.midX - size.width / 2
        }

        let minY = visible.minY + 8
        let maxY = visible.maxY - size.height - 8
        origin.y = maxY >= minY ? min(max(origin.y, minY), maxY) : minY

        panel.setFrameOrigin(origin)
    }

    /// 贴光标弹出并夹取到可见区域。
    /// 多显示器（含上方/左侧副屏）时，必须严格使用「鼠标所在那块屏幕」的坐标系，
    /// 否则窗口会被搬到主屏坐标之外而看不见。
    private func positionNearCursor() {
        guard let panel else { return }
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation

        // 优先精确命中鼠标所在屏幕；没有就退回主屏
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame

        let mouseInside = NSScreen.screens.contains { NSMouseInRect(mouse, $0.frame, false) }

        var origin: NSPoint
        if mouseInside {
            // 默认放在光标下方，下方放不下就翻到上方
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
            if origin.y < visible.minY {
                origin.y = mouse.y + 16
            }
            if origin.y + size.height > visible.maxY {
                origin.y = visible.maxY - size.height
            }
        } else {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }

        // 硬夹取到这块屏幕的可见区域内（用该屏自己的坐标系，不能假设 minX=0）
        let inset: CGFloat = 8
        let minX = visible.minX + inset
        let minY = visible.minY + inset
        let maxX = visible.maxX - size.width - inset
        let maxY = visible.maxY - size.height - inset

        origin.x = maxX >= minX ? min(max(origin.x, minX), maxX) : minX
        origin.y = maxY >= minY ? min(max(origin.y, minY), maxY) : minY

        panel.setFrameOrigin(origin)
    }
}

// MARK: - 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    static let defaultHotkey = "⌥Space"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var monitor: Any?

    func start() {
        installHandler()
        reload()
    }

    func reload() {
        unregister()
        register(combo: AppSettingsStore.shared.hotkey)
    }

    private func register(combo: String) {
        let (keyCode, modifiers) = HotkeyManager.parse(combo)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D454D4F), id: 1) // 'MEMO'
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("注册全局快捷键失败：\(status)，回退到全局事件监听（需辅助功能授权）")
            installLocalMonitor()
        } else {
            NSLog("全局快捷键已注册：\(combo) keyCode=\(keyCode)")
        }
        _ = hotKeyID
    }

    private func installLocalMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // 回退方案需要辅助功能授权，仅在 Carbon 失败时启用
            if event.keyCode == 49, event.modifierFlags.contains(.option) {
                Task { @MainActor in PanelController.shared.toggle() }
            }
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in PanelController.shared.toggle() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 解析 "⌥Space" / "⌃⌥M" 之类的显示串
    static func parse(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32) {
        var modifiers: UInt32 = 0
        var rest = combo
        let option: Character = "⌥"
        let control: Character = "⌃"
        let command: Character = "⌘"
        let shift: Character = "⇧"

        while let first = rest.first, [option, control, command, shift].contains(first) {
            switch first {
            case option: modifiers |= UInt32(optionKey)
            case control: modifiers |= UInt32(controlKey)
            case command: modifiers |= UInt32(cmdKey)
            case shift: modifiers |= UInt32(shiftKey)
            default: break
            }
            rest.removeFirst()
        }

        let keyCode: UInt32
        switch rest.lowercased() {
        case "space", "空格": keyCode = UInt32(kVK_Space)
        case "return", "回车": keyCode = UInt32(kVK_Return)
        default:
            if let char = rest.lowercased().first, let code = keyCodeFor(char) {
                keyCode = code
            } else {
                keyCode = UInt32(kVK_Space)
            }
        }
        return (keyCode, modifiers)
    }

    private static func keyCodeFor(_ char: Character) -> UInt32? {
        let map: [Character: Int] = [
            "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F,
            "h": kVK_ANSI_H, "g": kVK_ANSI_G, "z": kVK_ANSI_Z, "x": kVK_ANSI_X,
            "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
            "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y,
            "t": kVK_ANSI_T, "o": kVK_ANSI_O, "u": kVK_ANSI_U, "i": kVK_ANSI_I,
            "p": kVK_ANSI_P, "l": kVK_ANSI_L, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
            "n": kVK_ANSI_N, "m": kVK_ANSI_M,
        ]
        if let code = map[char] { return UInt32(code) }
        return nil
    }
}

/// 让 HotkeyManager 在无 AppSettings 实例时也能读取当前快捷键
@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()
    var hotkey: String {
        UserDefaults.standard.string(forKey: "hotkey") ?? HotkeyManager.defaultHotkey
    }
}
