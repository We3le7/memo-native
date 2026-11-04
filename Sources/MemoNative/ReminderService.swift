import Foundation
import AppKit

/// 每天到点检查未完成事项，并生成「带真实摘要」的通知。
///
/// 设计取舍：
///  * UNCalendarNotificationTrigger 保证「App 没运行也会弹」——但通知文案是排定时固定的；
///  * 因此排定一条通用提醒兜底，同时 App 运行时由本服务在到点再发一条精确摘要
///    （两条使用不同的通知标识，后者会合并展示）。
@MainActor
final class ReminderService {
    static let shared = ReminderService()

    private var timer: Timer?
    private var lastFiredDay: String?

    func start(store: MemoStore, settings: AppSettings) {
        ReminderCenter.shared.reschedule()
        scheduleNextTick(store: store, settings: settings)
        observeWakeAndClockChanges(store: store, settings: settings)
    }

    /// 睡眠唤醒 / 改系统时间后，Timer 可能已漂移：重新对齐并补发错过的今日提醒
    private func observeWakeAndClockChanges(store: MemoStore, settings: AppSettings) {
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    await ReminderService.shared.catchUpIfMissed(store: store, settings: settings)
                    ReminderService.shared.scheduleNextTick(store: store, settings: settings)
                }
            }
        }
    }

    /// 若今天已过提醒时间、且今天还没提醒过，则补发一次
    func catchUpIfMissed(store: MemoStore, settings: AppSettings) async {
        let today = DateKey.today
        guard lastFiredDay != today else { return }
        guard store.reminders.last?.day != today else { return }
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutesNow = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let target = settings.reminderHour * 60 + settings.reminderMinute
        guard minutesNow >= target else { return }
        guard !store.pending.isEmpty else { return }
        lastFiredDay = today
        await fire(store: store, force: false)
    }

    private func scheduleNextTick(store: MemoStore, settings: AppSettings) {
        timer?.invalidate()
        let now = Date()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = settings.reminderHour
        components.minute = settings.reminderMinute
        components.second = 0
        guard var target = calendar.date(from: components) else { return }
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target.addingTimeInterval(86400)
        }

        let interval = target.timeIntervalSince(now)
        let timer = Timer(timeInterval: max(interval, 1), repeats: false) { _ in
            Task { @MainActor in
                await ReminderService.shared.fireIfDue(store: store, settings: settings)
                ReminderService.shared.scheduleNextTick(store: store, settings: settings)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 到点触发；同一自然日只触发一次
    func fireIfDue(store: MemoStore, settings: AppSettings) async {
        let today = DateKey.today
        if lastFiredDay == today { return }
        lastFiredDay = today
        await fire(store: store, force: false)
    }

    @discardableResult
    func fireNow(store: MemoStore, force: Bool) async -> ReminderRecord {
        await fire(store: store, force: force)
    }

    @discardableResult
    private func fire(store: MemoStore, force: Bool) async -> ReminderRecord {
        let pending = store.pending
        let body = Digest.body(for: pending)
        let title = "今日未完成备忘"

        let channel = ReminderCenter.shared.notifyNow(title: title, body: body)

        let record = ReminderRecord(
            id: Memo.newID(),
            at: ISO8601.string(from: Date()),
            day: DateKey.today,
            title: title,
            body: body.isEmpty ? "今天没有未完成事项 🎉" : body,
            count: pending.count,
            read: false,
            channel: channel
        )
        store.recordReminder(record)
        return record
    }
}
