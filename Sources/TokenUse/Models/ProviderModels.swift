import AppKit
import Foundation
import SwiftUI

// MARK: - TrackedProvider

/// 核心支持的 5 大 AI 编程平台
enum TrackedProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex = "codex"
    case mimo = "mimo"
    case kimi = "kimi"
    case minimax = "minimax"
    case antigravity = "antigravity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .mimo: return "MiMo Token Plan"
        case .kimi: return "Kimi Code"
        case .minimax: return "MiniMax"
        case .antigravity: return "Antigravity"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .mimo: return "MiMo"
        case .kimi: return "Kimi"
        case .minimax: return "MiniMax"
        case .antigravity: return "Antigravity"
        }
    }

    var vendorName: String {
        switch self {
        case .codex: return "OpenAI"
        case .mimo: return "Xiaomi"
        case .kimi: return "Moonshot"
        case .minimax: return "MiniMax"
        case .antigravity: return "Google"
        }
    }

    var systemIcon: String {
        switch self {
        case .codex: return "terminal.fill"
        case .mimo: return "cpu.fill"
        case .kimi: return "moon.stars.fill"
        case .minimax: return "waveform.path.ecg"
        case .antigravity: return "sparkles"
        }
    }

    var iconResourceName: String {
        "provider-\(rawValue)"
    }

    var accentColor: Color {
        switch self {
        case .codex:
            return Color(.sRGB, red: 0.31, green: 0.68, blue: 0.98)
        case .mimo:
            return Color(.sRGB, red: 1.00, green: 0.56, blue: 0.24)
        case .kimi:
            return Color(.sRGB, red: 0.58, green: 0.49, blue: 0.98)
        case .minimax:
            return Color(.sRGB, red: 0.34, green: 0.84, blue: 0.64)
        case .antigravity:
            return Color(.sRGB, red: 0.96, green: 0.44, blue: 0.68)
        }
    }

    var credentialHint: String {
        switch self {
        case .codex:
            return "支持 ChatGPT OAuth JSON / refresh_token，自动读取 ~/.codex 与 CC Switch 多账号并支持一键切换"
        case .mimo:
            return "自动识别 Xiaomi MiMo 桌面端会话免登录拉取 Token Plan 与会员周额度，亦支持网页登录多账号"
        case .kimi:
            return "支持 sk-kimi-... API Key、OAuth 凭证或 kimi-auth 网页会话（自动读取 ~/.kimi-code / Kimi 桌面端）"
        case .minimax:
            return "支持 sk-cp-... Token Plan / Coding Plan API Key（自动识别国内 minimaxi.com 与国际版及 ~/.minimax）"
        case .antigravity:
            return "支持自动探测运行中的 Antigravity App/CLI/IDE 分组配额及多份 Google OAuth 凭证"
        }
    }

    var defaultLogPathHint: String {
        switch self {
        case .codex: return "~/.codex"
        case .mimo: return "~/.local/share/mimocode"
        case .kimi: return "~/.kimi-code"
        case .minimax: return "~/.minimax"
        case .antigravity: return "~/.gemini/antigravity"
        }
    }

    /// 根据日志客户端、provider、model 归类到 5 大目标平台（不属于这 5 类的返回 nil）
    static func classify(client: String, provider: String, model: String) -> TrackedProvider? {
        let c = client.lowercased()
        let p = provider.lowercased()
        let m = model.lowercased()

        // 1. 专属客户端优先归集（Antigravity / Codex 内部所有模型均归属该平台）
        if c == "antigravity" || p == "antigravity" {
            return .antigravity
        }
        if c == "codex" {
            // 若在 Codex 中通过自定义 provider 指向了 MiMo / MiniMax / Kimi，按实际模型/provider 归类
            if p.contains("xiaomi") || p.contains("mimo") || m.contains("mimo") {
                return .mimo
            }
            if p.contains("minimax") || m.contains("minimax") {
                return .minimax
            }
            if p.contains("kimi") || p.contains("moonshot") || m.contains("kimi") {
                return .kimi
            }
            return .codex
        }
        if c == "kimi" || c == "kimi-code" {
            return .kimi
        }
        if c == "mcode" || c == "minimax-code" {
            return .minimax
        }
        if c == "mimocode" || c == "mimo" {
            if p.contains("minimax") || m.contains("minimax") {
                return .minimax
            }
            if p.contains("kimi") || p.contains("moonshot") || m.contains("kimi") {
                return .kimi
            }
            return .mimo
        }

        // 2. 跨客户端路由（如 Claude Code / OpenCode / CC Switch 中使用 MiniMax、MiMo、Kimi、Codex）
        if p.contains("minimax") || m.contains("minimax") {
            return .minimax
        }
        if p.contains("xiaomi") || p.contains("mimo") || m.contains("mimo-") || m.hasPrefix("mimo") {
            return .mimo
        }
        if p.contains("moonshot") || p.contains("kimi") || m.contains("kimi")
            || m == "k3" || m.hasPrefix("k3-") || m.hasPrefix("k3.")
            || m.hasPrefix("k2.") || m.hasPrefix("k2p") {
            return .kimi
        }
        if m.contains("codex") {
            return .codex
        }

        return nil
    }
}

// MARK: - Account Configuration

enum AccountSource: String, Codable, Sendable, Equatable {
    case autoDiscovered = "auto"
    case manual = "manual"
}

enum AccountAuthKind: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    case apiKey = "apiKey"
    case oauthToken = "oauthToken"
    case cookie = "cookie"
    case localOnly = "localOnly"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiKey: return "API Key / Token"
        case .oauthToken: return "OAuth 凭证 / Refresh Token"
        case .cookie: return "控制台 Cookie"
        case .localOnly: return "仅本地日志目录"
        }
    }
}

/// 单个平台账号配置（持久化于配置文件，敏感密钥存储在 KeychainStore）
struct ProviderAccountConfig: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var provider: TrackedProvider
    var label: String
    var source: AccountSource
    var authKind: AccountAuthKind
    var isEnabled: Bool
    /// 区域标识（如 "cn" / "global"）或自定义 API Base URL
    var regionOrBaseURL: String?
    /// 平台侧账号唯一标识（如 chatgpt_account_id、Kimi user_id、Google email、MiMo uid）
    var externalAccountId: String?
    /// 本机自动发现时的源凭证文件路径
    var credentialFilePath: String?
    /// 源凭证文件中的子键（例如 codex_oauth_auth.json 的 account key 或 auth.json 的 provider key）
    var credentialLookupKey: String?
    /// 来源描述（如 "CC Switch"、"~/.codex"、"手动添加"）
    var originDescription: String?
    /// 绑定的独立本地日志/配置目录路径（可选）
    var customLogPath: String?

    init(
        id: String = UUID().uuidString,
        provider: TrackedProvider,
        label: String,
        source: AccountSource,
        authKind: AccountAuthKind,
        isEnabled: Bool = true,
        regionOrBaseURL: String? = nil,
        externalAccountId: String? = nil,
        credentialFilePath: String? = nil,
        credentialLookupKey: String? = nil,
        originDescription: String? = nil,
        customLogPath: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.source = source
        self.authKind = authKind
        self.isEnabled = isEnabled
        self.regionOrBaseURL = regionOrBaseURL
        self.externalAccountId = externalAccountId
        self.credentialFilePath = credentialFilePath
        self.credentialLookupKey = credentialLookupKey
        self.originDescription = originDescription
        self.customLogPath = customLogPath
    }
}

/// 用户对自动发现账号的本地覆盖项（改名、启停、绑定独立日志目录、区域覆盖等）
struct AccountOverride: Codable, Sendable, Equatable {
    var customLabel: String?
    var isEnabled: Bool?
    var customLogPath: String?
    var regionOrBaseURL: String?
}

// MARK: - Quota & Usage Snapshots

struct QuotaWindow: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var label: String
    /// 已使用百分比（0...100）
    var usedPercent: Double
    /// 附加数值说明（例如 "14.9B / 38B"、"已用 24 / 100"、"剩余 92%"）
    var detailText: String?
    /// 额度重置时间
    var resetAt: Date?
    /// 是否为不限额窗口
    var isUnlimited: Bool

    init(
        id: String,
        label: String,
        usedPercent: Double,
        detailText: String? = nil,
        resetAt: Date? = nil,
        isUnlimited: Bool = false
    ) {
        self.id = id
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.detailText = detailText
        self.resetAt = resetAt
        self.isUnlimited = isUnlimited
    }

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    func effectiveRemainingPercent(at now: Date = Date()) -> Double {
        if isUnlimited { return 100.0 }
        if let resetAt, resetAt <= now { return 100.0 }
        return remainingPercent
    }
}

struct TokenBreakdownSnapshot: Codable, Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0

    var totalInput: Int {
        input + cacheRead + cacheWrite
    }

    var totalTokens: Int {
        input + output + cacheRead + cacheWrite + reasoning
    }

    var cacheHitPercent: Double {
        let totalIn = totalInput
        guard totalIn > 0 else { return 0 }
        return Double(cacheRead) / Double(totalIn) * 100.0
    }

    mutating func merge(_ other: TokenBreakdownSnapshot) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        reasoning += other.reasoning
    }
}

struct AccountUsageSnapshot: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var provider: TrackedProvider
    var label: String
    var sourceBadge: String
    var planBadge: String?
    var quotaWindows: [QuotaWindow]
    var quotaStatusMessage: String?
    var quotaError: String?
    var hasCustomConsoleAuth: Bool
    var isActiveSystemAccount: Bool = false
    var canSwitchSystemAccount: Bool = false
    var walletBalanceText: String? = nil
    var resetCreditsText: String? = nil
    var todayTokens: Int
    var todayCost: Double
    var allTimeTokens: Int
    var allTimeCost: Double
    var todayBreakdown: TokenBreakdownSnapshot? = nil
    var allTimeBreakdown: TokenBreakdownSnapshot? = nil
    var tokensPerSecond: Double? = nil
    var latestTokensPerSecond: Double? = nil
    var speedIsToday: Bool = true
    var updatedAt: Date
}

struct ProviderGroupSnapshot: Codable, Sendable, Identifiable, Equatable {
    var id: String { provider.rawValue }
    var provider: TrackedProvider
    var accounts: [AccountUsageSnapshot]
    var todayTokens: Int
    var todayCost: Double
    var allTimeTokens: Int
    var allTimeCost: Double
    var todayBreakdown: TokenBreakdownSnapshot? = nil
    var allTimeBreakdown: TokenBreakdownSnapshot? = nil
    var tokensPerSecond: Double? = nil
    var latestTokensPerSecond: Double? = nil
    var speedIsToday: Bool = true

    /// 用于右侧边缘停靠条 (Edge Dock) 展示该平台当前剩余配额环形图百分比（0...100）
    var representativeRemainingPercent: Double? {
        let now = Date()
        let activeCandidates: [AccountUsageSnapshot]
        if provider == .antigravity {
            activeCandidates = accounts.filter {
                !$0.quotaWindows.isEmpty && ($0.isActiveSystemAccount || $0.sourceBadge == "Antigravity IDE")
            }
        } else {
            activeCandidates = accounts.filter { $0.isActiveSystemAccount && !$0.quotaWindows.isEmpty }
        }
        let sourceAccounts = activeCandidates.isEmpty
            ? accounts.filter { !$0.quotaWindows.isEmpty }
            : activeCandidates
        let finiteWindows = sourceAccounts.flatMap { $0.quotaWindows.filter { !$0.isUnlimited } }
        guard !finiteWindows.isEmpty else {
            let hasUnlimited = sourceAccounts.contains { $0.quotaWindows.contains(where: \.isUnlimited) }
            return hasUnlimited ? 100.0 : nil
        }

        // Antigravity 仅看 Gemini 配额池，忽略 Claude / GPT 配额池
        if provider == .antigravity {
            let geminiWindows = finiteWindows.filter { window in
                let idLower = window.id.lowercased()
                let labelLower = window.label.lowercased()
                let isClaudeOrGPT = idLower.contains("claude") || idLower.contains("gpt")
                    || labelLower.contains("claude") || labelLower.contains("gpt")
                guard !isClaudeOrGPT else { return false }
                return idLower.contains("gemini") || labelLower.contains("gemini") || idLower.contains("argon")
            }
            if !geminiWindows.isEmpty {
                return geminiWindows.map { $0.effectiveRemainingPercent(at: now) }.min()
            }
        }

        return finiteWindows.map { $0.effectiveRemainingPercent(at: now) }.min()
    }
}

enum SpeedFormatter {
    static func format(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f tok/s", value)
        }
        return String(format: "%.1f tok/s", value)
    }

    static func tooltip(average: Double, latest: Double?, isToday: Bool) -> String {
        let scope = isToday ? "今日平均生成速率" : "近 90 天平均生成速率"
        let avgStr = average >= 100 ? String(format: "%.0f", average) : String(format: "%.1f", average)
        if let latest, latest > 0 {
            let latestStr = latest >= 100 ? String(format: "%.0f", latest) : String(format: "%.1f", latest)
            return "\(scope) \(avgStr) tok/s · 最近一轮 \(latestStr) tok/s（按输出 + 思考 Token 实测耗时计算）"
        }
        return "\(scope) \(avgStr) tok/s（按输出 + 思考 Token 实测耗时计算）"
    }
}

struct MultiAccountDashboard: Codable, Sendable, Equatable {
    var providers: [ProviderGroupSnapshot]
    var totalTodayTokens: Int
    var totalTodayCost: Double
    var totalAllTimeTokens: Int
    var totalAllTimeCost: Double
    var totalTodayBreakdown: TokenBreakdownSnapshot? = nil
    var totalAllTimeBreakdown: TokenBreakdownSnapshot? = nil
    var updatedAt: Date

    var totalActiveAccounts: Int {
        providers.reduce(0) { $0 + $1.accounts.count }
    }
}

// MARK: - Bundled Brand Icon Loader

@MainActor
enum ProviderBrandIconCache {
    private static var cache: [TrackedProvider: NSImage] = [:]

    /// 安全解析打包资源 URL（绝不调用在重定位 `.app` 上可能触发 `fatalError` 的 `Bundle.module`），
    /// 同时兼容 SwiftPM Classic 扁平 `.bundle`、SwiftBuild `Contents/Resources/` 嵌套 `.bundle` 与 `swift run`。
    static func bundledResourceURL(name: String, ext: String) -> URL? {
        let bundleFilenames = ["TokenUse_TokenUse.bundle"]
        let baseDirs: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent(),
        ]

        for case let dir? in baseDirs {
            for bName in bundleFilenames {
                let bURL = dir.appendingPathComponent(bName)
                if let resBundle = Bundle(url: bURL),
                   let found = resBundle.url(forResource: name, withExtension: ext) {
                    return found
                }
                let nested = bURL.appendingPathComponent("Contents/Resources/\(name).\(ext)")
                if FileManager.default.fileExists(atPath: nested.path) {
                    return nested
                }
                let flat = bURL.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: flat.path) {
                    return flat
                }
            }
        }

        if let mainFound = Bundle.main.url(forResource: name, withExtension: ext) {
            return mainFound
        }
        return nil
    }

    static func image(for provider: TrackedProvider) -> NSImage? {
        if let hit = cache[provider] {
            return hit
        }
        if let url = bundledResourceURL(name: provider.iconResourceName, ext: "png"),
           let img = NSImage(contentsOf: url) {
            cache[provider] = img
            return img
        }
        return nil
    }
}

struct ProviderBrandIcon: View {
    let provider: TrackedProvider
    var size: CGFloat = 16
    var cornerRadius: CGFloat = 4

    var body: some View {
        if let nsImage = ProviderBrandIconCache.image(for: provider) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            Image(systemName: provider.systemIcon)
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(provider.accentColor)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Reset Time Formatting

enum ResetFormatter {
    static func format(_ resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let diff = resetAt.timeIntervalSince(now)
        if diff <= 0 {
            return "即将重置"
        }
        let totalMinutes = Int(diff / 60)
        if totalMinutes < 60 {
            return "\(max(1, totalMinutes))m 后重置"
        }
        let totalHours = totalMinutes / 60
        let remMinutes = totalMinutes % 60
        if totalHours < 48 {
            return remMinutes > 0 ? "\(totalHours)h \(remMinutes)m 后重置" : "\(totalHours)h 后重置"
        }
        let days = totalHours / 24
        let remHours = totalHours % 24
        if days <= 14 {
            return remHours > 0 ? "\(days)d \(remHours)h 后重置" : "\(days)d 后重置"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(formatter.string(from: resetAt)) 重置"
    }
}
