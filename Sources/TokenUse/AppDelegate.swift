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
    // Sparkle 2.x 标准启动器：startingUpdater: true 表示构造时即启动 SPUUpdater，
    // 自动按 Info.plist 的 SUFeedURL / SUEnableAutomaticChecks 拉取 appcast。
    // Why SPUStandardUpdaterController：LSUIElement app 下仍会注入"Check for Updates…"
    // 菜单项到 macOS 顶部菜单栏，UI 一致性最好。
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EdgeWindowManager.shared.setup()

        // 启动数据拉取
        Task {
            await AppState.shared.start()
        }
    }

    /// 暴露给 UI 手动触发更新检查（如设置页"立即检查更新"按钮）
    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}
