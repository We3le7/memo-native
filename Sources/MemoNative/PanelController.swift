import Cocoa
import Carbon.HIToolbox
import SwiftUI
import Combine

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
        FloatingOrb.shared.setExpanded(true)   // 球淡出，让位给面板
        // 激活必须在 makeKey 之前完成，否则窗口拿到 key 的瞬间 App 还是非激活，
        // 系统会立刻补发一次 resignActive，把刚打开的面板又收起来。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
        let hosting = NSHostingView(rootView: view)
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
        panel.contentView = hosting
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

        panel.orderOut(nil)
        applyLevel(active: false)
        removeEscapeMonitor()
        FloatingOrb.shared.setExpanded(false)  // 球回来，面板已收起

        // 注意：不要用 NSApp.hide(nil)，那会把整个 App（连同 Dock 图标）一起藏起来，
        // 导致再次呼出时窗口联动错乱。

        if restoreFocus, behavior == .hide,
           let previous = previousApp,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier,
           previous.isTerminated == false {
            previous.activate()
        }
        previousApp = nil
        isHiding = false
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
    private func positionNearOrb(_ orbFrame: NSRect) {
        guard let panel else { return }
        let size = panel.frame.size
        let gap = OrbMetrics.gap

        let center = NSPoint(x: orbFrame.midX, y: orbFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { panel.center(); return }
        let visible = screen.visibleFrame

        var origin = NSPoint(
            x: orbFrame.minX - size.width - gap,
            y: orbFrame.midY - size.height / 2
        )
        // 左边放不下 → 放到球右边
        if origin.x < visible.minX + 8 {
            origin.x = orbFrame.maxX + gap
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
        var hotKeyID = EventHotKeyID(signature: OSType(0x4D454D4F), id: 1) // 'MEMO'
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
