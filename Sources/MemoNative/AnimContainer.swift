import AppKit
import QuartzCore

/// 承载面板内容、专门用来做缩放开合的容器视图。
///
/// 为什么不直接动窗口的 frameView：AppKit 在每次布局时都会把 frameView
/// 图层的 anchorPoint 和 position 重置回默认值。实测设好锚点后 0.4 秒内
/// 就被抹回 (0,0)——锚点失效，缩放只能绕左上角发生，看起来像"从角落里
/// 挤出来"而不是从悬浮球那里长出来。
///
/// 自建的图层 AppKit 不会碰，anchorPoint 能稳稳留住。
final class AnimContainerView: NSView {
    /// 缩放锚点，归一化坐标（0…1）。由调用方在每次动画前设置。
    var anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    override var isFlipped: Bool { false }

    /// 设置锚点，并同步 position 让内容不位移。
    ///
    /// 改 anchorPoint 会改变图层围绕哪个点定位，如果不同时调 position，
    /// 内容会整体跳一下。position 应当等于"锚点在父坐标系里的位置"。
    func applyAnchor(_ point: CGPoint) {
        guard let layer else { return }
        anchor = point
        let bounds = layer.bounds
        layer.anchorPoint = point
        // 容器铺满窗口，父坐标系原点就是窗口左下角
        layer.position = CGPoint(
            x: bounds.width * point.x,
            y: bounds.height * point.y
        )
    }
}
