import SwiftUI
import Combine

// MARK: - AppState
/// 全局应用状态管理（@MainActor）
/// - 启动秒开：存在有效快照时立即渲染（不清空今日数据），随后后台静默同步最新配额与日志
/// - 主动刷新与定时刷新：始终执行真实扫描与在线配额拉取（修复原 1 小时内刷新无效与今日闪零问题）
/// - 协调 AccountDiscoveryService、NativeUsageService、ProviderQuotaService 与 ReportManager

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var dashboard: MultiAccountDashboard?
    @Published var stats: TokenStats?
    @Published var discoveredAccounts: [ProviderAccountConfig] = []
    @Published var activeCodexAccountIds: Set<String> = []
    @Published var switchingAccountId: String? = nil
    @Published var errorMessage: String?
    @Published var statusMessage: String = "正在初始化..."
    @Published var isLoading: Bool = false

    private let nativeUsageService = NativeUsageService.shared
    private let quotaService = ProviderQuotaService.shared
    private let reportManager = ReportManager.shared

    private var timer: Timer?
    private var hasStarted = false
    private var isRefreshingLocalOnly = false
    private var lastQuotaResults: [String: ProviderQuotaResult] = [:]
    private let dashboardCacheFilename = "dashboard-v3.json"

    private init() {}

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        DebugLogger.log("🚀 [AppState] start() 开始")
        reloadAccountList()

        SessionActivityMonitor.shared.onSessionTurnFinished = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshLocalUsageOnly()
            }
        }
        SessionActivityMonitor.shared.start { [weak self] in
            self?.discoveredAccounts ?? []
        }

        // 1. 若有 1 小时内的多账号快照，先瞬时展示（保留缓存中的今日数据与配额，绝不置零闪烁），再后台刷新
        if let cached = await reportManager.loadSnapshot(
            MultiAccountDashboard.self,
            filename: dashboardCacheFilename,
            maxAge: 3600
        ) {
            self.dashboard = cached
            statusMessage = "已加载缓存，正在同步最新配额..."
            startTimer()
            Task {
                await performSync(showBlockingSpinner: false)
            }
            return
        }

        await performSync(showBlockingSpinner: true)
        startTimer()
    }

    /// 手动点击刷新或设置变更后调用：强制执行完整本地扫描 + 在线配额查询
    func refresh() async {
        reloadAccountList()
        await performSync(showBlockingSpinner: dashboard == nil)
    }

    /// 当本地会话刚结束一轮生成时触发：仅增量刷新本地日志 Token 与 tok/s，复用最近一次在线配额结果，避免频繁请求远端接口
    func refreshLocalUsageOnly() async {
        guard !isLoading, !isRefreshingLocalOnly, !lastQuotaResults.isEmpty else { return }
        isRefreshingLocalOnly = true
        defer { isRefreshingLocalOnly = false }

        let settings = SettingsManager.shared
        let manualAccounts = settings.manualAccounts
        let overrides = settings.accountOverrides
        let autoEnabled = settings.enableAutoDiscovery

        let bundle = await Task.detached(priority: .utility) {
            AccountDiscoveryService.resolveAccounts(
                manualAccounts: manualAccounts,
                overrides: overrides,
                enableAutoDiscovery: autoEnabled
            )
        }.value

        self.discoveredAccounts = bundle.allAccounts
        self.activeCodexAccountIds = bundle.activeCodexAccountIds
        let enabledAccounts = bundle.enabledAccounts

        let dynamicModels = await quotaService.modelMapForAntigravity()
        let localUsage = await nativeUsageService.fetchCombined(
            accounts: enabledAccounts,
            dynamicAntigravityModels: dynamicModels
        )

        guard !isLoading else { return }
        let now = Date()
        let builtDashboard = buildDashboard(
            enabledAccounts: enabledAccounts,
            activeCodexAccountIds: bundle.activeCodexAccountIds,
            localUsage: localUsage,
            quotaResults: lastQuotaResults,
            updatedAt: now
        )
        self.dashboard = builtDashboard
        self.stats = TokenStats(
            allTime: localUsage.allTimeReport,
            today: localUsage.todayReport,
            updatedAt: now
        )
        try? await reportManager.saveSnapshot(builtDashboard, filename: dashboardCacheFilename)
    }

    /// 一键切换本机 `$CODEX_HOME/auth.json` 当前活跃的 Codex OAuth 账号
    func switchActiveCodexAccount(_ accountId: String) async {
        guard switchingAccountId == nil else { return }
        switchingAccountId = accountId
        errorMessage = nil
        statusMessage = "正在切换系统活跃 Codex 账号..."
        defer { switchingAccountId = nil }

        let settings = SettingsManager.shared
        let bundle = AccountDiscoveryService.resolveAccounts(
            manualAccounts: settings.manualAccounts,
            overrides: settings.accountOverrides,
            enableAutoDiscovery: settings.enableAutoDiscovery
        )
        guard let target = bundle.allAccounts.first(where: { $0.id == accountId }) else {
            errorMessage = "未找到目标 Codex 账号"
            return
        }

        do {
            try await CodexAccountSwitchService.switchActiveSystemAccount(to: target)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "切换 Codex 账号失败"
        }
    }

    /// 仅重新扫描本机账号列表（供设置页即时反馈使用）
    func reloadAccountList() {
        let settings = SettingsManager.shared
        let bundle = AccountDiscoveryService.resolveAccounts(
            manualAccounts: settings.manualAccounts,
            overrides: settings.accountOverrides,
            enableAutoDiscovery: settings.enableAutoDiscovery
        )
        self.discoveredAccounts = bundle.allAccounts
        self.activeCodexAccountIds = bundle.activeCodexAccountIds
    }

    private func performSync(showBlockingSpinner: Bool) async {
        isLoading = true
        if showBlockingSpinner {
            statusMessage = "正在扫描本地日志与同步各账号配额..."
        }
        errorMessage = nil

        let settings = SettingsManager.shared
        let manualAccounts = settings.manualAccounts
        let overrides = settings.accountOverrides
        let autoEnabled = settings.enableAutoDiscovery

        // 在后台并发拉取账户发现、本地日志单遍扫描、在线配额接口
        let bundle = await Task.detached(priority: .userInitiated) {
            AccountDiscoveryService.resolveAccounts(
                manualAccounts: manualAccounts,
                overrides: overrides,
                enableAutoDiscovery: autoEnabled
            )
        }.value

        self.discoveredAccounts = bundle.allAccounts
        self.activeCodexAccountIds = bundle.activeCodexAccountIds
        let enabledAccounts = bundle.enabledAccounts

        let dynamicModels = await quotaService.modelMapForAntigravity()
        let localUsage = await nativeUsageService.fetchCombined(
            accounts: enabledAccounts,
            dynamicAntigravityModels: dynamicModels
        )

        let quotaResults = await quotaService.fetchAllQuotas(
            accounts: enabledAccounts,
            ephemeralSecrets: bundle.ephemeralSecrets,
            offlineCodexSnapshots: localUsage.offlineCodexSnapshots
        )
        self.lastQuotaResults = quotaResults

        let now = Date()
        let builtDashboard = buildDashboard(
            enabledAccounts: enabledAccounts,
            activeCodexAccountIds: bundle.activeCodexAccountIds,
            localUsage: localUsage,
            quotaResults: quotaResults,
            updatedAt: now
        )

        self.dashboard = builtDashboard
        self.stats = TokenStats(
            allTime: localUsage.allTimeReport,
            today: localUsage.todayReport,
            updatedAt: now
        )

        // 异步持久化快照与全量报告缓存
        if let allTimeData = try? JSONEncoder().encode(localUsage.allTimeReport) {
            _ = try? await reportManager.saveReport(allTimeData)
        }
        try? await reportManager.saveSnapshot(builtDashboard, filename: dashboardCacheFilename)

        let timeStr = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        statusMessage = "更新于 \(timeStr)"
        isLoading = false
        DebugLogger.log("✅ [AppState] 同步完成: \(builtDashboard.totalActiveAccounts) 个活跃账号")
    }

    private func resolveSpeed(
        today: SpeedSampleAccumulator,
        allTime: SpeedSampleAccumulator
    ) -> (avg: Double?, latest: Double?, isToday: Bool) {
        if let todayAvg = today.averageTokensPerSecond {
            return (todayAvg, today.latestTokensPerSecond ?? allTime.latestTokensPerSecond, true)
        }
        if let allAvg = allTime.averageTokensPerSecond {
            return (allAvg, allTime.latestTokensPerSecond, false)
        }
        return (nil, nil, true)
    }

    private func buildDashboard(
        enabledAccounts: [ProviderAccountConfig],
        activeCodexAccountIds: Set<String>,
        localUsage: CombinedLocalUsageResult,
        quotaResults: [String: ProviderQuotaResult],
        updatedAt: Date
    ) -> MultiAccountDashboard {
        var providerGroups: [ProviderGroupSnapshot] = []
        var grandTodayBreakdown = TokenBreakdownSnapshot()
        var grandAllTimeBreakdown = TokenBreakdownSnapshot()

        for provider in TrackedProvider.allCases {
            let pAccounts = enabledAccounts.filter { $0.provider == provider }
            var snapshots: [AccountUsageSnapshot] = []
            var seenExternalIndex: [String: Int] = [:]
            var mergedSpeedByIndex: [Int: (today: SpeedSampleAccumulator, allTime: SpeedSampleAccumulator)] = [:]

            for acct in pAccounts {
                let q = quotaResults[acct.id]
                let acctToday = localUsage.perAccountToday[acct.id] ?? UsageTotals()
                let acctAllTime = localUsage.perAccountAllTime[acct.id] ?? UsageTotals()
                let isActiveSystem = (provider == .codex) && activeCodexAccountIds.contains(acct.id)
                let canSwitchSystem = (provider == .codex) && (acct.authKind == .oauthToken) && !isActiveSystem

                let effectiveLabel: String = {
                    // 若用户没有自定义改名且账号处于默认目录名，可用接口返回的昵称/邮箱美化
                    let hasOverrideLabel = SettingsManager.shared.accountOverrides[acct.id]?.customLabel != nil
                    if acct.source == .autoDiscovered, !hasOverrideLabel,
                       let resolved = q?.resolvedLabel, !resolved.isEmpty,
                       (acct.label.hasPrefix("Kimi Code (")
                        || acct.label.hasPrefix("Xiaomi MiMo")
                        || acct.label.contains("本机")) {
                        return resolved
                    }
                    return acct.label
                }()

                let sourceBadge = acct.originDescription ?? (acct.source == .manual ? "手动添加" : "自动发现")
                let dedupExternalKey = (q?.resolvedExternalId ?? acct.externalAccountId)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                // 若两个自动发现账号指向同一个远端账号 ID（例如 ~/.kimi 与 ~/.kimi-code 同登录），自动合并本地 Token 防止重复卡片
                if acct.source == .autoDiscovered,
                   let key = dedupExternalKey, !key.isEmpty,
                   let existingIdx = seenExternalIndex[key] {
                    snapshots[existingIdx].todayTokens += acctToday.tokens
                    snapshots[existingIdx].todayCost += acctToday.cost
                    snapshots[existingIdx].allTimeTokens += acctAllTime.tokens
                    snapshots[existingIdx].allTimeCost += acctAllTime.cost

                    if acctToday.tokens > 0 {
                        var mergedToday = snapshots[existingIdx].todayBreakdown ?? TokenBreakdownSnapshot()
                        mergedToday.merge(acctToday.breakdown)
                        snapshots[existingIdx].todayBreakdown = mergedToday
                    }
                    if acctAllTime.tokens > 0 {
                        var mergedAll = snapshots[existingIdx].allTimeBreakdown ?? TokenBreakdownSnapshot()
                        mergedAll.merge(acctAllTime.breakdown)
                        snapshots[existingIdx].allTimeBreakdown = mergedAll
                    }

                    var speedPair = mergedSpeedByIndex[existingIdx] ?? (SpeedSampleAccumulator(), SpeedSampleAccumulator())
                    speedPair.today.merge(acctToday.speed)
                    speedPair.allTime.merge(acctAllTime.speed)
                    mergedSpeedByIndex[existingIdx] = speedPair
                    let resolvedMergedSpeed = resolveSpeed(today: speedPair.today, allTime: speedPair.allTime)
                    snapshots[existingIdx].tokensPerSecond = resolvedMergedSpeed.avg
                    snapshots[existingIdx].latestTokensPerSecond = resolvedMergedSpeed.latest
                    snapshots[existingIdx].speedIsToday = resolvedMergedSpeed.isToday

                    let mergedActive = snapshots[existingIdx].isActiveSystemAccount || isActiveSystem
                    snapshots[existingIdx].isActiveSystemAccount = mergedActive
                    if provider == .codex {
                        snapshots[existingIdx].canSwitchSystemAccount = !mergedActive
                            && (snapshots[existingIdx].canSwitchSystemAccount || acct.authKind == .oauthToken)
                    }

                    if snapshots[existingIdx].quotaWindows.isEmpty, let wins = q?.windows, !wins.isEmpty {
                        snapshots[existingIdx].quotaWindows = wins
                    }
                    if snapshots[existingIdx].planBadge == nil {
                        snapshots[existingIdx].planBadge = q?.planBadge
                    }
                    if snapshots[existingIdx].walletBalanceText == nil {
                        snapshots[existingIdx].walletBalanceText = q?.walletBalanceText
                    }
                    if snapshots[existingIdx].resetCreditsText == nil {
                        snapshots[existingIdx].resetCreditsText = q?.resetCreditsText
                    }
                    continue
                }

                let acctSpeed = resolveSpeed(today: acctToday.speed, allTime: acctAllTime.speed)
                let snap = AccountUsageSnapshot(
                    id: acct.id,
                    provider: provider,
                    label: effectiveLabel,
                    sourceBadge: sourceBadge,
                    planBadge: q?.planBadge,
                    quotaWindows: q?.windows ?? [],
                    quotaStatusMessage: q?.statusMessage,
                    quotaError: q?.errorMessage,
                    hasCustomConsoleAuth: q?.hasCustomConsoleAuth ?? false,
                    isActiveSystemAccount: isActiveSystem,
                    canSwitchSystemAccount: canSwitchSystem,
                    walletBalanceText: q?.walletBalanceText,
                    resetCreditsText: q?.resetCreditsText,
                    todayTokens: acctToday.tokens,
                    todayCost: acctToday.cost,
                    allTimeTokens: acctAllTime.tokens,
                    allTimeCost: acctAllTime.cost,
                    todayBreakdown: acctToday.tokens > 0 ? acctToday.breakdown : nil,
                    allTimeBreakdown: acctAllTime.tokens > 0 ? acctAllTime.breakdown : nil,
                    tokensPerSecond: acctSpeed.avg,
                    latestTokensPerSecond: acctSpeed.latest,
                    speedIsToday: acctSpeed.isToday,
                    updatedAt: updatedAt
                )
                let newIndex = snapshots.count
                mergedSpeedByIndex[newIndex] = (acctToday.speed, acctAllTime.speed)
                if acct.source == .autoDiscovered, let key = dedupExternalKey, !key.isEmpty {
                    seenExternalIndex[key] = newIndex
                }
                snapshots.append(snap)
            }

            // 若已存在活跃的 ~/.kimi-code (v2) 账号，且旧版遗留 ~/.kimi (v1) 90 天内无任何日志且凭证已失效，默认隐藏废弃幽灵卡片（除非用户显式开启）
            if provider == .kimi,
               snapshots.contains(where: { !$0.quotaWindows.isEmpty }) {
                snapshots.removeAll { snap in
                    let explicitOverride = SettingsManager.shared.accountOverrides[snap.id]?.isEnabled == true
                    return !explicitOverride
                        && snap.sourceBadge == "~/.kimi"
                        && snap.todayTokens == 0
                        && snap.allTimeTokens == 0
                        && snap.quotaWindows.isEmpty
                        && snap.quotaError != nil
                }
            }

            let providerToday = localUsage.perProviderToday[provider] ?? UsageTotals()
            let providerAllTime = localUsage.perProviderAllTime[provider] ?? UsageTotals()
            grandTodayBreakdown.merge(providerToday.breakdown)
            grandAllTimeBreakdown.merge(providerAllTime.breakdown)
            let providerSpeed = resolveSpeed(today: providerToday.speed, allTime: providerAllTime.speed)

            providerGroups.append(ProviderGroupSnapshot(
                provider: provider,
                accounts: snapshots,
                todayTokens: providerToday.tokens,
                todayCost: providerToday.cost,
                allTimeTokens: providerAllTime.tokens,
                allTimeCost: providerAllTime.cost,
                todayBreakdown: providerToday.tokens > 0 ? providerToday.breakdown : nil,
                allTimeBreakdown: providerAllTime.tokens > 0 ? providerAllTime.breakdown : nil,
                tokensPerSecond: providerSpeed.avg,
                latestTokensPerSecond: providerSpeed.latest,
                speedIsToday: providerSpeed.isToday
            ))
        }

        let totalTodayTokens = providerGroups.reduce(0) { $0 + $1.todayTokens }
        let totalTodayCost = providerGroups.reduce(0.0) { $0 + $1.todayCost }
        let totalAllTimeTokens = providerGroups.reduce(0) { $0 + $1.allTimeTokens }
        let totalAllTimeCost = providerGroups.reduce(0.0) { $0 + $1.totalAllTimeCostFragment }

        return MultiAccountDashboard(
            providers: providerGroups,
            totalTodayTokens: totalTodayTokens,
            totalTodayCost: totalTodayCost,
            totalAllTimeTokens: totalAllTimeTokens,
            totalAllTimeCost: totalAllTimeCost,
            totalTodayBreakdown: totalTodayTokens > 0 ? grandTodayBreakdown : nil,
            totalAllTimeBreakdown: totalAllTimeTokens > 0 ? grandAllTimeBreakdown : nil,
            updatedAt: updatedAt
        )
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let interval = SettingsManager.shared.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func restartTimer() {
        startTimer()
    }
}

private extension ProviderGroupSnapshot {
    var totalAllTimeCostFragment: Double { allTimeCost }
}
