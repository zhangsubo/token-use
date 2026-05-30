import AppKit
import SwiftUI

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EdgeWindowManager.shared.setup()

        // Start data fetching on launch
        Task {
            await AppState.shared.start()
        }
    }
}
