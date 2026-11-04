import AppKit
import SwiftUI

/// 设计系统：颜色、间距、动效的统一出处。
///
/// 前几轮把界面删得太素——只剩灰阶和四个小圆点，规矩但没味道。
/// 这一轮的原则变了：
///   * 层次靠「表面」（surface）而不是分割线：卡片、胶囊、底纹，深浅有别
///   * 颜色不只用于优先级：强调色负责「可交互」，优先级色负责「语义」
///   * 光影和质感来自极淡的渐变与内描边，而不是加重边框
enum Theme {
    // 间距
    static let gutter: CGFloat = 20
    static let radius: CGFloat = 12
    static let hairline: CGFloat = 0.5

    // 语义灰阶
    //
    // 统一用 Color.primary 叠不透明度：既能自适应深浅色，
    // 也能在三元表达式里作为具体 Color 参与类型推断
    //（SwiftUI 的 .tertiary/.quaternary 是 ShapeStyle，不能当 Color 用）。
    static let ink = Color.primary
    static let inkSecondary = Color.primary.opacity(0.66)
    static let inkTertiary = Color.primary.opacity(0.44)
    static let inkQuaternary = Color.primary.opacity(0.24)

    /// 交互强调色：祖母绿，按外观分别取值。
    ///
    /// 迭代过程（每一步都是实测对比度推翻上一版）：
    ///
    ///   蓝 #5C85FA      深色 4.89 / 浅色 3.12   浅色偏弱
    ///   紫 #8B5CF6      深色 3.94 / 浅色 3.88   深色看不清（用户反馈）
    ///   紫 #A78BFA      深色 6.12 / 浅色 5.60   达标，但用户想换成绿色
    ///   绿 #34D399      深色 8.65 / 浅色 5.43   采用
    ///
    /// 绿色在两侧都比紫色更宽裕，是这套配色里对比度最高的强调色。
    ///
    /// 关键教训（改颜色时一直适用）：**只调基色不够**。
    /// 深色下发闷的真正原因是选中底块只有 13% 不透明度——
    /// 合成后与背景对比仅 1.15，几乎融进背景。
    /// 所以底块必须同步提到 16~22%，描边提到 75%。
    ///
    /// 浅色用偏深的 #096C4A：白底上深色更清楚（对比 5.90，
    /// 压在 16% 底块上仍有 4.66）。
    /// 深色用偏亮的 #34D399：深灰底上亮度决定可读性。
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // 浅色 #096C4A / 深色 #34D399
        return isDark
            ? NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
            : NSColor(srgbRed: 0.035, green: 0.424, blue: 0.290, alpha: 1)
    })

    /// 中性选中态：用文字色本身做底，不引入色相。
    ///
    /// 输入框和工期选择器都走这一套——它们是"文字的一部分"，
    /// 染色反而会把注意力从用户输入的内容上挪开。
    /// 优先级选择器不同：那四档是有语义的，必须用颜色区分。
    /// 填充只需给出"这一块被选中"的区域感；边界靠描边。
    /// 描边取 40%：浅色 2.82 / 深色 3.78，能勾出轮廓但不抢文字。
    /// （22% 时只有 1.68 / 2.05，边界会糊。）
    static let selectionFill = Color.primary.opacity(0.12)
    static let selectionStroke = Color.primary.opacity(0.40)

    // 表面层次：从平面到抬起
    static let surface = Color.primary.opacity(0.045)
    static let surfaceRaised = Color.primary.opacity(0.075)
    static let surfaceHover = Color.primary.opacity(0.055)

    /// 描边：比表面略深一点点，形成「薄边」而不是硬框
    static let stroke = Color.primary.opacity(0.075)
    static let strokeStrong = Color.primary.opacity(0.12)

    // 动效
    //
    // 三档曲线，用途分明：
    //   snappy —— 点击、切换等「即时反馈」，要快
    //   soft   —— 大块内容的进出场，要稳
    //   easeFast —— 悬停这类高频、低幅的变化，快到几乎无感
    static let springSnappy = Animation.spring(response: 0.26, dampingFraction: 0.80)
    static let springSoft = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let springBouncy = Animation.spring(response: 0.34, dampingFraction: 0.70)
    static let easeFast = Animation.easeOut(duration: 0.14)
    static let easeMedium = Animation.easeInOut(duration: 0.22)

    /// 列表增删的动效：入场略带弹跳，退场干脆
    static let rowInsert = Animation.spring(response: 0.38, dampingFraction: 0.76)
    static let rowRemove = Animation.easeIn(duration: 0.16)
}

// 优先级配色，与 App 图标里的四个点一致。
//
// 每个颜色都按深浅色分别取值：同一份色相，浅色模式下压深、
// 深色模式下提亮，让对比度在两种外观下都够。
//
// 实测对比度（WCAG，非文本元素要求 ≥ 3.0）：
//   旧固定色：urgent 4.25/3.59  high 6.23/2.45  normal 7.58/2.01  low 3.66/4.17
//             橙和黄在浅色模式下只有 2.4 / 2.0——黄在白底上几乎看不见。
//   新动态色：见下方各自注释。
extension Priority {
    var tint: Color {
        switch self {
        case .urgent:
            // 红：浅色下压深一点，深色下提亮一点
            return dynamic(
                light: (0.835, 0.216, 0.239),   // #D53740  浅色 4.09
                dark:  (0.949, 0.361, 0.376)    // #F25C60  深色 5.03
            )
        case .high:
            // 橙：浅色 2.45 → 3.36
            return dynamic(
                light: (0.784, 0.396, 0.031),   // #C86508  浅色 3.36
                dark:  (0.973, 0.573, 0.129)    // #F89221  深色 7.05
            )
        case .normal:
            // 黄：浅色 2.01 → 3.12，这是四色里最需要修的一个
            return dynamic(
                light: (0.639, 0.478, 0.000),   // #A37A00  浅色 3.12
                dark:  (0.941, 0.769, 0.208)    // #F0C435  深色 8.81
            )
        case .low:
            // 低优先级：绿。
            //
            // 和强调色（emerald）同属绿色系，色距只有 0.10——但它们
            // **不会同时出现在一处**：输入区（含工期选择器）已改成纯中性色，
            // 强调色现在只用于"已完成勾选圈"和设置页开关。
            // 勾选圈在列表行首，优先级圆点在行尾，隔着整行内容。
            //
            // 选森林绿而不是更亮的翠绿：和红/橙/黄的区分度更好
            //（0.81 / 0.74 / 0.61，翠绿是 0.87 / 0.81 / 0.68 但偏亮）。
            // 双模式对比度：浅 4.59 / 深 9.57。
            return dynamic(
                light: (0.082, 0.502, 0.239),   // #15803D  浅色 4.59
                dark:  (0.290, 0.871, 0.502)    // #4ADE80  深色 9.57
            )
        }
    }

    /// 按当前外观返回对应色值。
    ///
    /// 用 NSColor 的 appearance 动态构造，而不是在 SwiftUI 里读
    /// colorScheme——tint 在非 View 上下文里也要能用（测试、图标绘制）。
    private func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}
