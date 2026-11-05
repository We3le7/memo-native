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

    /// 输入框左侧图标的三种状态色。
    ///
    /// 为什么不能直接用 inkQuaternary / inkTertiary / inkSecondary：
    /// 那组是"面板上的文字"用的，放在 26pt 的图标上，
    /// 浅色模式下会**层级反转**——inkSecondary(0.66) 在白底上
    /// 对比度只有 2.17，比 inkTertiary(0.44) 的 4.52 还淡。
    /// 图标越小、越该靠对比度被看见，不能沿用字的色阶。
    ///
    /// 这里按外观分别取，保证深/浅两边都是**递增**的：
    ///   状态   深色对比  浅色对比
    ///   静止    2.29      3.40
    ///   悬停    4.49      6.65
    ///   聚焦    8.36     13.36
    static var iconIdle: Color { adaptiveInk(dark: 0.34, light: 0.52) }
    static var iconHover: Color { adaptiveInk(dark: 0.52, light: 0.34) }
    static var iconActive: Color { adaptiveInk(dark: 0.72, light: 0.16) }

    /// 按外观取一个灰度墨色
    private static func adaptiveInk(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        })
    }

    /// 强调色实心块上的文字/图标色。
    ///
    /// 浅色模式的强调是深绿（#096C4A），上面要放白字；
    /// 深色模式的强调是亮绿（#34D399），上面放白字只有 1.9:1，
    /// 几乎看不见——得放深色字。
    /// 所以不能简单地写 .white。
    static var onAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // 深色模式：强调色很亮 → 用深字
            // 浅色模式：强调色很深 → 用白字
            return isDark
                ? NSColor(srgbRed: 0.055, green: 0.11, blue: 0.09, alpha: 1)
                : NSColor.white
        })
    }

    /// 实心按钮上的文字色：面板背景本身。
    ///
    /// 按钮是"墨色实心 + 反色文字"，那反色就该是面板底色——
    /// 这样文字看起来像是从实心底上"凿"出来的，
    /// 而不是涂了一层别的颜色。
    /// 跟随外观翻转：深色模式取深灰、浅色模式取浅灰。
    static var panelBackgroundInverted: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? UILogic.darkPanelBackground : UILogic.lightPanelBackground
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // 动效
    //
    // 按**用途**分档，不按形状（spring/ease）分。
    // 早先各处直接写 .easeOut(duration: 0.16) 这类内联值，
    // 散出五种不同的时长、四套不同的弹簧参数——
    // 单看每一处都合理，放在一起就显得各走各的，
    // 界面一动起来就露馅。
    //
    // 现在收敛成五档。同一类交互用同一档，
    // 节奏感来自"一致"，不来自"每处都调过"。

    /// 悬停、按下这类高频低幅的变化。快到几乎无感，
    /// 慢一点就会觉得界面在拖手。
    static let hover = Animation.easeOut(duration: UILogic.tier("hover"))

    /// 即时反馈：点一下，东西就该动。
    /// 用于选中态、勾选、小范围的形态变化。
    static let tap = Animation.spring(response: UILogic.tier("tap"), dampingFraction: 0.80)

    /// 带一点回弹的确认感。用于"完成了某件事"这类
    /// 值得被看见的动作，弹一下比滑一下更有回应。
    static let confirm = Animation.spring(response: UILogic.tier("confirm"), dampingFraction: 0.70)

    /// 中等尺度：内容块的展开、收起、切换。
    static let move = Animation.spring(response: UILogic.tier("move"), dampingFraction: 0.86)

    /// 整行的进出场。入场略慢、带一点过冲，退场更快更干脆——
    /// 东西消失不该让人等。
    static let rowInsert = Animation.spring(response: 0.38, dampingFraction: 0.76)
    static let rowRemove = Animation.easeIn(duration: UILogic.tier("remove"))

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
