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
        static let enableAutoUpdate = "enableAutoUpdate"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        static let skippedVersion = "skippedVersion"
        static let enableAutoDiscovery = "enableAutoDiscovery"
        static let showEstimatedCost = "showEstimatedCost"
        static let providerOrder = "providerOrder"
        static let dockEdge = "dockEdge"
        static let dockVerticalRatio = "dockVerticalRatio"
        static let dockScreenID = "dockScreenID"
    }

    private struct PersistedAccountStore: Codable {
        var manualAccounts: [ProviderAccountConfig] = []
        var accountOverrides: [String: AccountOverride] = [:]
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

    @Published var enableAutoDiscovery: Bool {
        didSet { defaults.set(enableAutoDiscovery, forKey: Keys.enableAutoDiscovery) }
    }

    @Published var showEstimatedCost: Bool {
        didSet { defaults.set(showEstimatedCost, forKey: Keys.showEstimatedCost) }
    }

    @Published var providerOrder: [TrackedProvider] {
        didSet {
            defaults.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder)
        }
    }

    /// 侧边栏贴靠屏幕边缘（支持 `.left` 贴左 / `.right` 贴右，默认 `.right`）
    @Published var dockEdge: DockEdge {
        didSet {
            let normalized: DockEdge = (dockEdge == .left) ? .left : .right
            if normalized != dockEdge {
                dockEdge = normalized
                return
            }
            defaults.set(normalized.rawValue, forKey: Keys.dockEdge)
        }
    }

    /// 侧边栏垂直高度比例（`0.0` = 最上方，`0.5` = 居中默认，`1.0` = 最下方）
    @Published var dockVerticalRatio: Double {
        didSet {
            let clamped = min(1.0, max(0.0, dockVerticalRatio))
            if abs(clamped - dockVerticalRatio) > 0.000_001 {
                dockVerticalRatio = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.dockVerticalRatio)
        }
    }

    /// 多显示器场景下记录侧边栏所在屏幕 ID（缺省 `nil` 自动跟随主屏幕）
    @Published var dockScreenID: UInt32? {
        didSet {
            if let dockScreenID {
                defaults.set(Int(dockScreenID), forKey: Keys.dockScreenID)
            } else {
                defaults.removeObject(forKey: Keys.dockScreenID)
            }
        }
    }

    @Published private(set) var manualAccounts: [ProviderAccountConfig] = []
    @Published private(set) var accountOverrides: [String: AccountOverride] = [:]

    private var accountStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("TokenUse/accounts-config.json")
    }

    private init() {
        self.customMascotPath = defaults.string(forKey: Keys.customMascotPath)
        let saved = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = saved > 0 ? saved : 1800 // default 30 min

        if defaults.object(forKey: Keys.enableAutoUpdate) == nil {
            self.enableAutoUpdate = true
        } else {
            self.enableAutoUpdate = defaults.bool(forKey: Keys.enableAutoUpdate)
        }

        if defaults.object(forKey: Keys.enableAutoDiscovery) == nil {
            self.enableAutoDiscovery = true
        } else {
            self.enableAutoDiscovery = defaults.bool(forKey: Keys.enableAutoDiscovery)
        }

        if defaults.object(forKey: Keys.showEstimatedCost) == nil {
            self.showEstimatedCost = true
        } else {
            self.showEstimatedCost = defaults.bool(forKey: Keys.showEstimatedCost)
        }

        self.providerOrder = Self.normalizedProviderOrder(from: defaults.stringArray(forKey: Keys.providerOrder))

        if let rawEdge = defaults.string(forKey: Keys.dockEdge),
           let parsedEdge = DockEdge(rawValue: rawEdge),
           parsedEdge == .left || parsedEdge == .right {
            self.dockEdge = parsedEdge
        } else {
            self.dockEdge = .right
        }

        if defaults.object(forKey: Keys.dockVerticalRatio) == nil {
            self.dockVerticalRatio = 0.5
        } else {
            self.dockVerticalRatio = min(1.0, max(0.0, defaults.double(forKey: Keys.dockVerticalRatio)))
        }

        if let rawScreen = defaults.object(forKey: Keys.dockScreenID) as? Int, rawScreen > 0 {
            self.dockScreenID = UInt32(rawScreen)
        } else {
            self.dockScreenID = nil
        }

        self.lastUpdateCheckDate = defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        self.skippedVersion = defaults.string(forKey: Keys.skippedVersion)

        loadAccountStore()
    }

    // MARK: - Sidebar Position

    var isDefaultDockPosition: Bool {
        dockEdge == .right && abs(dockVerticalRatio - 0.5) < 0.005 && dockScreenID == nil
    }

    func resetDockPosition() {
        dockScreenID = nil
        dockEdge = .right
        dockVerticalRatio = 0.5
    }

    // MARK: - Provider Display Order

    var isDefaultProviderOrder: Bool {
        providerOrder == TrackedProvider.allCases
    }

    func resetProviderOrder() {
        providerOrder = TrackedProvider.allCases
    }

    func moveProvider(_ provider: TrackedProvider, to targetIndex: Int) {
        guard let fromIndex = providerOrder.firstIndex(of: provider) else { return }
        let clampedIndex = max(0, min(providerOrder.count - 1, targetIndex))
        guard fromIndex != clampedIndex else { return }
        var updated = providerOrder
        updated.remove(at: fromIndex)
        updated.insert(provider, at: clampedIndex)
        providerOrder = updated
    }

    private static func normalizedProviderOrder(from rawValues: [String]?) -> [TrackedProvider] {
        guard let rawValues, !rawValues.isEmpty else {
            return TrackedProvider.allCases
        }
        var seen = Set<TrackedProvider>()
        var result: [TrackedProvider] = []
        for raw in rawValues {
            if let provider = TrackedProvider(rawValue: raw), seen.insert(provider).inserted {
                result.append(provider)
            }
        }
        for provider in TrackedProvider.allCases where seen.insert(provider).inserted {
            result.append(provider)
        }
        return result
    }

    // MARK: - Multi-Account Persistence

    private func loadAccountStore() {
        guard FileManager.default.fileExists(atPath: accountStoreURL.path),
              let data = try? Data(contentsOf: accountStoreURL),
              let store = try? JSONDecoder().decode(PersistedAccountStore.self, from: data) else {
            return
        }
        self.manualAccounts = store.manualAccounts
        self.accountOverrides = store.accountOverrides
    }

    private func saveAccountStore() {
        let store = PersistedAccountStore(
            manualAccounts: manualAccounts,
            accountOverrides: accountOverrides
        )
        do {
            try FileManager.default.createDirectory(
                at: accountStoreURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: accountStoreURL, options: .atomic)
        } catch {
            DebugLogger.log("❌ [SettingsManager] 保存账号配置失败: \(error)")
        }
    }

    func saveManualAccount(_ account: ProviderAccountConfig, secret: String?, consoleCookie: String? = nil) throws {
        let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSecret, !trimmedSecret.isEmpty {
            try KeychainStore.saveSecret(trimmedSecret, for: account.id)
        }

        if let consoleCookie {
            let trimmedCookie = consoleCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCookie.isEmpty {
                KeychainStore.deleteSecret(for: Self.cookieKeychainKey(for: account.id))
            } else {
                try KeychainStore.saveSecret(trimmedCookie, for: Self.cookieKeychainKey(for: account.id))
            }
        }

        if let idx = manualAccounts.firstIndex(where: { $0.id == account.id }) {
            manualAccounts[idx] = account
        } else {
            manualAccounts.append(account)
        }
        saveAccountStore()
    }

    func deleteManualAccount(id: String) {
        manualAccounts.removeAll { $0.id == id }
        KeychainStore.deleteSecret(for: id)
        KeychainStore.deleteSecret(for: Self.cookieKeychainKey(for: id))
        saveAccountStore()
    }

    func setAccountEnabled(_ isEnabled: Bool, for account: ProviderAccountConfig) {
        if account.source == .manual {
            if let idx = manualAccounts.firstIndex(where: { $0.id == account.id }) {
                manualAccounts[idx].isEnabled = isEnabled
                saveAccountStore()
            }
        } else {
            var override = accountOverrides[account.id] ?? AccountOverride()
            override.isEnabled = isEnabled
            accountOverrides[account.id] = override
            saveAccountStore()
        }
    }

    func updateDiscoveredAccountOverride(
        accountID: String,
        customLabel: String?,
        isEnabled: Bool?,
        customLogPath: String?,
        regionOrBaseURL: String?,
        consoleCookie: String?
    ) throws {
        var override = accountOverrides[accountID] ?? AccountOverride()
        let trimmedLabel = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        override.customLabel = (trimmedLabel?.isEmpty == false) ? trimmedLabel : nil
        if let isEnabled {
            override.isEnabled = isEnabled
        }
        let trimmedLog = customLogPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        override.customLogPath = (trimmedLog?.isEmpty == false) ? trimmedLog : nil
        let trimmedRegion = regionOrBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        override.regionOrBaseURL = (trimmedRegion?.isEmpty == false) ? trimmedRegion : nil

        accountOverrides[accountID] = override
        saveAccountStore()

        if let consoleCookie {
            let trimmedCookie = consoleCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCookie.isEmpty {
                KeychainStore.deleteSecret(for: Self.cookieKeychainKey(for: accountID))
            } else {
                try KeychainStore.saveSecret(trimmedCookie, for: Self.cookieKeychainKey(for: accountID))
            }
        }
    }

    nonisolated static func cookieKeychainKey(for accountID: String) -> String {
        "\(accountID).console_cookie"
    }

    // MARK: - Mascot

    func resetMascot() {
        customMascotPath = nil
    }

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
