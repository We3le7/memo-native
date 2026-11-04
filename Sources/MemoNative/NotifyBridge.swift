import Foundation
import UserNotifications
import AppKit

/// 统一的通知投递通道。
///
/// 背景：未做 Apple 开发者签名的本地构建，系统会拒绝 UNUserNotificationCenter 授权
/// （"Notifications are not allowed for this application"）。为保证提醒不缺位，
/// 授权失败时自动降级为 `osascript display notification` —— 走登录用户的通知中心，
/// 同样以横幅形式出现，只是点击无法回跳 App。
@MainActor
final class NotifyBridge {
    static let shared = NotifyBridge()

    var isAuthorized = false

    /// 返回实际使用的通道名
    @discardableResult
    func deliver(title: String, body: String) -> String {
        let text = body.isEmpty ? "今天没有未完成事项 🎉" : body
        NSLog("NotifyBridge.deliver authorized=\(isAuthorized) title=\(title)")

        if isAuthorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            content.userInfo = ["deeplink": "memo://open"]
            let request = UNNotificationRequest(
                identifier: "memo.now.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("原生通知失败：\(error.localizedDescription)") }
            }
            return "notification-center"
        }

        let ok = runOsascript(title: title, body: text)
        NSLog("NotifyBridge osascript ok=\(ok)")
        return ok ? "osascript" : "none"
    }

    private func runOsascript(title: String, body: String) -> Bool {
        // 去掉 osascript 不接受的控制字符，把换行转成 " / " 保证单行展示
        let flat = body
            .replacingOccurrences(of: "\n", with: " · ")
            .replacingOccurrences(of: "\"", with: "'")
        let script = "display notification \"\(flat)\" with title \"\(title)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                NSLog("osascript 通知失败(status=\(process.terminationStatus))：\(output)")
                return false
            }
            if !output.isEmpty { NSLog("osascript 输出：\(output)") }
            return true
        } catch {
            NSLog("osascript 启动失败：\(error.localizedDescription)")
            return false
        }
    }
}
