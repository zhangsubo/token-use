import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState.shared

    var body: some View {
        TokenDashboardContent(appState: appState, showsHandle: false)
            .frame(width: 644, height: 670)
    }
}

private struct SettingsLaunchConfig: Identifiable {
    let id = UUID()
    var initialTab: SettingsTab
    var initialAddingProvider: TrackedProvider?
}

struct TokenDashboardContent: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var edgeManager = EdgeWindowManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared

    @State private var selectedProvider: TrackedProvider? = nil
    @State private var settingsLaunch: SettingsLaunchConfig? = nil
    @State private var xiaomiLoginAccount: ProviderAccountConfig? = nil

    let showsHandle: Bool
    var refreshAction: (() -> Void)?

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.34, green: 0.41, blue: 0.58).opacity(0.46),
                            Color(.sRGB, red: 0.18, green: 0.23, blue: 0.36).opacity(0.58)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.20),
                            .white.opacity(0.05),
                            .black.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.40), .white.opacity(0.10), .black.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(0.5)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                .padding(7)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showsHandle {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: 32, height: 3)
                        .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
                        .padding(.top, 8)
                }

                headerBar
                    .padding(.horizontal, 22)
                    .padding(.top, showsHandle ? 8 : 20)
                    .padding(.bottom, 10)

                dividerLine
                    .padding(.bottom, 10)

                if let dashboard = appState.dashboard {
                    summaryStrip(dashboard: dashboard)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 10)

                    providerFilterBar(dashboard: dashboard)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredGroups(from: dashboard)) { group in
                                ProviderSectionCard(
                                    group: group,
                                    isSessionActive: activityMonitor.activeProviders.contains(group.provider),
                                    showEstimatedCost: settings.showEstimatedCost,
                                    switchingAccountId: appState.switchingAccountId,
                                    onAddAccount: {
                                        openSettings(tab: .accounts, adding: group.provider)
                                    },
                                    onBindXiaomiCookie: { accountId in
                                        if let cfg = appState.discoveredAccounts.first(where: { $0.id == accountId }) {
                                            EdgeWindowManager.shared.isModalPresenting = true
                                            xiaomiLoginAccount = cfg
                                        } else {
                                            openSettings(tab: .accounts, adding: nil)
                                        }
                                    },
                                    onSwitchCodexAccount: { accountId in
                                        Task { await appState.switchActiveCodexAccount(accountId) }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                    }

                    footerBar(updatedAt: dashboard.updatedAt)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                } else if let error = appState.errorMessage {
                    Spacer()
                    EmptyStateCard {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Button("立即重试") {
                            Task { await appState.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(width: 560)
                    Spacer()
                } else {
                    Spacer()
                    EmptyStateCard {
                        ProgressView()
                            .controlSize(.large)
                        Text(appState.statusMessage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                    .frame(width: 560)
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(
            item: $settingsLaunch,
            onDismiss: {
                EdgeWindowManager.shared.isModalPresenting = false
            }
        ) { config in
            SettingsView(
                initialTab: config.initialTab,
                initialAddingProvider: config.initialAddingProvider
            )
        }
        .sheet(
            item: $xiaomiLoginAccount,
            onDismiss: {
                EdgeWindowManager.shared.isModalPresenting = false
            }
        ) { account in
            XiaomiConsoleLoginSheet(accountLabel: account.label) { cookie in
                if account.source == .manual {
                    try? settings.saveManualAccount(account, secret: nil, consoleCookie: cookie)
                } else {
                    let existing = settings.accountOverrides[account.id]
                    try? settings.updateDiscoveredAccountOverride(
                        accountID: account.id,
                        customLabel: existing?.customLabel,
                        isEnabled: existing?.isEnabled,
                        customLogPath: existing?.customLogPath,
                        regionOrBaseURL: existing?.regionOrBaseURL,
                        consoleCookie: cookie
                    )
                }
                Task { await appState.refresh() }
            }
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.sRGB, red: 0.424, green: 0.635, blue: 1.0),
                                Color(.sRGB, red: 0.208, green: 0.427, blue: 0.922)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.32), lineWidth: 0.8)
                    )
                    .shadow(color: Color(.sRGB, red: 0.078, green: 0.176, blue: 0.392).opacity(0.28), radius: 8, x: 0, y: 4)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("TokenUse")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)

                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.85)
                    }
                }

                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                HeaderActionButton(
                    systemName: edgeManager.isPinned ? "pin.fill" : "pin",
                    help: edgeManager.isPinned ? "取消固定面板" : "固定面板（移开鼠标不自动收起）",
                    isActive: edgeManager.isPinned
                ) {
                    edgeManager.isPinned.toggle()
                }

                HeaderActionButton(
                    systemName: "plus",
                    help: "添加平台账号"
                ) {
                    openSettings(tab: .accounts, adding: selectedProvider ?? settings.providerOrder.first ?? .codex)
                }

                HeaderActionButton(
                    systemName: "arrow.clockwise",
                    help: "立即刷新本地日志与在线配额",
                    isDisabled: appState.isLoading
                ) {
                    if let refreshAction {
                        refreshAction()
                    } else {
                        Task { await appState.refresh() }
                    }
                }

                HeaderActionButton(systemName: "gearshape", help: "多账号与常规设置") {
                    openSettings(tab: .accounts, adding: nil)
                }

                HeaderActionButton(systemName: "xmark", help: "退出 TokenUse", role: .close) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if appState.isLoading {
            return "正在同步 5 大平台本地日志与实时配额..."
        }
        if let dashboard = appState.dashboard {
            return "5 大平台 · \(dashboard.totalActiveAccounts) 个已启用账号"
        }
        return appState.statusMessage
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 596, height: 1)
    }

    private func summaryStrip(dashboard: MultiAccountDashboard) -> some View {
        HStack(spacing: 10) {
            CompactMetricCard(
                title: "今日消耗 (Today)",
                icon: "sun.max.fill",
                accent: Color(.sRGB, red: 0.38, green: 0.76, blue: 1.0),
                tokensText: NumberFormatterUtil.format(dashboard.totalTodayTokens),
                costText: settings.showEstimatedCost ? NumberFormatterUtil.formatCurrency(dashboard.totalTodayCost) : nil,
                breakdown: dashboard.totalTodayBreakdown
            )

            CompactMetricCard(
                title: "近 90 天累计 (90d)",
                icon: "chart.bar.xaxis",
                accent: Color(.sRGB, red: 0.56, green: 0.88, blue: 0.68),
                tokensText: NumberFormatterUtil.format(dashboard.totalAllTimeTokens),
                costText: settings.showEstimatedCost ? NumberFormatterUtil.formatCurrency(dashboard.totalAllTimeCost) : nil,
                breakdown: dashboard.totalAllTimeBreakdown
            )

            WorkingMascotBadgeView()
                .frame(width: 68, height: 68)
                .help("可在「设置 → 常规与更新」中更换自定义吉祥物或 GIF")
        }
    }

    private func providerFilterBar(dashboard: MultiAccountDashboard) -> some View {
        HStack(spacing: 6) {
            FilterChipButton(
                title: "全部",
                icon: "square.grid.2x2.fill",
                provider: nil,
                badgeCount: dashboard.totalActiveAccounts,
                accent: .white,
                isSelected: selectedProvider == nil
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedProvider = nil
                }
            }

            ForEach(settings.providerOrder) { provider in
                let count = dashboard.providers.first(where: { $0.provider == provider })?.accounts.count ?? 0
                FilterChipButton(
                    title: provider.shortName,
                    icon: provider.systemIcon,
                    provider: provider,
                    badgeCount: count,
                    accent: provider.accentColor,
                    isSelected: selectedProvider == provider
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedProvider = (selectedProvider == provider) ? nil : provider
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func filteredGroups(from dashboard: MultiAccountDashboard) -> [ProviderGroupSnapshot] {
        let ordered = settings.providerOrder.compactMap { provider in
            dashboard.providers.first(where: { $0.provider == provider })
        }
        guard let selectedProvider else {
            return ordered
        }
        return ordered.filter { $0.provider == selectedProvider }
    }

    private func footerBar(updatedAt: Date) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .medium))
                Text(formattedTime(updatedAt))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.68))

            Spacer()

            if settings.showEstimatedCost {
                HStack(spacing: 4) {
                    Text("* 本地会话日志 + 在线套餐配额双轨统计 · 定价参考")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("LiteLLM")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .onTapGesture {
                            if let url = URL(string: "https://github.com/BerriAI/litellm") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                }
            } else {
                Text("* 本地会话日志 + 在线套餐配额双轨统计")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.6)
                )
        )
    }

    private func openSettings(tab: SettingsTab, adding provider: TrackedProvider?) {
        EdgeWindowManager.shared.isModalPresenting = true
        settingsLaunch = SettingsLaunchConfig(initialTab: tab, initialAddingProvider: provider)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}

// MARK: - Top Summary Cards & Filter Chips

private struct CompactMetricCard: View {
    let title: String
    let icon: String
    let accent: Color
    let tokensText: String
    let costText: String?
    let breakdown: TokenBreakdownSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer(minLength: 0)
                if let costText {
                    Text(costText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(.sRGB, red: 0.44, green: 0.94, blue: 0.68))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(.sRGB, red: 0.16, green: 0.56, blue: 0.38).opacity(0.32))
                                .overlay(
                                    Capsule()
                                        .stroke(Color(.sRGB, red: 0.44, green: 0.94, blue: 0.68).opacity(0.28), lineWidth: 0.6)
                                )
                        )
                        .help("按 API 单价折算等效价值")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(tokensText)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("Tokens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))

                Spacer(minLength: 0)

                if let b = breakdown, b.totalTokens > 0 {
                    Text(String(format: "缓存 %.0f%%", b.cacheHitPercent))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.11), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                )
        )
    }
}

private struct FilterChipButton: View {
    let title: String
    let icon: String
    let provider: TrackedProvider?
    let badgeCount: Int
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let provider {
                    ProviderBrandIcon(provider: provider, size: 13, cornerRadius: 3)
                        .opacity(isSelected ? 1.0 : 0.82)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .white.opacity(0.65))
                }

                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.72))

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? accent.opacity(0.35) : .white.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? .white.opacity(0.18) : .white.opacity(0.06))
                    .overlay(
                        Capsule()
                            .stroke(isSelected ? accent.opacity(0.55) : .white.opacity(0.12), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Provider & Account Cards

private struct ProviderSectionCard: View {
    let group: ProviderGroupSnapshot
    let isSessionActive: Bool
    let showEstimatedCost: Bool
    let switchingAccountId: String?
    let onAddAccount: () -> Void
    let onBindXiaomiCookie: (String) -> Void
    let onSwitchCodexAccount: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Provider Header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(group.provider.accentColor.opacity(0.18))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    isSessionActive
                                        ? Color(.sRGB, red: 0.34, green: 0.94, blue: 0.66).opacity(0.75)
                                        : group.provider.accentColor.opacity(0.45),
                                    lineWidth: isSessionActive ? 1.1 : 0.8
                                )
                        )

                    ProviderBrandIcon(provider: group.provider, size: 18, cornerRadius: 4)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(group.provider.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .layoutPriority(2)

                        Text(group.provider.vendorName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.08)))
                            .lineLimit(1)

                        Text("\(group.accounts.count) 账号")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(group.provider.accentColor.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(group.provider.accentColor.opacity(0.15)))
                            .lineLimit(1)

                        if isSessionActive {
                            HStack(spacing: 3.5) {
                                Circle()
                                    .fill(Color(.sRGB, red: 0.34, green: 0.94, blue: 0.66))
                                    .frame(width: 5.5, height: 5.5)
                                Text("运行中")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(Color(.sRGB, red: 0.42, green: 0.95, blue: 0.70))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color(.sRGB, red: 0.16, green: 0.58, blue: 0.38).opacity(0.32))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color(.sRGB, red: 0.42, green: 0.95, blue: 0.70).opacity(0.40), lineWidth: 0.6)
                                    )
                            )
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if let tps = group.tokensPerSecond {
                        HStack(spacing: 2.5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(SpeedFormatter.format(tps))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color(.sRGB, red: 0.56, green: 0.88, blue: 1.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color(.sRGB, red: 0.22, green: 0.58, blue: 0.90).opacity(0.18))
                                .overlay(
                                    Capsule()
                                        .stroke(Color(.sRGB, red: 0.56, green: 0.88, blue: 1.0).opacity(0.32), lineWidth: 0.6)
                                )
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(SpeedFormatter.tooltip(average: tps, latest: group.latestTokensPerSecond, isToday: group.speedIsToday))
                    }

                    let groupCloudPeriodTokens = group.accounts.reduce(0) { $0 + ($1.cloudBilling?.periodTokens ?? 0) }
                    if group.todayTokens > 0 || group.allTimeTokens > 0 {
                        HStack(spacing: 5) {
                            Text("今日 \(NumberFormatterUtil.formatCompact(group.todayTokens))")
                                .foregroundStyle(.white.opacity(0.84))
                            Text("·")
                                .foregroundStyle(.white.opacity(0.30))
                            Text("90d \(NumberFormatterUtil.formatCompact(group.allTimeTokens))")
                                .foregroundStyle(.white.opacity(0.64))
                            if showEstimatedCost && group.allTimeCost > 0 {
                                Text(NumberFormatterUtil.formatCurrency(group.allTimeCost))
                                    .foregroundStyle(Color(.sRGB, red: 0.46, green: 0.92, blue: 0.68))
                                    .help("按 API 单价折算等效价值")
                            }
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(groupHeaderTokensTooltip)
                    } else if groupCloudPeriodTokens > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.fill")
                                .font(.system(size: 9))
                            Text("云端 \(NumberFormatterUtil.formatCompact(groupCloudPeriodTokens))")
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(.sRGB, red: 0.58, green: 0.86, blue: 1.0).opacity(0.9))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("来自官方计费接口的跨设备云端 Token 用量（本机近 90 天无本地会话日志）")
                    }

                    Button(action: onAddAccount) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(.white.opacity(0.10))
                                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("添加 \(group.provider.displayName) 账号")
                }
            }

            if group.accounts.isEmpty {
                emptyProviderRow
            } else {
                VStack(spacing: 7) {
                    ForEach(group.accounts) { account in
                        AccountQuotaCard(
                            account: account,
                            accent: group.provider.accentColor,
                            showInlineSpeed: group.accounts.count > 1,
                            showEstimatedCost: showEstimatedCost,
                            isSwitching: switchingAccountId == account.id,
                            onBindXiaomiCookie: { onBindXiaomiCookie(account.id) },
                            onSwitchCodexAccount: { onSwitchCodexAccount(account.id) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.065))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 0.8)
                )
        )
    }

    private var groupHeaderTokensTooltip: String {
        let localToday = group.localTodayTokens ?? group.todayTokens
        if group.todayTokens > localToday {
            return "今日已融合官方计费接口跨设备消耗（官方云端 \(NumberFormatterUtil.formatCompact(group.todayTokens)) · 本机会话 \(NumberFormatterUtil.formatCompact(localToday))）"
        }
        return "本机会话统计：今日 \(NumberFormatterUtil.formatCompact(group.todayTokens)) · 近 90 天 \(NumberFormatterUtil.formatCompact(group.allTimeTokens))"
    }

    private var emptyProviderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.48))

            if group.allTimeTokens > 0 {
                Text("已归集本机日志 \(NumberFormatterUtil.formatCompact(group.allTimeTokens)) Tokens · 添加凭证可查看实时套餐余额")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            } else {
                Text("暂未发现或启用 \(group.provider.shortName) 账号")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.50))
            }

            Spacer()

            Button(action: onAddAccount) {
                Text("添加账号 +")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(group.provider.accentColor.opacity(0.28))
                            .overlay(
                                Capsule()
                                    .stroke(group.provider.accentColor.opacity(0.55), lineWidth: 0.7)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.14))
        )
    }
}

private struct AccountQuotaCard: View {
    let account: AccountUsageSnapshot
    let accent: Color
    let showInlineSpeed: Bool
    let showEstimatedCost: Bool
    let isSwitching: Bool
    let onBindXiaomiCookie: () -> Void
    let onSwitchCodexAccount: () -> Void

    @State private var showBreakdown = false
    @State private var showAllModels = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
    ]

    private var modelList: [ModelUsageItem] {
        account.resolvedModelUsages
    }

    private var canExpandDetails: Bool {
        account.todayTokens > 0
            || account.allTimeTokens > 0
            || !modelList.isEmpty
            || (account.cloudBilling?.hasHeadlineActivity == true)
    }

    private var headerSummaryButtonText: String {
        if account.todayTokens > 0 || account.allTimeTokens > 0 {
            return "今日 \(NumberFormatterUtil.formatCompact(account.todayTokens)) · 90d \(NumberFormatterUtil.formatCompact(account.allTimeTokens))"
        }
        if let cb = account.cloudBilling, let pTok = cb.periodTokens, pTok > 0 {
            return "\(cb.periodLabel ?? "云端") \(NumberFormatterUtil.formatCompact(pTok))"
        }
        if let cb = account.cloudBilling, let pSpend = cb.periodSpendText, !pSpend.isEmpty {
            return "\(cb.periodLabel ?? "云端") \(pSpend)"
        }
        return "模型明细 (\(modelList.count))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Account Title + Badges + Actions + Per-Account Tokens
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6.5, height: 6.5)

                Text(account.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                Text(account.sourceBadge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .lineLimit(1)

                if let plan = account.planBadge, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(accent.opacity(0.16))
                                .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 0.6))
                        )
                        .lineLimit(1)
                }

                if account.isActiveSystemAccount {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5))
                        Text("当前使用")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color(.sRGB, red: 0.42, green: 0.94, blue: 0.68))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(Color(.sRGB, red: 0.16, green: 0.56, blue: 0.38).opacity(0.34))
                            .overlay(
                                Capsule()
                                    .stroke(Color(.sRGB, red: 0.42, green: 0.94, blue: 0.68).opacity(0.35), lineWidth: 0.6)
                            )
                    )
                    .lineLimit(1)
                } else if account.canSwitchSystemAccount {
                    Button(action: onSwitchCodexAccount) {
                        HStack(spacing: 3) {
                            if isSwitching {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                            } else {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 9))
                            }
                            Text("切换启用")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.12))
                                .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 0.6))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSwitching)
                    .help("一键将此账号切换为本机 ~/.codex/auth.json 当前活跃 Codex 账号（自动备份原登录态）")
                }

                if let wallet = account.walletBalanceText, !wallet.isEmpty {
                    Text(wallet)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(.sRGB, red: 0.62, green: 0.90, blue: 0.98))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .lineLimit(1)
                }

                if let credits = account.resetCreditsText, !credits.isEmpty {
                    Text(credits)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.07)))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if account.provider == .mimo && !account.hasCustomConsoleAuth && account.quotaWindows.isEmpty {
                    Button(action: onBindXiaomiCookie) {
                        HStack(spacing: 3) {
                            Image(systemName: "globe.badge.chevron.backward")
                                .font(.system(size: 10))
                            Text("登录查额度")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(accent.opacity(0.18))
                                .overlay(Capsule().stroke(accent.opacity(0.45), lineWidth: 0.6))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("打开隔离的小米控制台登录窗口，自动提取该账号 Cookie 查询 Token Plan 额度")
                }

                if showInlineSpeed, let acctTps = account.tokensPerSecond {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(SpeedFormatter.format(acctTps))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color(.sRGB, red: 0.56, green: 0.88, blue: 1.0).opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(SpeedFormatter.tooltip(average: acctTps, latest: account.latestTokensPerSecond, isToday: account.speedIsToday))
                }

                if canExpandDetails {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showBreakdown.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(headerSummaryButtonText)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            Image(systemName: showBreakdown ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("点击展开/收起官方计费跨端核对、分模型使用情况与缓存命中明细")
                }
            }

            // Quota Progress Windows (2-column compact grid when >= 2 windows, battery-style % left)
            if !account.quotaWindows.isEmpty {
                if account.quotaWindows.count >= 2 {
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(account.quotaWindows) { window in
                            QuotaWindowRow(window: window, providerAccent: accent)
                        }
                    }
                } else if let single = account.quotaWindows.first {
                    QuotaWindowRow(window: single, providerAccent: accent)
                }
            } else if let err = account.quotaError, !err.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange.opacity(0.9))
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.88))
                        .lineLimit(2)
                }
            } else if let msg = account.quotaStatusMessage, !msg.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)
                }
            }

            // 官方计费与多端消耗核对摘要条（存在跨端活跃度或账单记录时单行呈现，点击直接展开分模型明细）
            if let cb = account.cloudBilling, cb.hasHeadlineActivity {
                cloudBillingStrip(cb)
            }

            if showBreakdown {
                if !modelList.isEmpty {
                    modelUsagesPanel(models: modelList)
                }
                if let b = account.allTimeBreakdown ?? account.todayBreakdown, b.totalTokens > 0 {
                    tokenBreakdownFooter(breakdown: b, todayBreakdown: account.todayBreakdown)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            account.isActiveSystemAccount
                                ? Color(.sRGB, red: 0.42, green: 0.94, blue: 0.68).opacity(0.28)
                                : .white.opacity(0.08),
                            lineWidth: 0.7
                        )
                )
        )
    }

    private func cloudBillingStrip(_ cb: CloudBillingSummary) -> some View {
        let segments: [String] = {
            var parts: [String] = []
            if let tTok = cb.todayTokens, tTok > 0 {
                if let tSpend = cb.todaySpendText, !tSpend.isEmpty {
                    parts.append("今日 \(NumberFormatterUtil.formatCompact(tTok)) (\(tSpend))")
                } else {
                    parts.append("今日 \(NumberFormatterUtil.formatCompact(tTok))")
                }
            } else if let tSpend = cb.todaySpendText, !tSpend.isEmpty {
                parts.append("今日 \(tSpend)")
            }

            if let pTok = cb.periodTokens, pTok > 0 {
                let pTitle = cb.periodLabel ?? "周期"
                if let pSpend = cb.periodSpendText, !pSpend.isEmpty {
                    parts.append("\(pTitle) \(NumberFormatterUtil.formatCompact(pTok)) · \(pSpend)")
                } else {
                    parts.append("\(pTitle) \(NumberFormatterUtil.formatCompact(pTok))")
                }
            } else if let pSpend = cb.periodSpendText, !pSpend.isEmpty {
                parts.append("\(cb.periodLabel ?? "周期") \(pSpend)")
            } else if let pReq = cb.periodRequests, pReq > 0 {
                parts.append("\(cb.periodLabel ?? "请求") \(pReq) 次")
            }

            if let surf = cb.surfaceSummary, !surf.isEmpty {
                parts.append(surf)
            }
            return parts
        }()

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                showBreakdown.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.95))

                Text(cb.sourceName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: true, vertical: false)

                if !segments.isEmpty {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.28))
                    Text(segments.joined(separator: " · "))
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                if !modelList.isEmpty {
                    HStack(spacing: 2.5) {
                        Text("\(modelList.count) 个模型")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        Image(systemName: showBreakdown ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(accent.opacity(0.92))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(accent.opacity(0.18), lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("官方计费/配额接口返回的全端消耗（含其他设备、Web/App 及 API 调用），点击查看分模型明细")
    }

    private func modelUsagesPanel(models: [ModelUsageItem]) -> some View {
        let maxCollapsedCount = 6
        let visibleModels = (showAllModels || models.count <= maxCollapsedCount)
            ? models
            : Array(models.prefix(maxCollapsedCount))

        return VStack(alignment: .leading, spacing: 4.5) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.9))
                Text("分模型使用与官方计费核对")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                if let src = account.cloudBilling?.sourceName {
                    Text("\(src) + 本机日志")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("仅本机近 90 天会话日志")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            ForEach(visibleModels) { item in
                modelUsageRow(item)
            }

            if models.count > maxCollapsedCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        showAllModels.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(showAllModels ? "收起部分模型" : "查看全部 \(models.count) 个模型")
                        Image(systemName: showAllModels ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .padding(.top, 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 0.5)
                )
        )
    }

    private func modelUsageRow(_ item: ModelUsageItem) -> some View {
        let badgeColor: Color = {
            switch item.origin {
            case .officialCloud:
                return Color(.sRGB, red: 0.45, green: 0.80, blue: 1.0)
            case .merged:
                return Color(.sRGB, red: 0.40, green: 0.92, blue: 0.70)
            case .localOnly:
                return .white.opacity(0.55)
            }
        }()

        return HStack(spacing: 5) {
            Text(item.modelName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(item.origin.badgeText)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(badgeColor.opacity(0.13))
                )
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                if let cPeriod = item.cloudPeriodTokens, cPeriod > 0 {
                    let prefix = (item.cloudTodayTokens ?? 0) > 0
                        ? "今日 \(NumberFormatterUtil.formatCompact(item.cloudTodayTokens!)) · "
                        : ""
                    Text("\(prefix)\(item.cloudPeriodLabel ?? "云端") \(NumberFormatterUtil.formatCompact(cPeriod))")
                        .foregroundStyle(Color(.sRGB, red: 0.68, green: 0.88, blue: 1.0))
                } else if let cToday = item.cloudTodayTokens, cToday > 0 {
                    Text("云端今日 \(NumberFormatterUtil.formatCompact(cToday))")
                        .foregroundStyle(Color(.sRGB, red: 0.68, green: 0.88, blue: 1.0))
                }

                if let reqs = item.cloudRequests, reqs > 0 {
                    Text("\(reqs)次")
                        .foregroundStyle(.white.opacity(0.52))
                }

                if let spend = item.cloudSpendText, !spend.isEmpty {
                    Text(spend)
                        .fontWeight(.medium)
                        .foregroundStyle(Color(.sRGB, red: 0.98, green: 0.82, blue: 0.48))
                }

                if let qText = item.cloudQuotaText, !qText.isEmpty {
                    Text(qText)
                        .foregroundStyle(modelQuotaColor(usedPercent: item.cloudUsedPercent))
                }

                if item.localAllTimeTokens > 0 || item.localTodayTokens > 0 {
                    if item.origin == .merged {
                        Text("本机90d \(NumberFormatterUtil.formatCompact(item.localAllTimeTokens))")
                            .foregroundStyle(.white.opacity(0.58))
                    } else if item.localTodayTokens > 0 {
                        Text("今日 \(NumberFormatterUtil.formatCompact(item.localTodayTokens)) · 90d \(NumberFormatterUtil.formatCompact(item.localAllTimeTokens))")
                            .foregroundStyle(.white.opacity(0.68))
                    } else {
                        Text("90d \(NumberFormatterUtil.formatCompact(item.localAllTimeTokens))")
                            .foregroundStyle(.white.opacity(0.64))
                    }

                    if showEstimatedCost && item.localCost >= 0.01 && item.cloudSpendText == nil {
                        Text(NumberFormatterUtil.formatCurrency(item.localCost))
                            .foregroundStyle(Color(.sRGB, red: 0.46, green: 0.92, blue: 0.68).opacity(0.88))
                            .help("本机日志按 API 单价折算等效价值")
                    }
                }
            }
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func modelQuotaColor(usedPercent: Double?) -> Color {
        guard let usedPercent else { return .white.opacity(0.58) }
        let rem = max(0, 100 - usedPercent)
        if rem <= 10 { return Color(.sRGB, red: 1.0, green: 0.45, blue: 0.45) }
        if rem <= 30 { return .orange }
        return Color(.sRGB, red: 0.44, green: 0.92, blue: 0.68)
    }

    private func tokenBreakdownFooter(
        breakdown: TokenBreakdownSnapshot,
        todayBreakdown: TokenBreakdownSnapshot?
    ) -> some View {
        HStack(spacing: 9) {
            Text(String(format: "90d 缓存命中 %.1f%%", breakdown.cacheHitPercent))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(.sRGB, red: 0.46, green: 0.92, blue: 0.72))

            Text("输入 \(NumberFormatterUtil.formatCompact(breakdown.input))")
            Text("缓存读 \(NumberFormatterUtil.formatCompact(breakdown.cacheRead))")
            if breakdown.cacheWrite > 0 {
                Text("缓存写 \(NumberFormatterUtil.formatCompact(breakdown.cacheWrite))")
            }
            Text("输出 \(NumberFormatterUtil.formatCompact(breakdown.output))")
            if breakdown.reasoning > 0 {
                Text("推理 \(NumberFormatterUtil.formatCompact(breakdown.reasoning))")
            }

            Spacer(minLength: 0)

            if let acctTps = account.tokensPerSecond {
                Text("⚡ \(SpeedFormatter.format(acctTps))")
                    .foregroundStyle(Color(.sRGB, red: 0.56, green: 0.88, blue: 1.0))
                    .help(SpeedFormatter.tooltip(average: acctTps, latest: account.latestTokensPerSecond, isToday: account.speedIsToday))
            }

            if let tb = todayBreakdown, tb.totalTokens > 0 {
                Text(String(format: "今日缓存 %.0f%%", tb.cacheHitPercent))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .font(.system(size: 10, weight: .regular, design: .rounded))
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.045))
        )
    }

    private var statusDotColor: Color {
        if account.quotaError != nil && account.quotaWindows.isEmpty {
            return .orange
        }
        if let minRemaining = account.quotaWindows.filter({ !$0.isUnlimited }).map(\.remainingPercent).min() {
            if minRemaining <= 10 { return Color(.sRGB, red: 1.0, green: 0.42, blue: 0.42) }
            if minRemaining <= 30 { return .orange }
            return Color(.sRGB, red: 0.34, green: 0.90, blue: 0.62)
        }
        return .white.opacity(0.45)
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let providerAccent: Color

    private var extraDetailText: String? {
        guard let detail = window.detailText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty,
              !detail.hasPrefix("剩余 ") else {
            return nil
        }
        return detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 5) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if window.isUnlimited {
                    Text("不限额")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(barTextColor)
                } else {
                    Text(String(format: "剩余 %.0f%%", window.remainingPercent))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(barTextColor)
                        .lineLimit(1)
                }
            }

            GeometryReader { geo in
                let totalWidth = max(0, geo.size.width)
                let ratio = window.isUnlimited ? 1.0 : min(1.0, max(0.0, window.remainingPercent / 100.0))
                let fillWidth = window.remainingPercent > 0 ? max(4, totalWidth * ratio) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(height: 5.5)

                    if window.isUnlimited {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(.sRGB, red: 0.30, green: 0.85, blue: 0.62).opacity(0.55),
                                        providerAccent.opacity(0.55)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: totalWidth, height: 5.5)
                    } else if fillWidth > 0 {
                        Capsule()
                            .fill(barGradient)
                            .frame(width: fillWidth, height: 5.5)
                    }
                }
            }
            .frame(height: 5.5)

            let resetText = ResetFormatter.format(window.resetAt)
            if extraDetailText != nil || resetText != nil {
                HStack(spacing: 4) {
                    if let extra = extraDetailText {
                        Text(extra)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if let resetText {
                        Text(resetText)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
            }
        }
    }

    private var barGradient: LinearGradient {
        let rem = window.remainingPercent
        if rem <= 15 {
            return LinearGradient(
                colors: [
                    Color(.sRGB, red: 1.0, green: 0.45, blue: 0.38),
                    Color(.sRGB, red: 0.96, green: 0.24, blue: 0.34)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if rem <= 35 {
            return LinearGradient(
                colors: [
                    Color(.sRGB, red: 1.0, green: 0.74, blue: 0.28),
                    Color(.sRGB, red: 0.98, green: 0.50, blue: 0.20)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                providerAccent.opacity(0.95),
                Color(.sRGB, red: 0.34, green: 0.88, blue: 0.72)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var barTextColor: Color {
        if window.isUnlimited {
            return Color(.sRGB, red: 0.46, green: 0.94, blue: 0.70)
        }
        let rem = window.remainingPercent
        if rem <= 15 {
            return Color(.sRGB, red: 1.0, green: 0.56, blue: 0.54)
        }
        if rem <= 35 {
            return Color(.sRGB, red: 1.0, green: 0.78, blue: 0.42)
        }
        return Color(.sRGB, red: 0.62, green: 0.96, blue: 0.78)
    }
}

// MARK: - Header Buttons & Empty State

private enum HeaderButtonRole {
    case normal
    case close
}

private struct HeaderActionButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    var isActive = false
    var role: HeaderButtonRole = .normal
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 29, height: 29)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    isActive
                                        ? Color.accentColor.opacity(0.48)
                                        : .white.opacity(isHovered ? 0.22 : 0.12),
                                    isActive
                                        ? Color.accentColor.opacity(0.28)
                                        : .white.opacity(isHovered ? 0.10 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isActive
                                        ? Color.accentColor.opacity(0.75)
                                        : .white.opacity(isHovered ? 0.34 : 0.18),
                                    lineWidth: 0.7
                                )
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: isHovered ? 7 : 4, x: 0, y: 2)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isDisabled {
            return .white.opacity(0.28)
        }
        if role == .close && isHovered {
            return Color(.sRGB, red: 1.0, green: 0.58, blue: 0.56).opacity(0.95)
        }
        if isActive {
            return .white
        }
        return .white.opacity(isHovered ? 0.92 : 0.68)
    }
}

private struct EmptyStateCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - Compact Mascot Badge (supports PNG & animated GIF)

private struct WorkingMascotBadgeView: View {
    @State private var mascotURL: URL?
    @ObservedObject private var settings = SettingsManager.shared
    private let badgeCanvasSize = CGSize(width: 60, height: 60)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.11), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                )

            if let url = mascotURL {
                AnimatedImageView(url: url, targetSize: badgeCanvasSize)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .id(url.path)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.45))
                    .onAppear { loadMascot() }
            }
        }
        .onAppear { loadMascot() }
        .onChange(of: settings.customMascotPath) { _, _ in loadMascot() }
    }

    private func loadMascot() {
        if let path = settings.customMascotPath, FileManager.default.fileExists(atPath: path) {
            mascotURL = URL(fileURLWithPath: path)
            return
        }
        if let url = ProviderBrandIconCache.bundledResourceURL(name: "working-mascot", ext: "png") {
            mascotURL = url
        }
    }
}

private struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    let targetSize: CGSize

    func makeNSView(context: Context) -> GIFImageView {
        let view = GIFImageView(targetSize: targetSize)
        view.imageURL = url
        return view
    }

    func updateNSView(_ nsView: GIFImageView, context: Context) {
        nsView.targetSize = targetSize
        nsView.imageURL = url
    }
}

private final class GIFImageView: NSImageView {
    var targetSize: CGSize
    var imageURL: URL? {
        didSet {
            if oldValue != imageURL {
                reloadImage()
            }
        }
    }

    init(targetSize: CGSize) {
        self.targetSize = targetSize
        super.init(frame: NSRect(origin: .zero, size: targetSize))
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func reloadImage() {
        guard let url = imageURL, let data = try? Data(contentsOf: url) else {
            image = nil
            return
        }
        let isGIF = url.pathExtension.lowercased() == "gif"
        if isGIF {
            let img = NSImage(data: data)
            img?.matchesOnMultipleResolution = false
            imageScaling = .scaleProportionallyUpOrDown
            image = img
        } else {
            guard let original = NSImage(data: data) else { image = nil; return }
            let origSize = original.size
            guard origSize.width > 0, origSize.height > 0 else { image = original; return }
            let scale = min(targetSize.width / origSize.width, targetSize.height / origSize.height)
            let scaledW = origSize.width * scale
            let scaledH = origSize.height * scale
            let compositor = NSImage(size: targetSize, flipped: false) { rect in
                let drawRect = NSRect(
                    x: (rect.width - scaledW) / 2,
                    y: (rect.height - scaledH) / 2,
                    width: scaledW,
                    height: scaledH
                )
                original.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            compositor.matchesOnMultipleResolution = false
            imageScaling = .scaleNone
            image = compositor
        }
    }
}

// MARK: - VisualEffectView

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 28

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}
