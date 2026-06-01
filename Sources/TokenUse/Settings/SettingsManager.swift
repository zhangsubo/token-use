import Foundation
import AppKit

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private var cachedCustomMascotPath: String?
    private var cachedCustomMascotImage: NSImage?

    private enum Keys {
        static let customMascotPath = "customMascotPath"
        static let refreshInterval = "refreshInterval"
        // Sparkle 自动更新相关
        // - enableAutoUpdate：是否允许启动后自动检查（镜像 SUEnableAutomaticChecks 的本地开关）
        // - lastUpdateCheckDate：UI 展示"上次检查"时间（Sparkle 自身不持久化这个）
        // - skippedVersion：用户点"稍后"时记下，下次不再提示同一版本
        static let enableAutoUpdate = "enableAutoUpdate"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        static let skippedVersion = "skippedVersion"
    }

    @Published var customMascotPath: String? {
        didSet {
            defaults.set(customMascotPath, forKey: Keys.customMascotPath)
            cachedCustomMascotPath = nil
            cachedCustomMascotImage = nil
        }
    }

    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    @Published var enableAutoUpdate: Bool {
        didSet { defaults.set(enableAutoUpdate, forKey: Keys.enableAutoUpdate) }
    }

    @Published var lastUpdateCheckDate: Date? {
        didSet { defaults.set(lastUpdateCheckDate, forKey: Keys.lastUpdateCheckDate) }
    }

    @Published var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skippedVersion) }
    }

    private init() {
        self.customMascotPath = defaults.string(forKey: Keys.customMascotPath)
        let saved = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = saved > 0 ? saved : 1800 // default 30 min

        // enableAutoUpdate 默认 true，与 Info.plist 的 SUEnableAutomaticChecks 一致
        if defaults.object(forKey: Keys.enableAutoUpdate) == nil {
            self.enableAutoUpdate = true
        } else {
            self.enableAutoUpdate = defaults.bool(forKey: Keys.enableAutoUpdate)
        }
        self.lastUpdateCheckDate = defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        self.skippedVersion = defaults.string(forKey: Keys.skippedVersion)
    }

    /// Reset mascot to bundle default
    func resetMascot() {
        customMascotPath = nil
    }

    /// Get custom mascot image if available, otherwise nil (caller falls back to bundle)
    var customMascotImage: NSImage? {
        guard let path = customMascotPath else { return nil }
        if cachedCustomMascotPath == path, let cachedCustomMascotImage {
            return cachedCustomMascotImage
        }
        guard FileManager.default.fileExists(atPath: path) else {
            customMascotPath = nil
            return nil
        }
        let image = NSImage(contentsOfFile: path)
        cachedCustomMascotPath = path
        cachedCustomMascotImage = image
        return image
    }
}
