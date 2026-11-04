import AppKit
import SwiftUI

/// 独立的设置窗口。
///
/// 为什么不用 SwiftUI 的 `.sheet`：
/// 面板是 `.nonactivatingPanel`，它的 sheet 会继承同样的 styleMask，
/// 结果就是「窗口画出来了，但永远成不了 key window」——
/// 按钮点不动、Esc 不响应、输入框也收不到键盘。
/// 用一个普通的 NSPanel（可成为 key）承载设置页，才能正常交互。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var store: MemoStore?
    private var settings: AppSettings?
    private var hasPositioned = false

    func configure(store: MemoStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let store, let settings else { return }

        if window == nil {
            build(store: store, settings: settings)
        }
        guard let window else { return }

        // 首次打开定位一次；之后保留用户拖动过的位置
        if !hasPositioned {
            // 定位前确保尺寸已经生效，否则可能按旧 frame 算出屏幕外的位置
            window.setContentSize(NSSize(width: 430, height: 596))
            positionWindow(window)
            hasPositioned = true
        }
        // 自己的 App 必须先激活，否则窗口画出来也拿不到键盘（按钮、Esc 全失效）。
        // 之前依赖面板 show() 顺带激活 App，去掉那一步后这里就必须自己保证。
        let wasActive = NSApp.isActive
        if wasActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // 激活是异步的：下一轮 runloop 再抢一次 key，避免首次打开抢不到
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func close() {
        window?.close()
    }

    private func build(store: MemoStore, settings: AppSettings) {
        let root = SettingsView(
            store: store,
            settings: settings,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 596),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 与面板同一套处理：窗口必须透明，behindWindow 材质才能采到桌面。
        // 默认 isOpaque = true 会先铺一层不透明底，玻璃等于不存在。
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = hosting

        // 窗口本体裁圆角。SwiftUI 的 clipShape 裁不动 VisualEffectView
        //（它是 AppKit view，铺满宿主矩形），必须给 frameView 加 layer 遮罩。
        if let frameView = hosting.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = Theme.radius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
        }

        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Esc 关闭
        window.isRestorable = false

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        window.setContentSize(NSSize(width: 430, height: 596))
        self.window = window
    }

    private func positionWindow(_ window: NSWindow) {
        let size = window.frame.size
        // 面板在屏幕中央偏左，设置窗放右侧；空间不够就居中
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { window.center(); return }

        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        // 夹取到可见区
        let inset: CGFloat = 12
        origin.x = max(visible.minX + inset, min(origin.x, visible.maxX - size.width - inset))
        origin.y = max(visible.minY + inset, min(origin.y, visible.maxY - size.height - inset))
        window.setFrameOrigin(origin)
    }
}
