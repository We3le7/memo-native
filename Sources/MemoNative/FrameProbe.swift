import AppKit
import QuartzCore

/// 动画期间的实际帧率探针（仅诊断用，由环境变量开启）。
///
/// 为什么需要：CAKeyframeAnimation 的插值发生在渲染服务里，
/// 主线程采样测不到真实刷新率。用 CVDisplayLink 跟随屏幕的
/// 垂直同步，才能知道"观众眼里"到底是多少帧。
final class FrameProbe {
    static let shared = FrameProbe()
    private var link: CVDisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var label = ""

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MEMO_FPS"] != nil
    }

    func start(_ name: String) {
        guard isEnabled else { return }
        label = name
        timestamps.removeAll()
        var l: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&l)
        guard let l else { return }
        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
            self?.timestamps.append(CACurrentMediaTime())
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(l)
        link = l
    }

    func stop() {
        guard isEnabled, let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        func emit(_ msg: String) {
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        }
        guard timestamps.count > 2 else {
            emit("[FPS] \(label): 采样不足 (\(timestamps.count))")
            return
        }
        var deltas: [Double] = []
        for i in 1..<timestamps.count {
            deltas.append(timestamps[i] - timestamps[i-1])
        }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        let sorted = deltas.sorted()
        let p95 = sorted[min(sorted.count-1, Int(Double(sorted.count) * 0.95))]
        let fps = avg > 0 ? 1.0 / avg : 0
        // 掉帧：相邻帧间隔超过 1.5 倍理想间隔
        let ideal = 1.0 / 60.0
        let drops = deltas.filter { $0 > ideal * 1.5 }.count
        emit(String(format: "[FPS] %@: 平均 %.1f fps, p95 间隔 %.1fms, 掉帧 %d/%d",
                    label, fps, p95 * 1000, drops, deltas.count))
    }
}
