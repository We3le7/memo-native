import Foundation

// MARK: - 提醒摘要（纯逻辑，可单测）

enum Digest {
    static func body(for items: [Memo], limit: Int = 6) -> String {
        guard !items.isEmpty else { return "" }
        var lines = items.prefix(limit).map { item -> String in
            let due = item.dueLabel.text
            return "\(item.priority.icon) \(item.title)（\(due)）"
        }
        if items.count > limit {
            lines.append("…… 另有 \(items.count - limit) 项")
        }
        return "共 \(items.count) 项未完成\n" + lines.joined(separator: "\n")
    }
}
