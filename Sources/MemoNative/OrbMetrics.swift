import CoreGraphics

/// 悬浮球的几何常量。
///
/// 单独成文件：这里只有纯数值，不依赖 AppKit/SwiftUI 的任何视图类型，
/// 因此可以被单元测试直接链接验证，而不用把整个 UI 层拖进测试目标。
enum OrbMetrics {
    /// 窗口尺寸（含阴影与光晕的留白）
    ///
    /// 这个值必须让**阴影完整落在窗口内**，否则窗口边缘会把阴影硬切一刀，
    /// 在浅色背景上看起来就是一个"方形底"。
    ///
    /// 需求：球体 46pt + 2 × (阴影最大扩散 13pt + 余量 4pt) ≈ 80pt。
    /// 曾用 52 / 64，都因为留白不足而出现方形切边。
    static let size: CGFloat = 80
    /// 圆形气泡的可视直径
    static let bubble: CGFloat = 46
    /// 球**体**与展开面板之间的视觉间距
    static let gap: CGFloat = 10

    /// 窗口每边比球体多出的留白（阴影与光晕用掉的空间）
    static var bleed: CGFloat { (size - bubble) / 2 }
    /// 默认摆放位置距屏幕边缘的内缩（只用于首次定位，不用于拖拽）
    static let snapInset: CGFloat = 12
}

// MARK: - 位置计算（纯函数，可单测）

/// 悬浮球的位置规则。
///
/// 设计决定：**不做边缘吸附**。用户把球拖到哪，它就停在哪，
/// 只保证整颗球不会跑出屏幕之外（否则就再也抓不到了）。
///
/// 没有做成 FloatingOrb 的私有方法，是因为它需要被单元测试覆盖：
/// 拖拽是纯几何计算，出错的代价是「球丢了」，必须能验证。
enum OrbLayout {
    /// 把球约束回可见区域。
    ///
    /// - 若球中心落在某块屏内，就约束到那块屏（支持多屏自由移动）
    /// - 否则找最近的屏幕兜底
    /// - 任何情况下都保证球完整可见，不会被截掉一半
    static func clamp(origin: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return origin }

        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let target = screens.first { $0.contains(center) }
            ?? screens.min(by: { distanceSquared(from: center, to: $0) < distanceSquared(from: center, to: $1) })
            ?? screens[0]

        // 允许球略微贴边，但不能整颗出去
        let inset: CGFloat = 0
        let minX = target.minX + inset
        let minY = target.minY + inset
        let maxX = target.maxX - size.width - inset
        let maxY = target.maxY - size.height - inset

        return CGPoint(
            x: maxX >= minX ? min(max(origin.x, minX), maxX) : minX,
            y: maxY >= minY ? min(max(origin.y, minY), maxY) : minY
        )
    }

    /// 点到矩形的最短距离平方（用于挑选最近的屏幕）
    private static func distanceSquared(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
