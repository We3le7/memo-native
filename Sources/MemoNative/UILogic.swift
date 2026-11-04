import Foundation

// MARK: - 可测试的纯逻辑
//
// 这些函数不依赖 AppKit/SwiftUI，单独编译即可跑单元测试，
// 便于在没有 Xcode 的环境里验证时间解析、日期换算等易错点。

enum UILogic {

    /// 顶部时钟文本：时:分:秒，24 小时制
    /// 标题下的副标题：星期 + 月日，例如「星期二 · 11月4日」
    static func headerDateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "EEEE · M月d日"
        return f.string(from: date)
    }

    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// 解析 createdAt 这类 ISO8601 字符串，返回「时:分」。
    /// 兼容带/不带毫秒两种写法；解析失败返回 nil（不显示，而不是崩或显示垃圾）。
    static func createdTimeText(_ iso: String, timeZone: TimeZone = .current) -> String? {
        guard let date = parseISO(iso) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.timeZone = timeZone
        out.dateFormat = "HH:mm"
        return out.string(from: date)
    }

    static func parseISO(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// 把日期偏移换算成 yyyy-MM-dd
    static func dueKey(offsetDays: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
        let target = calendar.date(byAdding: .day, value: offsetDays, to: now) ?? now
        return DateKey.string(from: target)
    }

    /// 相对今天的自然语言描述
    static func relativeDayText(for key: String, today: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = DateKey.date(from: key) else { return key }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: today),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case _ where days < 0: return "已逾期 \(abs(days)) 天"
        default: return "\(days) 天后"
        }
    }

    /// 提醒时间规范化：任意输入夹取到合法范围，避免 99 点之类的脏值写进配置
    static func clampTime(hour: Int, minute: Int) -> (hour: Int, minute: Int) {
        (min(max(hour, 0), 23), min(max(minute, 0), 59))
    }

    /// 解析时间输入框里的文本：只取数字、最多两位、夹取到范围
    static func parseTimeField(_ raw: String, range: ClosedRange<Int>, fallback: Int) -> Int {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return fallback }
        let clipped = String(digits.prefix(2))
        guard let number = Int(clipped) else { return fallback }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    static func formatTimeUnit(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}

// MARK: - 悬浮球的分档统计

/// 按紧急程度统计未完成事项。
///
/// 单独抽出来而不是塞进 MemoStore.stats，是为了能测：
/// 分档口径一旦错了（比如把已完成也算进去），
/// 球的数字看着正常，实际是在骗人。
struct PriorityBreakdown: Equatable {
    var urgent = 0
    var high = 0
    var normal = 0
    var low = 0

    var total: Int { urgent + high + normal + low }

    /// 有内容的档位，按紧急程度从高到低。
    /// 悬停时只展示这些——四档全列出来，空档位会稀释信息。
    var nonEmpty: [(priority: Priority, count: Int)] {
        var out: [(Priority, Int)] = []
        if urgent > 0 { out.append((.urgent, urgent)) }
        if high > 0 { out.append((.high, high)) }
        if normal > 0 { out.append((.normal, normal)) }
        if low > 0 { out.append((.low, low)) }
        return out
    }

    static func of(_ items: [Memo]) -> PriorityBreakdown {
        var b = PriorityBreakdown()
        for item in items where !item.done {
            switch item.priority {
            case .urgent: b.urgent += 1
            case .high: b.high += 1
            case .normal: b.normal += 1
            case .low: b.low += 1
            }
        }
        return b
    }
}

// MARK: - 桌面切换时的状态收敛

extension UILogic {
    /// 切换桌面时，要不要同步一次球的显隐。
    ///
    /// 三个窗口都带 .canJoinAllSpaces，会跟着用户出现在每个桌面，
    /// 面板跨桌面保持展开是正确的行为——召唤出来的东西不该因为切个桌面就消失。
    ///
    /// 需要校正的只有球的显隐：它由 show()/hide() 推进，
    /// Space 切换不经过那两个方法，图层可能停在半透明，和面板对不上。
    ///
    /// - Parameters:
    ///   - isPanelVisible: 面板窗口当前是否可见
    ///   - isHiding: 是否正在播收起动画
    static func shouldSyncOrbOnSpaceChange(
        isPanelVisible: Bool,
        isHiding: Bool,
        orbEnabled: Bool
    ) -> Bool {
        // 球被关掉时，一切与它相关的行为都该停手
        guard orbEnabled else { return false }
        // 正在播动画时不要去改，会和动画抢同一个属性
        guard !isHiding else { return false }
        // 面板是否可见都值得校正一次：可见→球该藏，不可见→球该现
        _ = isPanelVisible
        return true
    }
}

extension UILogic {
    /// 面板收起时，要不要让球浮现。
    ///
    /// 这里曾经无条件浮现：用户在设置里关掉悬浮球，展开面板再收起，
    /// 球又冒出来了——开关形同虚设。因为"收起面板"发生在"关掉开关"之后，
    /// 把状态覆盖了回去。
    ///
    /// - Parameters:
    ///   - orbEnabled: 设置里是否开启悬浮球
    ///   - isCollapsing: 是否正在播收起动画
    static func shouldRevealOrbOnCollapse(
        orbEnabled: Bool,
        isCollapsing: Bool
    ) -> Bool {
        // 球被关掉时，任何路径都不该让它出现
        guard orbEnabled else { return false }
        // 正在收起才需要浮现，其他时机不插手
        return isCollapsing
    }
}

extension UILogic {
    /// 面板展开时，要不要对球播"被吸入"的动画。
    ///
    /// 球关掉后窗口已经 orderOut，这时再去改 collapse / ignoresMouseEvents
    /// 只会污染状态——下次开启时球可能带着旧的 collapse 值出现（缩成一团）。
    ///
    /// - Parameter orbEnabled: 设置里是否开启悬浮球
    static func shouldAbsorbOrb(orbEnabled: Bool) -> Bool {
        orbEnabled
    }
}

// MARK: - 折叠淡出曲线

extension UILogic {
    /// 折叠时面板的不透明度曲线。
    ///
    /// 页面不能消失太快——这是用户体验问题，也是可测的数值问题。
    ///
    /// 原来的曲线 [1, 1, 0.88, 0.55, 0] 到 55% 还有 0.88，然后骤降，
    /// 最后 22% 直接归零。观感是"一直很清楚、末尾啪地没了"，
    /// 完全看不到面板收缩的过程。
    ///
    /// 现在让淡出更早起步、更均匀，面板缩小的全程都有内容可见。
    static let foldFadeValues: [NSNumber] = [1.0, 1.0, 0.92, 0.70, 0.38, 0.0]
    static let foldFadeKeyTimes: [NSNumber] = [0, 0.30, 0.48, 0.66, 0.84, 1.0]

    /// 折叠过程中，某个进度处的不透明度（线性插值）。
    static func foldOpacity(atProgress t: Double) -> Double {
        let ts = foldFadeKeyTimes.map { $0.doubleValue }
        let vs = foldFadeValues.map { $0.doubleValue }
        guard let first = ts.first, let last = ts.last else { return 1 }
        if t <= first { return vs.first ?? 1 }
        if t >= last { return vs.last ?? 0 }
        for i in 1..<ts.count where t <= ts[i] {
            let span = ts[i] - ts[i-1]
            guard span > 0 else { return vs[i] }
            let f = (t - ts[i-1]) / span
            return vs[i-1] + (vs[i] - vs[i-1]) * f
        }
        return vs.last ?? 0
    }
}

extension UILogic {
    /// 折叠动画期间，窗口层级能不能降。
    ///
    /// **不能**。降级会让面板立刻被前台 App 的窗口盖住——用户看到的是
    /// "页面突然消失"，后面那 0.45 秒的收缩动画全被遮在下面，等于白做。
    ///
    /// 降级必须等动画播完、窗口即将 orderOut 的那一刻再做。
    ///
    /// - Parameters:
    ///   - active: 目标状态（true = 浮到最上层）
    ///   - isRevealing: 展开动画是否在播
    static func canChangeWindowLevel(active: Bool, isRevealing: Bool) -> Bool {
        // 要升到最上层：任何时候都可以
        if active { return true }
        // 要降级：展开动画期间不行
        return !isRevealing
    }
}
