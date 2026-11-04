import Foundation
import ServiceManagement

/// 开机自启（macOS 13+ 官方 SMAppService；更老的系统回退到 LaunchAgent）
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return FileManager.default.fileExists(atPath: legacyPlistURL.path)
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                    } else if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("开机自启设置失败：\(error.localizedDescription)")
                }
            } else {
                newValue ? installLegacyAgent() : removeLegacyAgent()
            }
        }
    }

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.memo.native.plist")
    }

    private static func installLegacyAgent() {
        let exec = Bundle.main.executablePath ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>local.memo.native</string>
          <key>ProgramArguments</key><array><string>\(exec)</string><string>--background</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
        </dict></plist>
        """
        try? FileManager.default.createDirectory(
            at: legacyPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? plist.write(to: legacyPlistURL, atomically: true, encoding: .utf8)
        run("/bin/launchctl", ["load", legacyPlistURL.path])
    }

    private static func removeLegacyAgent() {
        run("/bin/launchctl", ["unload", legacyPlistURL.path])
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }

    private static func run(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
    }
}
