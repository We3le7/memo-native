import CoreGraphics
import Foundation

/// 弹簧曲线的采样工具。
///
/// 为什么需要它：SwiftUI 的 withAnimation 是逐帧重算视图树的，
/// 我们这个面板有一千多行内容加一层 NSVisualEffectView，
/// 每帧重算一次就掉帧。改成 Core Animation 的 keyframe 之后，
/// 形变发生在渲染服务里，SwiftUI 一次都不用重算，帧率才能上去。
///
/// 代价是拿不到 SwiftUI 的 spring 参数，得自己采样出曲线。
enum MotionCurve {
    /// 归一化阻尼弹簧的位移响应：t ∈ [0,1] → 约 0…1，允许过冲。
    ///
    /// 标准二阶欠阻尼阶跃响应：
    ///   y(t) = 1 - e^(-a t) · (cos(b t) + a/b · sin(b t))
    /// 其中 a 决定衰减快慢，b 决定振荡频率。
    static func spring(t: CGFloat, damping: CGFloat, stiffness: CGFloat = 6.5) -> CGFloat {
        let clampedT = max(0, min(1, t))
        let zeta = max(0.05, min(1.0, damping))
        let a = zeta * stiffness
        let b = stiffness * sqrt(max(0, 1 - zeta * zeta))
        guard b > 0.0001 else { return 1 }
        let envelope = exp(-a * clampedT)
        return 1 - envelope * (cos(b * clampedT) + (a / b) * sin(b * clampedT))
    }

    /// 采样成一组值，供 CAKeyframeAnimation 使用。
    ///
    /// 从 0 到 1 采样 count 个点，最后一个强制钉在 1.0——
    /// 曲线在 t=1 时可能还差一点点，不钉死会留下亚像素偏移。
    static func springValues(
        from start: CGFloat = 0,
        to end: CGFloat = 1,
        damping: CGFloat,
        count: Int = 30
    ) -> [CGFloat] {
        guard count > 1 else { return [end] }
        var values: [CGFloat] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let p = spring(t: t, damping: damping)
            values.append(start + (end - start) * p)
        }
        values[values.count - 1] = end
        return values
    }

    /// 每个采样点对应的时刻（0…1），与 springValues 配套传给 keyTimes。
    static func keyTimes(count: Int) -> [NSNumber] {
        (0..<count).map { NSNumber(value: Double($0) / Double(max(1, count - 1))) }
    }
}
