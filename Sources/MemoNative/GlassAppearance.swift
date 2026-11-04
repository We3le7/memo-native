import SwiftUI

/// 玻璃强度 → 具体渲染参数的换算。
///
/// 单独成文件：这里只有数值映射，不碰任何视图实例，
/// 因此能被单元测试直接验证。玻璃参数一旦算错，
/// 症状是「面板发白、看不见底下的东西」，很难靠肉眼定位。
enum GlassAppearance {
    /// 默认强度（对应之前手调的 0.7 alpha 观感）
    static let defaultStrength: Double = 0.55

    /// 强度 → NSVisualEffectView.alphaValue
    ///
    /// 方向要特别注意：**alphaValue 越小越透**。
    /// 所以用户刻度 0（不透）→ alpha 1.0；1（最透）→ alpha 0.35。
    /// 下限不取 0：alpha 太小时模糊会一起消失，只剩一块灰雾。
    static func materialAlpha(for strength: Double) -> Double {
        let s = clamp(strength)
        return 1.0 - s * 0.65
    }

    /// 强度 → 面板玻璃之上的那层着色浓度
    ///
    /// 越透的时候，越需要一点点着色把台面「压住」，
    /// 否则背后的高对比内容会顶穿文字的可读性。
    static func veilOpacity(for strength: Double) -> Double {
        let s = clamp(strength)
        // 强度 0 → 0.42（偏实，几乎不透）
        // 强度 1 → 0.06（几乎不遮）
        return 0.42 - s * 0.36
    }

    /// 强度 → 悬浮球的材质不透明度
    ///
    /// 球比面板更小、更贴近桌面，透光需求更明显，
    /// 因此曲线更陡：低强度时保持实心易辨认，高强度时几乎全透。
    static func orbMaterialOpacity(for strength: Double) -> Double {
        let s = clamp(strength)
        // 实测：ultraThinMaterial 在 opacity=1 时 alpha 就是 1.000（完全不透明），
        // 所以透光完全取决于这个系数，必须给足跨度。
        // 强度 0 → 0.95（实心，球清晰可辨）
        // 强度 1 → 0.22（玻璃很薄，桌面明显透上来，但模糊仍在）
        return 0.95 - s * 0.73
    }

    /// 强度 → 球的"实心"底衬不透明度
    ///
    /// 球比面板更需要这层：它是漂浮在桌面上的孤立圆形，
    /// 一旦整体透掉，就只剩一圈高光，等于从屏幕上消失。
    /// 所以低强度时必须几乎不透明，高强度时才允许明显透光。
    static func orbSolidOpacity(for strength: Double) -> Double {
        let s = clamp(strength)
        // 强度 0 → 0.55（补足实心感，低强度下球是结实的）
        // 强度 1 → 0.00（完全让位给材质，避免把透光又堵回去）
        //
        // 底衬只该"补一点点"，不该喧宾夺主：
        // 它叠在材质之上，权重太大会直接把透光抵消掉。
        return 0.55 * (1 - s)
    }

    /// 强度 → 球的边缘高光强度
    ///
    /// 玻璃越薄，边缘那圈高光越重要——否则球会"化"进背景里丢掉轮廓。
    static func orbRimOpacity(for strength: Double) -> Double {
        let s = clamp(strength)
        return 0.34 + s * 0.30
    }

    /// 强度 → 显示用的档位名
    static func label(for strength: Double) -> String {
        switch clamp(strength) {
        case ..<0.2: return "几乎不透明"
        case ..<0.45: return "清淡"
        case ..<0.7: return "标准"
        case ..<0.9: return "通透"
        default: return "极透"
        }
    }

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
