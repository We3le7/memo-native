import CoreGraphics
import Foundation

/// 悬浮球展开/收起的形变曲线。
///
/// 抽成纯函数是为了能测：这条曲线决定"球是被吸进去的，还是被掐掉的"，
/// 手调参数时很容易把峰值调没或调成抖动，测试能立刻发现。
enum OrbMotion {
    /// 鼓起阶段的最高点位置（占整个吸入进度的比例）
    static let peak: CGFloat = 0.35
    /// 鼓起幅度：最多比常态大 10%
    static let swellAmount: CGFloat = 0.10
    /// 收缩幅度：最终缩到 55%
    static let shrinkAmount: CGFloat = 0.55

    /// 吸入进度 0…1 → 缩放比例。
    ///
    /// 形状：从 1.0 轻轻鼓到约 1.10，再一路收到约 0.45。
    /// 直接单调缩小会像被掐断——先鼓后收才有"被吸进去"的动感。
    static func scale(for collapse: CGFloat) -> CGFloat {
        let c = max(0, min(1, collapse))
        guard c > 0 else { return 1.0 }
        let swell: CGFloat = c <= peak
            ? c / peak                    // 0 → 1：鼓起来
            : (1 - c) / (1 - peak)        // 1 → 0：落回去
        return 1.0 + swellAmount * swell - shrinkAmount * (c * c)
    }

    /// 吸入过程中的不透明度。
    /// 缩到一半时边缘会显得硬，叠一层淡出才柔和；留 5% 不归零，
    /// 避免完全透明的窗口在部分系统版本上被判定为"不可见"而不响应后续更新。
    static func opacity(for collapse: CGFloat) -> Double {
        let c = max(0, min(1, collapse))
        return 1.0 - Double(c) * 0.95
    }
}
