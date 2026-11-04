import AppKit

/// 监听桌面（Space）切换。
///
/// `NSWorkspace.activeSpaceDidChangeNotification` 没有 object，
/// 且可能在任意线程发出，所以统一切回主线程再回调。
///
/// 单独抽一个薄封装而不是直接把观察者塞进 PanelController：
/// 这个通知的回调时机不稳定（切 Space 的动画过程中会连发多次），
/// 集中在一处便于去重和以后加防抖。
@MainActor
final class WorkspaceWatcher {
    static let shared = WorkspaceWatcher()

    private var observer: NSObjectProtocol?
    private var handlers: [UUID: () -> Void] = [:]

    private init() {}

    /// 注册回调。返回的令牌可以直接放进 PanelController 的 observers 数组，
    /// 但那边的数组是 [NSObjectProtocol]，所以这里返回一个可注销的盒子。
    @discardableResult
    func onSpaceChange(_ handler: @escaping () -> Void) -> SpaceSubscription {
        let token = UUID()
        handlers[token] = handler
        ensureObserving()
        return SpaceSubscription(watcher: self, token: token)
    }

    fileprivate func remove(_ token: UUID) {
        handlers.removeValue(forKey: token)
        if handlers.isEmpty, let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func ensureObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 复制一份再遍历：回调里可能注销自己，直接遍历会撞上字典修改
                let snapshot = Array(self.handlers.values)
                for handler in snapshot { handler() }
            }
        }
    }
}


/// 注销句柄。伪装成 NSObjectProtocol，好塞进既有的 observers 数组统一管理。
final class SpaceSubscription: NSObject {
    private weak var watcher: WorkspaceWatcher?
    private let token: UUID

    init(watcher: WorkspaceWatcher, token: UUID) {
        self.watcher = watcher
        self.token = token
    }

    deinit {
        let w = watcher
        let t = token
        Task { @MainActor in w?.remove(t) }
    }
}
