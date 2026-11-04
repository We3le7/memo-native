import Foundation
import UserNotifications
import AppKit

/// 每日 09:00 提醒：用系统通知中心（UNUserNotificationCenter）排定重复触发器，
/// 比脚本轮询更可靠 —— 即使 App 未运行，macOS 也会在到点时弹出通知。
@MainActor
final class ReminderCenter {
    static let shared = ReminderCenter()

    private let identifier = "memo.daily.pending"
    private let center = UNUserNotificationCenter.current()

    /// 提醒时间，默认 09:00；可用 UserDefaults 覆盖（设置面板会写这里）
    var hour: Int {
        get { UserDefaults.standard.object(forKey: "reminderHour") as? Int ?? 9 }
        set { UserDefaults.standard.set(newValue, forKey: "reminderHour"); reschedule() }
    }

    var minute: Int {
        get { UserDefaults.standard.object(forKey: "reminderMinute") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "reminderMinute"); reschedule() }
    }

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    /// 是否拿到了系统通知授权。未授权时自动降级到 osascript 通知，
    /// 这样未做代码签名的本地构建也能正常提醒。
    private(set) var isAuthorized = false

    /// 最近一次实际投递使用的通道，便于界面与记录展示
    private(set) var lastChannel = "notification-center"

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                if let error {
                    NSLog("通知授权失败：\(error.localizedDescription)")
                }
                NotifyBridge.shared.isAuthorized = granted
                NSLog("通知授权结果：\(granted)")
            }
        }
    }

    /// 每天固定时间重复；只有存在未完成事项才有意义，所以内容在触发时无法动态取，
    /// 这里使用「先排一条通用通知 + App 运行中补充精确摘要」的组合。
    func reschedule() {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "今日未完成备忘"
        content.body = "打开备忘录看看今天要做什么"
        content.sound = .default
        content.userInfo = ["deeplink": "memo://open"]

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error { NSLog("排定每日提醒失败：\(error.localizedDescription)") }
        }
    }

    /// 立即弹一条带真实摘要的通知（用于「测试提醒」和到点时的精确版本）
    @discardableResult
    func notifyNow(title: String, body: String) -> String {
        let channel = NotifyBridge.shared.deliver(title: title, body: body)
        lastChannel = channel
        return channel
    }
}
