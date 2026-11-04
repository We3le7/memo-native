import CoreGraphics

/// 悬浮球的几何常量。
///
/// 单独成文件：这里只有纯数值，不依赖 AppKit/SwiftUI 的任何视图类型，
/// 因此可以被单元测试直接链接验证，而不用把整个 UI 层拖进测试目标。
enum OrbMetrics {
    /// 窗口尺寸（含阴影留白）
    ///
    /// 实测：球体 46pt + 逾期光晕 + 双层阴影 的外接尺寸约 62pt。
    /// 之前是 52pt，光晕和阴影会被窗口边缘裁掉，看起来"脏"。
    /// 这里留 2pt 余量。
    static let size: CGFloat = 64
    /// 圆形气泡的可视直径
    static let bubble: CGFloat = 46
    /// 球与展开面板之间的间距
    static let gap: CGFloat = 10
    /// 吸附到屏幕边缘时的内缩
    static let snapInset: CGFloat = 12
}
