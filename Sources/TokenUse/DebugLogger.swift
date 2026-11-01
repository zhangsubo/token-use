import Foundation

enum DebugLogger {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["TOKENUSE_DEBUG"] == "1" {
            return true
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    private static let logFile: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/TokenUse/debug.log")
    }()

    static func log(_ message: String) {
        guard enabled else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"

        // 写入文件
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? FileManager.default.createDirectory(
                    at: logFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: logFile)
            }
        }

        // 同时输出到控制台
        print(logMessage, terminator: "")
    }
}
