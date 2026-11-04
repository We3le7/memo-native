import Foundation
import Combine

/// 设置页打开时的字段快照，供「取消」回滚。
///
/// 只用 String/Int/Bool 存值，不直接持有 `PanelDismissBehavior` 这类 UI 层类型，
/// 这样它可以被单元测试单独链接，不必把整个 UI 拖进测试目标。
@MainActor
final class SettingsSnapshot: ObservableObject {
    private var hour = 9
    private var minute = 0
    private var behaviorCode = "demote"
    private var orb = true
    private var menuBar = true

    func capture(from settings: AppSettings) {
        hour = settings.reminderHour
        minute = settings.reminderMinute
        behaviorCode = settings.dismissBehavior.code
        orb = settings.showFloatingOrb
        menuBar = settings.showInMenuBar
    }

    func apply(to settings: AppSettings) {
        if settings.reminderHour != hour { settings.reminderHour = hour }
        if settings.reminderMinute != minute { settings.reminderMinute = minute }
        let restored = PanelDismissBehavior.from(code: behaviorCode)
        if settings.dismissBehavior != restored { settings.dismissBehavior = restored }
        if settings.showFloatingOrb != orb { settings.showFloatingOrb = orb }
        if settings.showInMenuBar != menuBar { settings.showInMenuBar = menuBar }
    }

    // 便于测试断言
    var capturedHour: Int { hour }
    var capturedOrb: Bool { orb }
}
