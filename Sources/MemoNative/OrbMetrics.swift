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
    /// 吸附到屏幕边缘时的内缩
    static let snapInset: CGFloat = 12
}
