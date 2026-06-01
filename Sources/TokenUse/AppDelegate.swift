import AppKit
import SwiftUI
import Sparkle

@main
struct TokenUseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController?

    static var isSparkleConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feedURL = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EdgeWindowManager.shared.setup()

        if SettingsManager.shared.enableAutoUpdate, Self.isSparkleConfigured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        // 启动数据拉取
        Task {
            await AppState.shared.start()
        }
    }

    /// 暴露给 UI 手动触发更新检查（如设置页"立即检查更新"按钮）
    func checkForUpdates() {
        guard Self.isSparkleConfigured else {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = "当前应用包未配置 Sparkle 发布公钥（SUPublicEDKey）。请在正式发布包中写入公钥后再启用自动更新。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if updaterController == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        SettingsManager.shared.lastUpdateCheckDate = Date()
        updaterController?.updater.checkForUpdates()
    }
}
