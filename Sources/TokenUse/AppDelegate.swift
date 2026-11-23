import AppKit
import SwiftUI
import Sparkle

@main
struct TokenUseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(isStandaloneWindow: true)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var updaterController: SPUStandardUpdaterController?

    override init() {
        super.init()
        Self.shared = self
    }

    static var isSparkleConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feedURL = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    private func ensureUpdaterControllerStarted() -> SPUStandardUpdaterController? {
        guard Self.isSparkleConfigured else { return nil }
        if let updaterController {
            return updaterController
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = SettingsManager.shared.enableAutoUpdate
        controller.startUpdater()
        updaterController = controller
        return controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        DebugLogger.log("🚀 applicationDidFinishLaunching 开始")

        NSApp.setActivationPolicy(.accessory)
        DebugLogger.log("✅ 设置 accessory 模式完成")

        EdgeWindowManager.shared.setup()
        DebugLogger.log("✅ EdgeWindowManager.setup() 完成")

        ResetCreditNotificationService.shared.setup()
        DebugLogger.log("✅ ResetCreditNotificationService.setup() 完成")

        if let controller = ensureUpdaterControllerStarted() {
            DebugLogger.log("✅ Sparkle 更新器已启动（自动检查：\(controller.updater.automaticallyChecksForUpdates ? "开启" : "关闭")）")
        } else {
            DebugLogger.log("⚠️ Sparkle 自动更新未配置")
        }

        // 启动数据拉取
        DebugLogger.log("📊 准备启动 AppState.shared.start()")
        Task {
            await AppState.shared.start()
        }

        DebugLogger.log("🚀 applicationDidFinishLaunching 完成")
    }

    func setAutomaticUpdateChecksEnabled(_ enabled: Bool) {
        guard let controller = ensureUpdaterControllerStarted() else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    /// 暴露给 UI 手动触发更新检查（如设置页"立即检查更新"按钮）
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)

        guard Self.isSparkleConfigured else {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = "当前应用包未配置 Sparkle 发布公钥（SUPublicEDKey）。请在正式发布包中写入公钥后再启用自动更新。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        guard let controller = ensureUpdaterControllerStarted() else { return }
        SettingsManager.shared.lastUpdateCheckDate = Date()
        controller.checkForUpdates(nil)
    }
}
