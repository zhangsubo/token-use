import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts = "多账号管理"
    case general = "常规与更新"

    var id: String { rawValue }
}

struct SettingsView: View {
    var initialTab: SettingsTab = .accounts
    var initialAddingProvider: TrackedProvider? = nil
    var isStandaloneWindow: Bool = false

    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var appState = AppState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .accounts
    @State private var editingAccount: AccountEditSession?
    @State private var xiaomiLoginTarget: ProviderAccountConfig?
    @State private var hostingWindow: NSWindow?
    @State private var showAccountsOrderDrawer: Bool = false
    @State private var draggingAccountTabProvider: TrackedProvider?

    @State private var customIntervalText: String = ""
    @State private var isCustomInterval: Bool = false
    @State private var previewImage: NSImage?
    @State private var isImportingMascot = false

    private let intervalOptions: [(String, TimeInterval)] = [
        ("5 分钟", 300),
        ("10 分钟", 600),
        ("30 分钟", 1800),
        ("自定义", -1),
    ]

    var body: some View {
        let cornerRadius: CGFloat = isStandaloneWindow ? 0 : 20

        VStack(spacing: 0) {
            headerBar

            Divider().background(.white.opacity(0.14))

            if selectedTab == .accounts {
                accountsTabContent
            } else {
                generalTabContent
            }
        }
        .frame(width: 560, height: 580)
        .background(
            SettingsWindowAccessor(configureChrome: isStandaloneWindow) { win in
                hostingWindow = win
            }
        )
        .background(
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .behindWindow,
                cornerRadius: cornerRadius
            )
            .ignoresSafeArea()
        )
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.24, green: 0.30, blue: 0.44).opacity(0.88),
                            Color(.sRGB, red: 0.16, green: 0.20, blue: 0.32).opacity(0.92),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()
        )
        .overlay {
            if !isStandaloneWindow {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if isStandaloneWindow {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                EdgeWindowManager.shared.isModalPresenting = true
            }
            selectedTab = initialTab
            setupIntervalState()
            appState.reloadAccountList()
            if let provider = initialAddingProvider {
                editingAccount = .newManual(provider: provider)
            }
        }
        .onDisappear {
            if !isStandaloneWindow {
                EdgeWindowManager.shared.isModalPresenting = false
            }
        }
        .sheet(item: $editingAccount) { session in
            AccountEditorSheet(session: session) {
                appState.reloadAccountList()
                Task { await appState.refresh() }
            }
        }
        .sheet(item: $xiaomiLoginTarget) { account in
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

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            Text("设置")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let active = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(active ? 0.96 : 0.62))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(active ? 0.20 : 0.0))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(.black.opacity(0.22))
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.6))
            )

            Spacer()

            Button {
                if isStandaloneWindow {
                    (hostingWindow ?? NSApp.keyWindow)?.close()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.12))
                            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    // MARK: - Tab 1: Multi-Account Management

    private var accountsTabContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("自动扫描本机配置", isOn: $settings.enableAutoDiscovery)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .onChange(of: settings.enableAutoDiscovery) { _, _ in
                        Task { await appState.refresh() }
                    }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        showAccountsOrderDrawer.toggle()
                    }
                } label: {
                    Label(showAccountsOrderDrawer ? "完成排序" : "平台排序", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: showAccountsOrderDrawer ? .semibold : .regular))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(showAccountsOrderDrawer ? .cyan : nil)

                Button {
                    appState.reloadAccountList()
                    Task { await appState.refresh() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    ForEach(settings.providerOrder) { provider in
                        Button {
                            editingAccount = .newManual(provider: provider)
                        } label: {
                            Label(provider.displayName, systemImage: provider.systemIcon)
                        }
                    }
                } label: {
                    Label("添加账号", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.white.opacity(0.04))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showAccountsOrderDrawer {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("拖动调整平台展示顺序（按平台整体排序）", systemImage: "line.3.horizontal")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))

                                Spacer()

                                if !settings.isDefaultProviderOrder {
                                    Button("恢复默认") {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                            settings.resetProviderOrder()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }

                            ProviderOrderDragList(
                                settings: settings,
                                accounts: appState.discoveredAccounts
                            )
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.sRGB, red: 0.14, green: 0.24, blue: 0.38).opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.cyan.opacity(0.35), lineWidth: 0.9)
                                )
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ForEach(settings.providerOrder) { provider in
                        providerAccountGroup(provider)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
    }

    private func providerAccountGroup(_ provider: TrackedProvider) -> some View {
        let accounts = appState.discoveredAccounts.filter { $0.provider == provider }
        let isBeingDragged = draggingAccountTabProvider == provider

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 16, height: 24)

                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(provider.accentColor.opacity(0.18))
                            .frame(width: 24, height: 24)

                        ProviderBrandIcon(provider: provider, size: 15, cornerRadius: 3.5)
                    }

                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("(\(accounts.count))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
                .help("按住拖动可调整平台展示顺序")
                .onDrag {
                    draggingAccountTabProvider = provider
                    return NSItemProvider(object: provider.rawValue as NSString)
                }

                Spacer()

                Button {
                    editingAccount = .newManual(provider: provider)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("新增")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.10))
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
                    )
                }
                .buttonStyle(.plain)
            }

            if accounts.isEmpty {
                Text("暂未发现本机账号 · 点击右上角「新增」可手动配置 API Key / OAuth / 独立日志目录")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.035))
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                }
            }
        }
        .padding(12)
        .opacity(isBeingDragged ? 0.72 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isBeingDragged ? provider.accentColor.opacity(0.65) : .white.opacity(0.12),
                            lineWidth: isBeingDragged ? 1.1 : 0.7
                        )
                )
        )
        .onDrop(
            of: [.plainText, .text],
            delegate: ProviderCardDropDelegate(
                targetProvider: provider,
                draggingProvider: $draggingAccountTabProvider,
                settings: settings
            )
        )
    }

    private func accountRow(_ account: ProviderAccountConfig) -> some View {
        let hasCookie = KeychainStore.loadSecret(for: SettingsManager.cookieKeychainKey(for: account.id)) != nil
            || (account.authKind == .cookie && KeychainStore.loadSecret(for: account.id) != nil)
        let isActiveCodex = account.provider == .codex && appState.activeCodexAccountIds.contains(account.id)
        let canSwitchCodex = account.provider == .codex && account.authKind == .oauthToken && !isActiveCodex

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { account.isEnabled },
                set: { newVal in
                    settings.setAccountEnabled(newVal, for: account)
                    appState.reloadAccountList()
                    Task { await appState.refresh() }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(account.isEnabled ? 0.94 : 0.45))
                        .lineLimit(1)

                    Text(account.originDescription ?? (account.source == .manual ? "手动" : "自动"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.10)))

                    if isActiveCodex {
                        Text("当前使用")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green.opacity(0.92))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.green.opacity(0.16)))
                    }

                    if account.provider == .mimo && hasCookie {
                        Text("已绑控制台")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.green.opacity(0.16)))
                    }
                }

                if let logPath = account.customLogPath, !logPath.isEmpty {
                    Text("日志目录: \(abbreviateHome(logPath))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer()

            if canSwitchCodex {
                Button {
                    Task { await appState.switchActiveCodexAccount(account.id) }
                } label: {
                    Text(appState.switchingAccountId == account.id ? "切换中..." : "切换启用")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(appState.switchingAccountId != nil)
            }

            if account.provider == .mimo {
                Button {
                    xiaomiLoginTarget = account
                } label: {
                    Text(hasCookie ? "重登控制台" : "登录控制台")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button {
                editingAccount = .existing(account)
            } label: {
                Text("配置")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if account.source == .manual {
                Button(role: .destructive) {
                    settings.deleteManualAccount(id: account.id)
                    appState.reloadAccountList()
                    Task { await appState.refresh() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black.opacity(0.18))
        )
    }

    // MARK: - Tab 2: General & Updates

    private var generalTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                displaySection
                providerOrderSection
                refreshSection
                mascotSection
                updateSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显示偏好")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Toggle("显示估算金额（按 API 单价折算等效价值 ≈ $）", isOn: $settings.showEstimatedCost)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.9))

            Text("关闭后将隐藏今日、近 90 天及各平台分组上的等效美元价值估算标签。")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var providerOrderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("平台展示顺序")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if !settings.isDefaultProviderOrder {
                    Button("恢复默认顺序") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            settings.resetProviderOrder()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("按住平台行上下拖动即可调整展示顺序（按平台整体排序，实时同步至主面板、筛选栏与侧边悬浮舱）。")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))

            ProviderOrderDragList(
                settings: settings,
                accounts: appState.discoveredAccounts
            )
        }
    }

    private var mascotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("个性化图标 / 吉祥物")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                Group {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 8) {
                    Button("上传自定义 PNG") { openMascotPicker() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isImportingMascot)

                    if settings.customMascotPath != nil {
                        Button("恢复默认") {
                            settings.resetMascot()
                            refreshPreviewImage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动同步间隔")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(intervalOptions, id: \.1) { option in
                    let isSelected = isCustomInterval
                        ? option.1 == -1
                        : settings.refreshInterval == option.1

                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.4))

                        Text(option.0)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.7))

                        if option.1 == -1 && isCustomInterval {
                            TextField("分钟", text: $customIntervalText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .font(.system(size: 13))
                                .onSubmit { applyCustomInterval() }
                                .onChange(of: customIntervalText) { _, _ in applyCustomInterval() }
                            Text("分钟")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if option.1 == -1 {
                            isCustomInterval = true
                            applyCustomInterval()
                        } else {
                            isCustomInterval = false
                            settings.refreshInterval = option.1
                        }
                        AppState.shared.restartTimer()
                    }
                }
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自动更新")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.75))
                Text("当前版本：v\(currentVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Toggle("启动后自动检查更新", isOn: $settings.enableAutoUpdate)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!AppDelegate.isSparkleConfigured)

            if let last = settings.lastUpdateCheckDate {
                Text("上次检查：\(Self.relativeDate(last))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.checkForUpdates()
            } label: {
                Label("立即检查更新", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func setupIntervalState() {
        let current = settings.refreshInterval
        let matched = intervalOptions.first { $0.1 == current && $0.1 != -1 }
        if matched == nil {
            isCustomInterval = true
            customIntervalText = String(Int(current / 60))
        }
        refreshPreviewImage()
    }

    private func applyCustomInterval() {
        guard let minutes = Double(customIntervalText), minutes > 0 else { return }
        settings.refreshInterval = minutes * 60
        AppState.shared.restartTimer()
    }

    private func openMascotPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择吉祥物图片"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isImportingMascot = true
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dest = appSupport.appendingPathComponent("TokenUse/mascot-custom.png")

            Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    await MainActor.run {
                        settings.customMascotPath = dest.path
                        refreshPreviewImage()
                        isImportingMascot = false
                    }
                } catch {
                    await MainActor.run { isImportingMascot = false }
                }
            }
        }
    }

    private func refreshPreviewImage() {
        previewImage = settings.customMascotImage ?? loadDefaultMascot()
    }

    private func loadDefaultMascot() -> NSImage? {
        guard let url = ProviderBrandIconCache.bundledResourceURL(name: "working-mascot", ext: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

// MARK: - AccountEditorSheet

enum AccountEditSession: Identifiable {
    case newManual(provider: TrackedProvider)
    case existing(ProviderAccountConfig)

    var id: String {
        switch self {
        case .newManual(let p): return "new.\(p.rawValue)"
        case .existing(let acct): return "edit.\(acct.id)"
        }
    }
}

private struct AccountEditorSheet: View {
    let session: AccountEditSession
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared

    @State private var provider: TrackedProvider = .codex
    @State private var isAutoDiscovered = false
    @State private var accountId: String = UUID().uuidString
    @State private var label: String = ""
    @State private var authKind: AccountAuthKind = .apiKey
    @State private var secretInput: String = ""
    @State private var consoleCookieInput: String = ""
    @State private var regionOrBaseURL: String = ""
    @State private var externalAccountId: String = ""
    @State private var customLogPath: String = ""
    @State private var isEnabled: Bool = true
    @State private var showXiaomiWebLogin = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProviderBrandIcon(provider: provider, size: 18, cornerRadius: 4)
                Text(isAutoDiscovered ? "配置本机发现账号 — \(provider.displayName)" : "配置账号 — \(provider.displayName)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }

            Text(provider.credentialHint)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))

            Form {
                if !isAutoDiscovered {
                    Picker("所属平台", selection: $provider) {
                        ForEach(settings.providerOrder) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .onChange(of: provider) { _, newProvider in
                        authKind = Self.recommendedAuthKind(for: newProvider)
                    }
                }

                TextField("备注名称（如：主力 Pro / 工作号）", text: $label)

                if !isAutoDiscovered {
                    Picker("认证方式", selection: $authKind) {
                        ForEach(AccountAuthKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    if authKind != .localOnly {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(secretFieldTitle)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $secretInput)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(height: 68)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                        }
                    }
                }

                if provider == .mimo {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("小米控制台会话 Cookie（已装 MiMo 桌面端可自动免登，多账号可单独登录）")
                                .font(.system(size: 11.5, weight: .medium))
                            Spacer()
                            Button("打开网页登录自动获取") {
                                showXiaomiWebLogin = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                        TextField("api-platform_serviceToken=...; userId=...", text: $consoleCookieInput)
                            .font(.system(size: 11.5, design: .monospaced))
                    }
                }

                TextField("区域或自定义接口地址（可选：cn / global 或 https://...）", text: $regionOrBaseURL)

                if provider == .codex && !isAutoDiscovered {
                    TextField("ChatGPT Account / Workspace ID（可选，多团队工作区使用）", text: $externalAccountId)
                }

                HStack(spacing: 8) {
                    TextField("独立本地日志/配置目录（可选，如 \(provider.defaultLogPathHint)）", text: $customLogPath)
                    Button("选择目录…") {
                        pickDirectory()
                    }
                    .controlSize(.small)
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 490)
        .background(Color(.sRGB, red: 0.16, green: 0.20, blue: 0.30))
        .preferredColorScheme(.dark)
        .onAppear(perform: populateInitialValues)
        .sheet(isPresented: $showXiaomiWebLogin) {
            XiaomiConsoleLoginSheet(accountLabel: label.isEmpty ? "MiMo 账号" : label) { captured in
                consoleCookieInput = captured
                if !isAutoDiscovered && authKind == .cookie && secretInput.isEmpty {
                    secretInput = captured
                }
            }
        }
    }

    private var secretFieldTitle: String {
        switch (provider, authKind) {
        case (.kimi, .cookie):
            return "粘贴 Kimi 网页端 Cookie（含 kimi-auth=...，安全存入 macOS Keychain）"
        case (_, .cookie):
            return "控制台 Cookie（存入 macOS Keychain）"
        case (.codex, .oauthToken):
            return "粘贴 auth.json 内容、JWT access_token 或 refresh_token（存入 Keychain）"
        case (.antigravity, .oauthToken):
            return "粘贴 Google OAuth JSON 或 refresh_token（存入 Keychain）"
        case (.kimi, .oauthToken):
            return "粘贴 Kimi OAuth JSON（含 access_token / refresh_token）"
        default:
            return "API Key / Token（安全存入 macOS Keychain，留空则保持原值）"
        }
    }

    private static func recommendedAuthKind(for provider: TrackedProvider) -> AccountAuthKind {
        switch provider {
        case .codex: return .oauthToken
        case .mimo: return .cookie
        case .kimi: return .apiKey
        case .minimax: return .apiKey
        case .antigravity: return .oauthToken
        }
    }

    private func populateInitialValues() {
        switch session {
        case .newManual(let p):
            provider = p
            isAutoDiscovered = false
            accountId = UUID().uuidString
            authKind = Self.recommendedAuthKind(for: p)
            label = ""
            isEnabled = true
        case .existing(let acct):
            provider = acct.provider
            isAutoDiscovered = (acct.source == .autoDiscovered)
            accountId = acct.id
            label = acct.label
            authKind = acct.authKind
            regionOrBaseURL = acct.regionOrBaseURL ?? ""
            externalAccountId = acct.externalAccountId ?? ""
            customLogPath = acct.customLogPath ?? ""
            isEnabled = acct.isEnabled
            secretInput = KeychainStore.loadSecret(for: acct.id) ?? ""
            consoleCookieInput = KeychainStore.loadSecret(for: SettingsManager.cookieKeychainKey(for: acct.id)) ?? ""
        }
    }

    private func pickDirectory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择该账号对应的本地日志或配置目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            customLogPath = url.path
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmedLabel.isEmpty ? "\(provider.displayName) 账号" : trimmedLabel

        do {
            if isAutoDiscovered {
                try settings.updateDiscoveredAccountOverride(
                    accountID: accountId,
                    customLabel: finalLabel,
                    isEnabled: isEnabled,
                    customLogPath: customLogPath,
                    regionOrBaseURL: regionOrBaseURL,
                    consoleCookie: provider == .mimo ? consoleCookieInput : nil
                )
            } else {
                if case .newManual = session,
                   authKind != .localOnly,
                   secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !(provider == .mimo && !consoleCookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    validationError = "请输入凭证内容，或将认证方式切换为「仅本地日志目录」。"
                    return
                }

                let cfg = ProviderAccountConfig(
                    id: accountId,
                    provider: provider,
                    label: finalLabel,
                    source: .manual,
                    authKind: authKind,
                    isEnabled: isEnabled,
                    regionOrBaseURL: regionOrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : regionOrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    externalAccountId: externalAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : externalAccountId.trimmingCharacters(in: .whitespacesAndNewlines),
                    originDescription: "手动添加",
                    customLogPath: customLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customLogPath.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try settings.saveManualAccount(
                    cfg,
                    secret: secretInput,
                    consoleCookie: provider == .mimo ? consoleCookieInput : nil
                )
            }
            onSaved()
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// MARK: - SettingsWindowAccessor

private struct SettingsWindowAccessor: NSViewRepresentable {
    let configureChrome: Bool
    let onResolve: @MainActor (NSWindow?) -> Void

    final class WindowObserverView: NSView {
        var configureChrome: Bool = false
        var onResolve: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, configureChrome {
                window.appearance = NSAppearance(named: .darkAqua)
                window.backgroundColor = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.32, alpha: 1.0)
                window.titlebarAppearsTransparent = true
            }
            onResolve?(window)
        }
    }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.configureChrome = configureChrome
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.configureChrome = configureChrome
        nsView.onResolve = onResolve
    }
}

// MARK: - Provider Drag-to-Reorder Components

private struct ProviderOrderDragList: View {
    @ObservedObject var settings: SettingsManager
    let accounts: [ProviderAccountConfig]

    @State private var draggingProvider: TrackedProvider?
    @State private var dragStartIndex: Int?
    @State private var dragTranslationY: CGFloat = 0
    @State private var hoveredProvider: TrackedProvider?

    private let rowHeight: CGFloat = 38
    private let rowSpacing: CGFloat = 6
    private var stride: CGFloat { rowHeight + rowSpacing }

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(settings.providerOrder) { provider in
                let currentIndex = settings.providerOrder.firstIndex(of: provider) ?? 0
                let isDragging = draggingProvider == provider
                let isHovered = hoveredProvider == provider
                let accountCount = accounts.filter { $0.provider == provider }.count

                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(isDragging || isHovered ? 0.90 : 0.42))
                        .frame(width: 16)

                    Text("\(currentIndex + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.10)))

                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(provider.accentColor.opacity(0.18))
                            .frame(width: 24, height: 24)
                        ProviderBrandIcon(provider: provider, size: 15, cornerRadius: 3.5)
                    }

                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(provider.vendorName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.08)))

                    if accountCount > 0 {
                        Text("\(accountCount) 账号")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(provider.accentColor.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(provider.accentColor.opacity(0.15)))
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                settings.moveProvider(provider, to: currentIndex - 1)
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentIndex == 0)
                        .opacity(currentIndex == 0 ? 0.22 : (isHovered ? 0.90 : 0.45))
                        .help("上移一位")

                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                settings.moveProvider(provider, to: currentIndex + 1)
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentIndex >= settings.providerOrder.count - 1)
                        .opacity(currentIndex >= settings.providerOrder.count - 1 ? 0.22 : (isHovered ? 0.90 : 0.45))
                        .help("下移一位")
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isDragging
                                ? Color(.sRGB, red: 0.24, green: 0.32, blue: 0.48).opacity(0.96)
                                : .white.opacity(isHovered ? 0.09 : 0.055)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isDragging
                                        ? provider.accentColor.opacity(0.80)
                                        : .white.opacity(isHovered ? 0.22 : 0.10),
                                    lineWidth: isDragging ? 1.1 : 0.7
                                )
                        )
                )
                .contentShape(Rectangle())
                .offset(y: rowOffset(for: provider, currentIndex: currentIndex))
                .scaleEffect(isDragging ? 1.015 : 1.0)
                .shadow(
                    color: .black.opacity(isDragging ? 0.34 : 0.0),
                    radius: isDragging ? 10 : 0,
                    x: 0,
                    y: isDragging ? 4 : 0
                )
                .zIndex(isDragging ? 10 : 0)
                .onHover { hovering in
                    if hovering {
                        hoveredProvider = provider
                    } else if hoveredProvider == provider {
                        hoveredProvider = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("ProviderOrderDragSpace"))
                        .onChanged { value in
                            if draggingProvider == nil {
                                guard let idx = settings.providerOrder.firstIndex(of: provider) else { return }
                                draggingProvider = provider
                                dragStartIndex = idx
                            }
                            guard draggingProvider == provider, let startIdx = dragStartIndex else { return }

                            let deltaY = value.location.y - value.startLocation.y
                            dragTranslationY = deltaY

                            let count = settings.providerOrder.count
                            let rawTarget = (CGFloat(startIdx) * stride + deltaY) / stride
                            let targetIdx = max(0, min(count - 1, Int(rawTarget.rounded())))

                            if let currentIdx = settings.providerOrder.firstIndex(of: provider),
                               currentIdx != targetIdx {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                    settings.moveProvider(provider, to: targetIdx)
                                }
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                                draggingProvider = nil
                                dragStartIndex = nil
                                dragTranslationY = 0
                            }
                        }
                )
            }
        }
        .coordinateSpace(name: "ProviderOrderDragSpace")
    }

    private func rowOffset(for provider: TrackedProvider, currentIndex: Int) -> CGFloat {
        guard draggingProvider == provider, let startIdx = dragStartIndex else {
            return 0
        }
        let unclampedY = CGFloat(startIdx) * stride + dragTranslationY
        let maxY = CGFloat(max(0, settings.providerOrder.count - 1)) * stride
        let clampedY: CGFloat
        if unclampedY < 0 {
            clampedY = unclampedY * 0.22
        } else if unclampedY > maxY {
            clampedY = maxY + (unclampedY - maxY) * 0.22
        } else {
            clampedY = unclampedY
        }
        return clampedY - CGFloat(currentIndex) * stride
    }
}

@MainActor
private struct ProviderCardDropDelegate: DropDelegate {
    let targetProvider: TrackedProvider
    @Binding var draggingProvider: TrackedProvider?
    let settings: SettingsManager

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let source = draggingProvider,
              source != targetProvider,
              let targetIndex = settings.providerOrder.firstIndex(of: targetProvider) else {
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            settings.moveProvider(source, to: targetIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProvider = nil
        return true
    }
}
