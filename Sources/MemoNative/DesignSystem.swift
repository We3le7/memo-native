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

    /// 交互强调色：比系统蓝偏一点靛，避免大面积使用时刺眼
    static let accent = Color(red: 0.36, green: 0.52, blue: 0.98)

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

// 优先级配色，与 App 图标里的四个点一致
extension Priority {
    var tint: Color {
        switch self {
        case .urgent: return Color(red: 0.898, green: 0.282, blue: 0.302) // #E5484D
        case .high:   return Color(red: 0.941, green: 0.506, blue: 0.059) // #F0810F
        case .normal: return Color(red: 0.851, green: 0.659, blue: 0.000) // #D9A800
        case .low:    return Color(red: 0.184, green: 0.435, blue: 0.929) // #2F6FED
        }
    }
}
