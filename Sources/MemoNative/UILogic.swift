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

// MARK: - 动效时长

extension UILogic {
    /// 展开与折叠的时长，单位秒。
    ///
    /// 两者必须相等。曾经为了"收回去慢一点"把折叠单独调慢，
    /// 结果同一个动作一快一慢，看着不像同一件事的正反面。
    ///
    /// 这里把数值集中一份，测试直接比对，源码里也只剩这两个常量。
    static let unfoldSeconds: Double = 0.34
    static let foldSeconds: Double = 0.34

    /// 展开与折叠是否同速。
    static var isSymmetricDuration: Bool {
        abs(unfoldSeconds - foldSeconds) < 0.0001
    }
}

extension UILogic {
    /// 展开保护期（秒）。
    ///
    /// 必须**大于动画时长**，否则会出现：展开动画还在播，
    /// 系统在激活过程中发来一次失焦通知，面板被中途收掉——观感就是"一闪"。
    ///
    /// 也不能太长：用户展开、看一眼、立刻切走，应该能正常收起。
    static let revealGraceSeconds: Double = 0.75

    /// 保护期是否覆盖得动画全程。
    static var graceCoversUnfold: Bool {
        revealGraceSeconds > unfoldSeconds
    }
}

extension UILogic {
    /// 保护期内收到失焦，该怎么处理。
    enum GraceResignAction: Equatable {
        /// 当场按设置收起/下沉
        case actNow
        /// 记一笔，等保护期结束再确认
        case deferCheck
        /// 直接忽略
        case ignore
    }

    /// 判定保护期内的一次失焦事件。
    ///
    /// 这里踩过一个坑：最早是"保护期内直接 return"——为了挡住激活过程中
    /// 系统发来的假失焦。但那样会把**真实切走**也一起吞掉：
    /// 用户展开面板后 0.7 秒内切到别的 App，面板就不收了，看起来像折叠失败。
    ///
    /// 后来改成 deferCheck：保护期内不判，等保护期结束再看一眼
    /// App 是否真的不在前台。真走了就折，假失焦就忽略。
    ///
    /// - Parameters:
    ///   - inGrace: 是否还在保护期内
    ///   - isHiding: 是否正在播收起动画
    ///   - isPanelVisible: 面板是否可见
    static func graceResignAction(
        inGrace: Bool,
        isHiding: Bool,
        isPanelVisible: Bool
    ) -> GraceResignAction {
        guard isPanelVisible, !isHiding else { return .ignore }
        return inGrace ? .deferCheck : .actNow
    }
}

// MARK: - 优先级色点（悬停时展开的那四个）

extension UILogic {
    /// 色点高度（胶囊的短边）
    static let dotVisualSize: Double = 8

    /// 色点宽度（胶囊的长边）。
    ///
    /// 两端是半圆（半径 = 半高 = 4pt），中间留 4pt 平直段。
    /// 宽度 8 就是正圆（平直段为 0）；12 让胶囊形态看得出来，
    /// 又不至于长到像条状图。
    static let dotVisualWidth: Double = 12

    /// 中间平直段长度（两端半圆之外的直线部分）。
    static var dotFlatSegment: Double { dotVisualWidth - dotVisualSize }
    /// 每格命中帧边长（方形，不可见）
    static let dotHitFrame: Double = 16
    /// 相邻命中帧之间的间距
    static let dotHitSpacing: Double = 2

    /// 相邻两个圆点的圆心距。
    static var dotPitch: Double { dotHitFrame + dotHitSpacing }

    /// 单个命中的面积。
    static var dotHitArea: Double { dotHitFrame * dotHitFrame }

    /// 四个色点整组占用的宽度。
    static var dotGroupWidth: Double {
        dotHitFrame * 4 + dotHitSpacing * 3
    }

    /// 命中区是否会互相重叠。
    ///
    /// 重叠会让"点在两个圆之间"变成不确定事件——
    /// 用户以为点的是右边那个，命中却是左边那个。
    static var dotHitsOverlap: Bool {
        dotHitFrame > dotPitch
    }

    /// 命中区是否足够大。
    ///
    /// 8pt 的圆直接当按钮太小，要瞄着点。16pt 帧让整格都可点。
    static var dotHitIsComfortable: Bool {
        dotHitFrame >= 14
    }
}

// MARK: - 工期滑块与滚轮

extension UILogic {
    /// 工期可选范围
    static let spanRange: ClosedRange<Int> = 1...30

    /// 工期文案。1 天说"当天"更自然。
    static func spanLabel(_ span: Int) -> String {
        span <= 1 ? "当天" : "\(span) 天"
    }
}

// MARK: - 配色对比度

extension UILogic {
    /// WCAG 相对亮度。
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG 对比度（1...21）。
    static func contrastRatio(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double)
    ) -> Double {
        let la = relativeLuminance(r: a.0, g: a.1, b: a.2)
        let lb = relativeLuminance(r: b.0, g: b.1, b: b.2)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 面板背景的近似色（深色 / 浅色）。
    ///
    /// 实际是毛玻璃，这里是取样得到的等效值——足够判断对比度。
    static let darkPanelBackground: (Double, Double, Double) = (0.118, 0.118, 0.118)
    static let lightPanelBackground: (Double, Double, Double) = (0.96, 0.96, 0.96)

    /// 非文本元素的可读下限（WCAG 1.4.11）。
    static let minContrast: Double = 3.0
}

extension UILogic {
    /// 把带透明度的前景色合成到背景上，得到最终呈现的颜色。
    static func blend(
        _ fg: (Double, Double, Double),
        _ bg: (Double, Double, Double),
        _ alpha: Double
    ) -> (Double, Double, Double) {
        (fg.0 * alpha + bg.0 * (1 - alpha),
         fg.1 * alpha + bg.1 * (1 - alpha),
         fg.2 * alpha + bg.2 * (1 - alpha))
    }
}

// MARK: - 卡片网格

extension UILogic {
    /// 卡片列数。
    ///
    /// 面板内容宽固定约 584pt，两列时每张约 280pt。
    ///
    /// 为什么是两列而不是三列：三列每张只有 184pt，放不下
    /// 「日期 + 工期 + 优先级」这一整行元信息——曾经塞过，结果是
    /// 日期被挤成"3 天后"还得换行。两列 280pt 才够一行读完。
    ///
    /// 代价是一屏能看到的件数变少（2 列 × 约 4 排 = 8 张），
    /// 换来的是每张卡的信息完整度。卡片的价值在"看清一件事"，
    /// 而不是"看到更多件事"——后者是列表的强项。
    static func cardColumnCount() -> Int { 2 }

    /// 卡片最小高度。
    ///
    /// 一行标题只需 54pt，三行需要 88pt。用 minHeight 而不是固定高度：
    /// 固定 84pt 会把第三行截掉。网格里同一排由 LazyVGrid 拉齐，
    /// 所以单张撑高不会造成参差。
    static let cardMinHeight: Double = 84

    /// 单张卡片宽度。
    static func cardWidth(available: Double, columns: Int, spacing: Double) -> Double {
        guard columns > 0 else { return 0 }
        let w = (available - spacing * Double(columns - 1)) / Double(columns)
        return max(0, w)
    }
}
