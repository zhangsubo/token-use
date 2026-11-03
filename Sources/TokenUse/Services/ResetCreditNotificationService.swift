import Foundation
import AppKit
import CryptoKit
import UserNotifications

/// 负责监控 ChatGPT / Codex 重置券到期时间，并在剩余完整 48 小时（2 天）时触发 macOS 原生系统通知。
///
/// 双重可靠触发机制：
/// 1. 当重置券距离过期 `> 48h` 时，预先向 `UNUserNotificationCenter` 注册精确定时通知（在跨越 `48h` 边界的瞬间准时弹出），
///    且每次后台同步配额时自动刷新待发通知中的「当前 ChatGPT 用量 %」。
/// 2. 当应用启动或后台同步发现已有未通知的重置券处于 `(0, 48h]` 窗口内时，立即补发一次系统通知并持久化去重。
@MainActor
final class ResetCreditNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ResetCreditNotificationService()

    /// 提前提醒阈值：完整两天（48 小时 = 172,800 秒）
    nonisolated static let expiryLeadTime: TimeInterval = 48 * 3600
    nonisolated private static let requestIdPrefix = "tokenuse.reset-credit.48h."

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// 仅在标准 `.app` 应用包环境下启用 `UNUserNotificationCenter`（避免裸命令行二进制调用触发系统异常）
    static var isSupportedBundle: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private override init() {
        super.init()
    }

    func setup() {
        guard Self.isSupportedBundle else {
            DebugLogger.log("ℹ️ [ResetCreditNotify] 当前非 .app 包环境，跳过 UNUserNotificationCenter 初始化")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        Task { @MainActor in
            _ = await refreshAuthorizationStatus()
            if SettingsManager.shared.enableResetCreditExpiryNotification {
                _ = await requestAuthorizationIfNeeded()
            }
        }
    }

    @discardableResult
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        guard Self.isSupportedBundle else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
        return settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        guard Self.isSupportedBundle else { return false }
        let status = await refreshAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )) ?? false
            _ = await refreshAuthorizationStatus()
            return granted
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// 打开 macOS「系统设置 → 通知」面板
    func openSystemNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// 生成通知正文：`xxx账号有一张重置券要到期，当前chatGPT 用量为 xx %，抓紧用！`
    nonisolated static func formatNotificationBody(
        accountLabel: String,
        maskLabels: Bool,
        usedPercent: Int
    ) -> String {
        let displayLabel = maskLabels
            ? SettingsManager.maskAccountLabel(accountLabel)
            : accountLabel
        let trimmed = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLabel = trimmed.isEmpty ? "ChatGPT" : trimmed
        let accountPrefix = safeLabel.hasSuffix("账号") ? safeLabel : "\(safeLabel)账号"
        let clampedPct = min(100, max(0, usedPercent))
        return "\(accountPrefix)有一张重置券要到期，当前chatGPT 用量为 \(clampedPct) %，抓紧用！"
    }

    func cancelAllPendingResetCreditNotifications() async {
        guard Self.isSupportedBundle else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.requestIdPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            DebugLogger.log("🧹 [ResetCreditNotify] 已清理 \(ids.count) 条待触发重置券到期通知")
        }
    }

    /// 每次配额同步完成或相关设置变更后评估所有 Codex 账号的重置券到期状态
    func evaluate(dashboard: MultiAccountDashboard?) async {
        guard Self.isSupportedBundle, let dashboard else { return }
        let settings = SettingsManager.shared

        guard settings.enableResetCreditExpiryNotification else {
            await cancelAllPendingResetCreditNotifications()
            return
        }

        let granted = await requestAuthorizationIfNeeded()
        guard granted else { return }

        let now = Date()
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()
        let deliveredIds = Set(deliveredNotifications.map { $0.request.identifier })

        // 将已由系统定时器送达在通知中心里的重置券同步写入已通知集合
        for delivered in deliveredNotifications where delivered.request.identifier.hasPrefix(Self.requestIdPrefix) {
            if let creditIds = delivered.request.content.userInfo["creditIds"] as? [String], !creditIds.isEmpty {
                settings.markResetCreditsNotified(creditIds)
            }
        }

        let codexAccounts = dashboard.providers
            .filter { $0.provider == .codex }
            .flatMap(\.accounts)

        var desiredPendingIds = Set<String>()

        for account in codexAccounts {
            let activeCredits = account.activeResetCredits(at: now)
            guard !activeCredits.isEmpty else { continue }

            let usedPct = account.codexPrimaryUsedPercent(at: now)
            let batches = Self.groupCreditsIntoBatches(activeCredits)

            for batch in batches {
                guard let earliest = batch.first?.expiresAt else { continue }
                let remaining = earliest.timeIntervalSince(now)
                guard remaining > 0 else { continue }

                let creditIds = batch.map(\.id)
                let reqId = Self.requestIdentifier(accountId: account.id, creditIds: creditIds)

                let content = UNMutableNotificationContent()
                content.title = "ChatGPT 重置券到期提醒"
                if batch.count > 1 {
                    content.subtitle = "共 \(batch.count) 张重置券距到期不足 48 小时"
                }
                content.body = Self.formatNotificationBody(
                    accountLabel: account.label,
                    maskLabels: settings.maskAccountLabels,
                    usedPercent: usedPct
                )
                content.sound = .default
                content.userInfo = [
                    "creditIds": creditIds,
                    "accountId": account.id,
                ]

                if remaining <= Self.expiryLeadTime {
                    // 已进入 48 小时倒计时窗口：若尚未提醒过则立即发送系统通知
                    let allAlreadyNotified = creditIds.allSatisfy { settings.hasNotifiedResetCredit($0) }
                    if allAlreadyNotified {
                        continue
                    }
                    if deliveredIds.contains(reqId) {
                        settings.markResetCreditsNotified(creditIds)
                        continue
                    }

                    center.removePendingNotificationRequests(withIdentifiers: [reqId])
                    let immediateReq = UNNotificationRequest(
                        identifier: reqId,
                        content: content,
                        trigger: nil
                    )
                    do {
                        try await center.add(immediateReq)
                        settings.markResetCreditsNotified(creditIds)
                        DebugLogger.log("🔔 [ResetCreditNotify] 已发送重置券 ≤48h 到期通知（券数=\(batch.count), 用量=\(usedPct)%）")
                    } catch {
                        DebugLogger.log("❌ [ResetCreditNotify] 发送即时通知失败: \(error.localizedDescription)")
                    }
                } else {
                    // 距离到期大于 48 小时：注册/更新精确定时触发器，确保跨越 48 小时整点时准时提醒
                    let fireDelay = max(1.0, remaining - Self.expiryLeadTime)
                    desiredPendingIds.insert(reqId)
                    let trigger = UNTimeIntervalNotificationTrigger(
                        timeInterval: fireDelay,
                        repeats: false
                    )
                    let scheduledReq = UNNotificationRequest(
                        identifier: reqId,
                        content: content,
                        trigger: trigger
                    )
                    do {
                        try await center.add(scheduledReq)
                    } catch {
                        DebugLogger.log("❌ [ResetCreditNotify] 预约 48h 定时通知失败: \(error.localizedDescription)")
                    }
                }
            }
        }

        // 清理已兑换、已过期或已立即通知过的旧待触发请求
        let stalePendingIds = pendingRequests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.requestIdPrefix) && !desiredPendingIds.contains($0) }
        if !stalePendingIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stalePendingIds)
        }
    }

    /// 发送一条预览测试通知（优先采用当前首个 Codex 账号与实时用量百分比，不影响真实重置券去重状态）
    func sendTestNotification(dashboard: MultiAccountDashboard?) async -> Result<String, Error> {
        guard Self.isSupportedBundle else {
            return .failure(NSError(
                domain: "ResetCreditNotificationService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "当前未运行在标准 macOS .app 应用包中，无法调用系统通知中心"]
            ))
        }

        let granted = await requestAuthorizationIfNeeded()
        guard granted else {
            return .failure(NSError(
                domain: "ResetCreditNotificationService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "macOS 系统通知权限未开启，请前往「系统设置 → 通知 → TokenUse」允许通知"]
            ))
        }

        let settings = SettingsManager.shared
        let now = Date()
        let codexAccounts = dashboard?.providers
            .first(where: { $0.provider == .codex })?
            .accounts ?? []
        let sampleAccount = codexAccounts.first(where: { !$0.activeResetCredits(at: now).isEmpty })
            ?? codexAccounts.first

        let rawLabel = sampleAccount?.label ?? "示例"
        let usedPct = sampleAccount?.codexPrimaryUsedPercent(at: now) ?? 32
        let body = Self.formatNotificationBody(
            accountLabel: rawLabel,
            maskLabels: settings.maskAccountLabels,
            usedPercent: usedPct
        )

        let content = UNMutableNotificationContent()
        content.title = "ChatGPT 重置券到期提醒"
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "tokenuse.reset-credit.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(req)
            return .success(body)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let reqId = notification.request.identifier
        let creditIds = (notification.request.content.userInfo["creditIds"] as? [String]) ?? []
        if reqId.hasPrefix(Self.requestIdPrefix), !creditIds.isEmpty {
            Task { @MainActor in
                SettingsManager.shared.markResetCreditsNotified(creditIds)
            }
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let reqId = response.notification.request.identifier
        let creditIds = (response.notification.request.content.userInfo["creditIds"] as? [String]) ?? []
        Task { @MainActor in
            if reqId.hasPrefix(Self.requestIdPrefix), !creditIds.isEmpty {
                SettingsManager.shared.markResetCreditsNotified(creditIds)
            }
            NSApp.activate(ignoringOtherApps: true)
            EdgeWindowManager.shared.showPanel()
        }
        completionHandler()
    }

    // MARK: - Helpers

    /// 将同一账号下过期时间相差 60 秒以内的重置券归为同一批次（避免同秒发放的多张券同时弹出多条重复横幅）
    private static func groupCreditsIntoBatches(_ sortedCredits: [ResetCreditItem]) -> [[ResetCreditItem]] {
        var batches: [[ResetCreditItem]] = []
        for credit in sortedCredits {
            if let lastBatch = batches.last,
               let batchAnchor = lastBatch.first?.expiresAt,
               abs(credit.expiresAt.timeIntervalSince(batchAnchor)) <= 60 {
                batches[batches.count - 1].append(credit)
            } else {
                batches.append([credit])
            }
        }
        return batches
    }

    private static func requestIdentifier(accountId: String, creditIds: [String]) -> String {
        let joined = "\(accountId)::\(creditIds.sorted().joined(separator: "|"))"
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        return "\(requestIdPrefix)\(hex)"
    }
}
