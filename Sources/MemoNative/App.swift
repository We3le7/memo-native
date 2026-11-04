import AppKit
import SwiftUI
import UserNotifications

/// 入口：菜单栏 App，不使用 SwiftUI App 生命周期（避免额外的 Scene 管理），
/// 直接 NSApplication + AppDelegate，面板由 PanelController 自绘。
@main
enum MemoNativeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .regular：出现在 Dock 与启动台，图标可见；菜单栏图标照样保留
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = MemoStore()
    let settings = AppSettings()
    private var statusItem: NSStatusItem?
    private var panelObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // 显示 Dock 图标（图标在这里可见）

        UNUserNotificationCenter.current().delegate = self
        ReminderCenter.shared.requestAuthorization()
        ReminderCenter.shared.reschedule()

        PanelController.shared.configure(store: store, settings: settings)
        FloatingOrb.shared.configure(store: store, settings: settings)
        SettingsWindowController.shared.configure(store: store, settings: settings)
        HotkeyManager.shared.start()
        ReminderService.shared.start(store: store, settings: settings)

        applyMenuBarVisibility()   // 尊重上次关掉菜单栏的选择
        NotificationCenter.default.addObserver(
            forName: .memoMenuBarVisibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyMenuBarVisibility() }
        }
        listenForDeepLinks()

        // 每次启动都显示面板：这是「随手召唤」的主入口，不该依赖历史标记
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            FloatingOrb.shared.show()          // 先让球出现，面板才有锚点
            PanelController.shared.show()
        }
    }

    /// URL Scheme：memo://toggle / memo://add?title=xxx&priority=high&due=2026-11-06
    /// 这样快捷指令、Raycast、Alfred、终端都能随手召唤。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "memo" else { continue }
            let action = url.host ?? url.path.replacingOccurrences(of: "/", with: "")
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )

            switch action {
            case "add":
                if let title = query["title"], !title.isEmpty {
                    let priority = Priority(rawValue: query["priority"] ?? "") ?? .normal
                    store.add(title: title, priority: priority, dueDate: query["due"] ?? DateKey.today)
                    PanelController.shared.show()
                } else {
                    PanelController.shared.show()
                }
            case "delete":
                if let title = query["title"] {
                    for item in store.items where item.title.contains(title) {
                        store.delete(item.id)
                    }
                }
            case "settings":
                SettingsWindowController.shared.show()
            case "collapse":
                PanelController.shared.hide(restoreFocus: false)
            case "orb":
                FloatingOrb.shared.show()
            case "simspace":
                // 诊断：模拟一次桌面切换，验证状态收敛
                PanelController.shared.simulateSpaceChangeForTesting()
            case "remind":
                Task { @MainActor in _ = await ReminderService.shared.fireNow(store: store, force: true) }
            default:
                PanelController.shared.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelController.shared.show()
        return true
    }

    // MARK: 菜单栏

    /// 「在菜单栏显示图标」开关生效：关掉就真的从菜单栏移除
    func applyMenuBarVisibility() {
        if settings.showInMenuBar {
            if statusItem == nil { setupStatusItem() }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = item.button
        button?.image = Self.menuBarIcon()
        button?.image?.isTemplate = false   // 保留彩色，让优先级色点在菜单栏也可见
        button?.action = #selector(statusItemClicked)
        button?.target = self
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        observeStoreForBadge()
    }

    /// 从 App 图标生成菜单栏小图（18pt，对应 Retina 的 36px）
    static func menuBarIcon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        // 优先用包内图标文件，避免 applicationIconImage 尚未就绪
        let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
        let source = bundled ?? NSApplication.shared.applicationIconImage
        image.lockFocus()
        if let source {
            source.draw(
                in: NSRect(x: 0, y: 0, width: side, height: side),
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func observeStoreForBadge() {
        // 用通知粗略刷新角标：数据变更不频繁，2 秒轮询足够且实现简单
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBadge() }
        }
        refreshBadge()
    }

    private func refreshBadge() {
        let pending = store.stats.pending
        guard let button = statusItem?.button else { return }
        if pending > 0 {
            button.title = " \(pending)"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            PanelController.shared.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let pending = store.pending
        menu.addItem(withTitle: "\(DateKey.today) · \(pending.count) 项未完成", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        for item in pending.prefix(8) {
            let entry = NSMenuItem(
                title: "\(item.priority.icon) \(item.title)（\(item.dueLabel.text)）",
                action: #selector(completeFromMenu(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = item.id
            menu.addItem(entry)
        }
        if !pending.isEmpty { menu.addItem(.separator()) }

        menu.addItem(withTitle: "打开面板  \(settings.hotkey)", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "测试提醒", action: #selector(testReminder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // 下次左键仍走面板
    }

    @objc private func completeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.toggleDone(id)
        refreshBadge()
    }

    @objc private func openPanel() { PanelController.shared.show() }

    @objc private func testReminder() {
        Task { @MainActor in _ = await ReminderService.shared.fireNow(store: store, force: true) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 通知点击

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            PanelController.shared.show()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private func listenForDeepLinks() {
        panelObserver = NotificationCenter.default.addObserver(
            forName: .memoOpenPanel, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PanelController.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    /// 自检模式（--self-check）：把启动后的真实状态写到文件，便于自动化验证。
    /// 只在本机调试使用，不影响正常启动。
    private func runSelfCheckIfRequested() {
        guard CommandLine.arguments.contains("--self-check") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            NSLog("self-check: before explicit show, panelVisible=\(PanelController.shared.isVisible)")
            PanelController.shared.show()
            try? await Task.sleep(nanoseconds: 800_000_000)
            let beforeCount = store.reminders.count
            _ = await ReminderService.shared.fireNow(store: store, force: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSLog("self-check: reminders \(beforeCount) -> \(store.reminders.count), channel=\(store.reminders.last?.channel ?? "nil"), authorized=\(NotifyBridge.shared.isAuthorized)")
            NSLog("self-check: after explicit show, panelVisible=\(PanelController.shared.isVisible), key=\(String(describing: NSApp.keyWindow))")
            let panelVisible = PanelController.shared.isVisible
            let keyWindowClass = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
            let keyWindowSize = NSApp.keyWindow.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
            let contentView = NSApp.keyWindow?.contentView.map { String(describing: type(of: $0)) } ?? "nil"

            let report: [String: Any] = [
                "panelVisible": panelVisible,
                "keyWindowClass": keyWindowClass,
                "keyWindowSize": keyWindowSize,
                "contentView": contentView,
                "items": store.items.count,
                "pending": store.pending.count,
                "dataFile": store.fileURL.path,
                "dataExists": FileManager.default.fileExists(atPath: store.fileURL.path),
                "reminderTime": settings.reminderTimeText,
                "lastError": store.lastError ?? "",
                "statusItemPresent": statusItem != nil,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let out = URL(fileURLWithPath: "/tmp/memo-selfcheck.json")
                try? data.write(to: out)
                print("self-check written to \(out.path)")
            }
            // 自检模式下把窗口层级信息也打出来
            for window in NSApp.windows {
                print("window: \(type(of: window)) visible=\(window.isVisible) frame=\(window.frame)")
            }
            NSApp.terminate(nil)
        }
    }
}
