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

    private init() {
        self.customMascotPath = defaults.string(forKey: Keys.customMascotPath)
        let saved = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = saved > 0 ? saved : 1800 // default 30 min
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
