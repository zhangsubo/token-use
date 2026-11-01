import Foundation

// MARK: - ProviderQuotaResult

struct ProviderQuotaResult: Sendable {
    var resolvedLabel: String?
    var resolvedExternalId: String?
    var planBadge: String?
    var windows: [QuotaWindow] = []
    var walletBalanceText: String? = nil
    var resetCreditsText: String? = nil
    var statusMessage: String?
    var errorMessage: String?
    var hasCustomConsoleAuth: Bool = false
}

// MARK: - ProviderQuotaService

actor ProviderQuotaService {
    static let shared = ProviderQuotaService()

    private let session: URLSession
    private let noRedirectSession: URLSession
    private let insecureLocalSession: URLSession

    /// 内存缓存已刷新的 OAuth Access Token，减少对上游刷新端点的重复调用
    private var cachedAccessTokens: [String: (token: String, expiry: Date)] = [:]
    /// 内存缓存小米通行证换取的短期控制台 / 桌面会员 Cookie（遇 401/46109 自动清缓存重换一次）
    private var cachedMiMoConsoleSessions: [String: String] = [:]
    private var cachedMiMoMembershipSessions: [String: (cookie: String, region: String?)] = [:]
    /// 记忆各 MiniMax 账号上次成功的域名（避免每次先撞错区域）
    private var cachedMiniMaxRegionHost: [String: String] = [:]
    /// 内存缓存从本机 Antigravity 二进制中动态解析出的 OAuth Client Secret
    private var cachedAntigravityClientSecrets: [String]?
    /// 内存缓存 Antigravity 模型枚举映射（如 1417 -> "Gemini 4 Argon (High)"），供本地日志解析共享
    private var dynamicAntigravityModelNames: [Int: String] = [:]

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        self.session = URLSession(configuration: config)

        let manualRedirectCfg = URLSessionConfiguration.ephemeral
        manualRedirectCfg.httpShouldSetCookies = false
        manualRedirectCfg.httpCookieAcceptPolicy = .never
        manualRedirectCfg.timeoutIntervalForRequest = 10
        manualRedirectCfg.timeoutIntervalForResource = 15
        self.noRedirectSession = URLSession(
            configuration: manualRedirectCfg,
            delegate: ManualRedirectBlockDelegate(),
            delegateQueue: nil
        )

        let localCfg = URLSessionConfiguration.ephemeral
        localCfg.timeoutIntervalForRequest = 2.5
        localCfg.timeoutIntervalForResource = 4.0
        self.insecureLocalSession = URLSession(
            configuration: localCfg,
            delegate: LocalhostTrustDelegate(),
            delegateQueue: nil
        )
    }

    func modelMapForAntigravity() -> [Int: String] {
        dynamicAntigravityModelNames
    }

    /// 并发拉取所有已启用账号的在线套餐额度
    func fetchAllQuotas(
        accounts: [ProviderAccountConfig],
        ephemeralSecrets: [String: String],
        offlineCodexSnapshots: [String: OfflineCodexRateLimit]
    ) async -> [String: ProviderQuotaResult] {
        // 先探测一次本机运行中的 Antigravity Language Server（支持 App / CLI / IDE）
        let liveAntigravity = await probeRunningAntigravityServers()

        var results: [String: ProviderQuotaResult] = [:]
        await withTaskGroup(of: (String, ProviderQuotaResult).self) { group in
            for account in accounts where account.isEnabled {
                group.addTask {
                    let res = await self.fetchQuota(
                        for: account,
                        ephemeralSecrets: ephemeralSecrets,
                        offlineCodexSnapshots: offlineCodexSnapshots,
                        liveAntigravity: liveAntigravity
                    )
                    return (account.id, res)
                }
            }
            for await (id, res) in group {
                results[id] = res
            }
        }
        return results
    }

    private func fetchQuota(
        for account: ProviderAccountConfig,
        ephemeralSecrets: [String: String],
        offlineCodexSnapshots: [String: OfflineCodexRateLimit],
        liveAntigravity: [LiveAntigravityStatus]
    ) async -> ProviderQuotaResult {
        switch account.provider {
        case .codex:
            return await fetchCodexQuota(
                account: account,
                ephemeralSecrets: ephemeralSecrets,
                offlineSnapshots: offlineCodexSnapshots
            )
        case .mimo:
            return await fetchMiMoQuota(account: account, ephemeralSecrets: ephemeralSecrets)
        case .kimi:
            return await fetchKimiQuota(account: account, ephemeralSecrets: ephemeralSecrets)
        case .minimax:
            return await fetchMiniMaxQuota(account: account, ephemeralSecrets: ephemeralSecrets)
        case .antigravity:
            return await fetchAntigravityQuota(
                account: account,
                ephemeralSecrets: ephemeralSecrets,
                liveStatuses: liveAntigravity
            )
        }
    }

    // MARK: - 1. OpenAI Codex

    private func fetchCodexQuota(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String],
        offlineSnapshots: [String: OfflineCodexRateLimit]
    ) async -> ProviderQuotaResult {
        if account.authKind == .localOnly {
            return fallbackCodexOffline(account: account, offlineSnapshots: offlineSnapshots, reason: "仅本地日志模式")
        }
        if account.authKind == .apiKey {
            return fallbackCodexOffline(
                account: account,
                offlineSnapshots: offlineSnapshots,
                reason: "API Key 按量计费（无 5h/7d 订阅配额窗口）"
            )
        }

        do {
            let auth = try await resolveCodexOAuthToken(account: account, ephemeralSecrets: ephemeralSecrets)
            let endpoints = normalizedCodexEndpoints(customBase: account.regionOrBaseURL)

            async let usagePair = fetchCodexEndpointData(
                url: endpoints.usageURL,
                accessToken: auth.accessToken,
                chatgptAccountId: auth.chatgptAccountId,
                extraHeaders: [:]
            )
            async let resetCreditsData = try? fetchCodexEndpointData(
                url: endpoints.resetCreditsURL,
                accessToken: auth.accessToken,
                chatgptAccountId: auth.chatgptAccountId,
                extraHeaders: [
                    "openai-beta": "codex-1",
                    "originator": "Codex Desktop",
                ]
            )

            let (data, statusCode) = try await usagePair
            let rawResetCredits = await resetCreditsData

            guard (200..<300).contains(statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let fallback = fallbackCodexOffline(account: account, offlineSnapshots: offlineSnapshots, reason: nil)
                if !fallback.windows.isEmpty { return fallback }
                return ProviderQuotaResult(errorMessage: "Codex 配额请求返回 HTTP \(statusCode)")
            }

            var windows: [QuotaWindow] = []
            if let rateLimit = json["rate_limit"] as? [String: Any] {
                if let primary = rateLimit["primary_window"] as? [String: Any],
                   let win = buildCodexQuotaWindow(primary, idPrefix: "codex.primary", fallbackLabel: "5h 窗口") {
                    windows.append(win)
                }
                if let secondary = rateLimit["secondary_window"] as? [String: Any],
                   let win = buildCodexQuotaWindow(secondary, idPrefix: "codex.secondary", fallbackLabel: "7d 周限额") {
                    windows.append(win)
                }
            }

            // 解析附加特性独立配额池 (additional_rate_limits)
            if let additional = json["additional_rate_limits"] as? [[String: Any]] {
                for (idx, item) in additional.enumerated() {
                    let featureName = (item["limit_name"] as? String)
                        ?? (item["metered_feature"] as? String)
                        ?? ""
                    if featureName.lowercased() == "bengalfox" { continue }
                    guard let rl = item["rate_limit"] as? [String: Any] else { continue }
                    let cleanPrefix = featureName.isEmpty ? "附加" : featureName
                    if let primary = rl["primary_window"] as? [String: Any],
                       let win = buildCodexQuotaWindow(primary, idPrefix: "codex.add.\(idx).p", fallbackLabel: "\(cleanPrefix) 5h", featurePrefix: cleanPrefix) {
                        windows.append(win)
                    }
                    if let secondary = rl["secondary_window"] as? [String: Any],
                       let win = buildCodexQuotaWindow(secondary, idPrefix: "codex.add.\(idx).s", fallbackLabel: "\(cleanPrefix) 7d", featurePrefix: cleanPrefix) {
                        windows.append(win)
                    }
                }
            }

            let rawPlan = (json["plan_type"] as? String) ?? ""
            let planBadge = formatCodexPlanBadge(rawPlan)

            var walletText: String? = nil
            if let credits = json["credits"] as? [String: Any],
               (credits["unlimited"] as? Bool) != true,
               (credits["has_credits"] as? Bool) == true,
               let bal = credits["balance"] as? String, !bal.isEmpty, bal != "0", bal != "0.00" {
                walletText = "Credits $\(bal)"
            }

            var resetCouponText: String? = nil
            if let rcPair = rawResetCredits,
               (200..<300).contains(rcPair.status),
               let rcJSON = try? JSONSerialization.jsonObject(with: rcPair.data) as? [String: Any] {
                let avail = intValue(rcJSON["available_count"])
                if avail > 0 {
                    resetCouponText = "重置券 ×\(avail)"
                }
            }

            return ProviderQuotaResult(
                resolvedLabel: auth.email,
                resolvedExternalId: auth.chatgptAccountId,
                planBadge: planBadge,
                windows: windows,
                walletBalanceText: walletText,
                resetCreditsText: resetCouponText,
                statusMessage: windows.isEmpty ? "当前套餐暂无滚动速率限制" : nil
            )
        } catch {
            var fallback = fallbackCodexOffline(account: account, offlineSnapshots: offlineSnapshots, reason: nil)
            if !fallback.windows.isEmpty {
                fallback.statusMessage = "离线快照（在线刷新失败: \(error.localizedDescription)）"
                return fallback
            }
            return ProviderQuotaResult(errorMessage: error.localizedDescription)
        }
    }

    private func fetchCodexEndpointData(
        url: URL,
        accessToken: String,
        chatgptAccountId: String?,
        extraHeaders: [String: String]
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = chatgptAccountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func buildCodexQuotaWindow(
        _ winDict: [String: Any],
        idPrefix: String,
        fallbackLabel: String,
        featurePrefix: String? = nil
    ) -> QuotaWindow? {
        guard winDict["used_percent"] != nil else { return nil }
        let used = doubleValue(winDict["used_percent"])
        let resetAt = epochSecondsDate(winDict["reset_at"])
            ?? (doubleValue(winDict["reset_after_seconds"]) > 0
                ? Date().addingTimeInterval(doubleValue(winDict["reset_after_seconds"]))
                : nil)
        let winSec = intValue(winDict["limit_window_seconds"])
        let winMin = winSec > 0 ? Int(round(Double(winSec) / 60.0)) : 0
        let durationLabel: String = {
            if winMin >= 43_200 { return "月度限额" }
            if winMin >= 10_080 { return "7d 周限额" }
            if winMin >= 1_440 { return "24h 日限额" }
            if winMin > 0 { return "5h 窗口" }
            return fallbackLabel
        }()
        let finalLabel = featurePrefix.map { "\($0) · \(durationLabel)" } ?? durationLabel
        return QuotaWindow(
            id: idPrefix,
            label: finalLabel,
            usedPercent: used,
            detailText: String(format: "剩余 %.0f%%", max(0, 100 - used)),
            resetAt: resetAt
        )
    }

    private func fallbackCodexOffline(
        account: ProviderAccountConfig,
        offlineSnapshots: [String: OfflineCodexRateLimit],
        reason: String?
    ) -> ProviderQuotaResult {
        let snap: OfflineCodexRateLimit? = {
            if let ext = account.externalAccountId, let matched = offlineSnapshots[ext] {
                return matched
            }
            return offlineSnapshots["__default__"]
        }()

        guard let snap else {
            return ProviderQuotaResult(statusMessage: reason ?? "已启用本地会话统计")
        }

        var windows: [QuotaWindow] = []
        if let p = snap.primaryUsedPercent {
            windows.append(QuotaWindow(
                id: "codex.5h",
                label: "5h 窗口",
                usedPercent: p,
                detailText: String(format: "剩余 %.0f%%", max(0, 100 - p)),
                resetAt: snap.primaryResetAt
            ))
        }
        if let s = snap.secondaryUsedPercent {
            windows.append(QuotaWindow(
                id: "codex.7d",
                label: "7d 周限额",
                usedPercent: s,
                detailText: String(format: "剩余 %.0f%%", max(0, 100 - s)),
                resetAt: snap.secondaryResetAt
            ))
        }

        return ProviderQuotaResult(
            planBadge: snap.planType.flatMap(formatCodexPlanBadge),
            windows: windows,
            statusMessage: reason ?? "来自本地会话缓存快照"
        )
    }

    private func formatCodexPlanBadge(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "": return nil
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "max": return "Max"
        case "plus": return "Plus"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "business": return "Business"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    private func normalizedCodexEndpoints(customBase: String?) -> (usageURL: URL, resetCreditsURL: URL) {
        let configuredBase: String? = {
            if let customBase, customBase.lowercased().hasPrefix("http") {
                return customBase
            }
            let cfgURL = CodexAccountSwitchService.codexHomeDirectory().appendingPathComponent("config.toml")
            if let text = try? String(contentsOf: cfgURL, encoding: .utf8),
               let base = AccountDiscoveryService.extractTOMLValue(key: "chatgpt_base_url", in: text),
               base.lowercased().hasPrefix("http") {
                return base
            }
            return nil
        }()

        if let raw = configuredBase?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !raw.isEmpty {
            if raw.contains("/backend-api") {
                let u = URL(string: raw.hasSuffix("/usage") ? raw : "\(raw)/wham/usage")
                    ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!
                let rc = URL(string: "\(raw)/wham/rate-limit-reset-credits")
                    ?? URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
                return (u, rc)
            } else {
                let u = URL(string: raw.hasSuffix("/usage") ? raw : "\(raw)/api/codex/usage")
                    ?? URL(string: "https://chatgpt.com/backend-api/wham/usage")!
                let rc = URL(string: "\(raw)/api/codex/rate-limit-reset-credits")
                    ?? URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
                return (u, rc)
            }
        }
        return (
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        )
    }

    private struct ResolvedCodexAuth {
        let accessToken: String
        let chatgptAccountId: String?
        let email: String?
    }

    private func resolveCodexOAuthToken(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async throws -> ResolvedCodexAuth {
        let now = Date()

        // 1. 内存缓存未过期则直接复用
        if let cached = cachedAccessTokens[account.id], cached.expiry > now.addingTimeInterval(60) {
            return ResolvedCodexAuth(
                accessToken: cached.token,
                chatgptAccountId: account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(cached.token),
                email: AccountDiscoveryService.extractEmailFromJWT(cached.token)
            )
        }

        // 2. 若活跃 ~/.codex/auth.json 里已有未过期 access_token，直接使用避免触发 refresh_token 轮换
        if let liveAccess = ephemeralSecrets["\(account.id).live_access"],
           let exp = AccountDiscoveryService.extractJWTExpiration(liveAccess),
           exp > now.addingTimeInterval(60) {
            cachedAccessTokens[account.id] = (liveAccess, exp)
            return ResolvedCodexAuth(
                accessToken: liveAccess,
                chatgptAccountId: account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(liveAccess),
                email: AccountDiscoveryService.extractEmailFromJWT(liveAccess)
            )
        }

        // 3. 手动账号：从 Keychain 解析（支持完整 auth.json、JWT access_token 或纯 refresh_token）
        if account.source == .manual {
            guard let raw = KeychainStore.loadSecret(for: account.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                throw QuotaError.missingCredential("未找到手动配置的 Codex 凭证")
            }
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let tokens = (json["tokens"] as? [String: Any]) ?? json
                let access = tokens["access_token"] as? String
                let refresh = tokens["refresh_token"] as? String
                let acctId = (tokens["account_id"] as? String)
                    ?? (tokens["chatgpt_account_id"] as? String)
                    ?? account.externalAccountId
                if let access,
                   let exp = AccountDiscoveryService.extractJWTExpiration(access),
                   exp > now.addingTimeInterval(60) {
                    cachedAccessTokens[account.id] = (access, exp)
                    return ResolvedCodexAuth(
                        accessToken: access,
                        chatgptAccountId: acctId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(access),
                        email: AccountDiscoveryService.extractEmailFromJWT(access)
                    )
                }
                if let refresh, !refresh.isEmpty {
                    let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
                    // 写回 Keychain 以保存旋转后的 refresh_token
                    var updatedTokens = tokens
                    updatedTokens["access_token"] = refreshed.accessToken
                    if let newRefresh = refreshed.refreshToken { updatedTokens["refresh_token"] = newRefresh }
                    if let newId = refreshed.idToken { updatedTokens["id_token"] = newId }
                    if let updatedData = try? JSONSerialization.data(withJSONObject: updatedTokens),
                       let updatedStr = String(data: updatedData, encoding: .utf8) {
                        try? KeychainStore.saveSecret(updatedStr, for: account.id)
                    }
                    let exp = AccountDiscoveryService.extractJWTExpiration(refreshed.accessToken) ?? now.addingTimeInterval(3500)
                    cachedAccessTokens[account.id] = (refreshed.accessToken, exp)
                    return ResolvedCodexAuth(
                        accessToken: refreshed.accessToken,
                        chatgptAccountId: acctId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(refreshed.accessToken),
                        email: AccountDiscoveryService.extractEmailFromJWT(refreshed.idToken ?? refreshed.accessToken)
                    )
                }
            }
            if raw.hasPrefix("eyJ") {
                return ResolvedCodexAuth(
                    accessToken: raw,
                    chatgptAccountId: account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(raw),
                    email: AccountDiscoveryService.extractEmailFromJWT(raw)
                )
            }
            // 当作纯 refresh_token 处理
            let refreshed = try await refreshOpenAIToken(refreshToken: raw)
            if let newRefresh = refreshed.refreshToken, newRefresh != raw {
                try? KeychainStore.saveSecret(newRefresh, for: account.id)
            }
            let exp = AccountDiscoveryService.extractJWTExpiration(refreshed.accessToken) ?? now.addingTimeInterval(3500)
            cachedAccessTokens[account.id] = (refreshed.accessToken, exp)
            return ResolvedCodexAuth(
                accessToken: refreshed.accessToken,
                chatgptAccountId: account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(refreshed.accessToken),
                email: AccountDiscoveryService.extractEmailFromJWT(refreshed.idToken ?? refreshed.accessToken)
            )
        }

        // 4. 自动发现账号：重新读取磁盘文件（防止外部 CLI 已轮换 token）
        guard let credPath = account.credentialFilePath else {
            throw QuotaError.missingCredential("缺少 Codex OAuth 凭证路径")
        }
        let fileURL = URL(fileURLWithPath: credPath)
        guard var root = AccountDiscoveryService.readJSONDictionary(at: fileURL) else {
            throw QuotaError.missingCredential("无法读取 \(fileURL.lastPathComponent)")
        }

        // Case A: ~/.cc-switch/codex_oauth_auth.json
        if var accountsMap = root["accounts"] as? [String: Any],
           let lookupKey = account.credentialLookupKey,
           var entry = accountsMap[lookupKey] as? [String: Any] {
            guard let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty else {
                throw QuotaError.missingCredential("codex_oauth_auth 缺少 refresh_token")
            }
            let chatgptAcctId = (entry["chatgpt_account_id"] as? String)
                ?? (entry["account_id"] as? String)
                ?? account.externalAccountId
            let refreshed = try await refreshOpenAIToken(refreshToken: refreshToken)
            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                entry["refresh_token"] = newRefresh
            }
            if let newIdToken = refreshed.idToken, !newIdToken.isEmpty {
                entry["id_token"] = newIdToken
            }
            entry["token_updated_at_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            accountsMap[lookupKey] = entry
            root["accounts"] = accountsMap
            writeJSONAtomically(root, to: fileURL, permissions: 0o600)

            let exp = AccountDiscoveryService.extractJWTExpiration(refreshed.accessToken) ?? now.addingTimeInterval(3500)
            cachedAccessTokens[account.id] = (refreshed.accessToken, exp)
            return ResolvedCodexAuth(
                accessToken: refreshed.accessToken,
                chatgptAccountId: chatgptAcctId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(refreshed.accessToken),
                email: (entry["email"] as? String) ?? AccountDiscoveryService.extractEmailFromJWT(refreshed.idToken)
            )
        }

        // Case B: ~/.codex/auth.json
        if var tokens = root["tokens"] as? [String: Any] {
            if let access = tokens["access_token"] as? String,
               let exp = AccountDiscoveryService.extractJWTExpiration(access),
               exp > now.addingTimeInterval(60) {
                cachedAccessTokens[account.id] = (access, exp)
                return ResolvedCodexAuth(
                    accessToken: access,
                    chatgptAccountId: (tokens["account_id"] as? String) ?? account.externalAccountId,
                    email: AccountDiscoveryService.extractEmailFromJWT(tokens["id_token"] as? String)
                )
            }
            guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
                throw QuotaError.missingCredential("auth.json 缺少 refresh_token")
            }
            let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
            tokens["access_token"] = refreshed.accessToken
            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                tokens["refresh_token"] = newRefresh
            }
            if let newId = refreshed.idToken, !newId.isEmpty {
                tokens["id_token"] = newId
            }
            root["tokens"] = tokens
            root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            writeJSONAtomically(root, to: fileURL, permissions: 0o600)

            let exp = AccountDiscoveryService.extractJWTExpiration(refreshed.accessToken) ?? now.addingTimeInterval(3500)
            cachedAccessTokens[account.id] = (refreshed.accessToken, exp)
            return ResolvedCodexAuth(
                accessToken: refreshed.accessToken,
                chatgptAccountId: (tokens["account_id"] as? String) ?? account.externalAccountId,
                email: AccountDiscoveryService.extractEmailFromJWT(refreshed.idToken ?? refreshed.accessToken)
            )
        }

        // Case C: ~/.cc-switch/codex-login-stash.json
        if var logins = root["logins"] as? [String: Any],
           let lookupKey = account.credentialLookupKey,
           var loginObj = logins[lookupKey] as? [String: Any],
           var tokens = loginObj["tokens"] as? [String: Any] {
            if let access = tokens["access_token"] as? String,
               let exp = AccountDiscoveryService.extractJWTExpiration(access),
               exp > now.addingTimeInterval(60) {
                cachedAccessTokens[account.id] = (access, exp)
                return ResolvedCodexAuth(
                    accessToken: access,
                    chatgptAccountId: (tokens["account_id"] as? String) ?? account.externalAccountId,
                    email: AccountDiscoveryService.extractEmailFromJWT(tokens["id_token"] as? String)
                )
            }
            guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
                throw QuotaError.missingCredential("stash 缺少 refresh_token")
            }
            let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
            tokens["access_token"] = refreshed.accessToken
            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                tokens["refresh_token"] = newRefresh
            }
            if let newId = refreshed.idToken, !newId.isEmpty {
                tokens["id_token"] = newId
            }
            loginObj["tokens"] = tokens
            logins[lookupKey] = loginObj
            root["logins"] = logins
            writeJSONAtomically(root, to: fileURL, permissions: 0o600)

            let exp = AccountDiscoveryService.extractJWTExpiration(refreshed.accessToken) ?? now.addingTimeInterval(3500)
            cachedAccessTokens[account.id] = (refreshed.accessToken, exp)
            return ResolvedCodexAuth(
                accessToken: refreshed.accessToken,
                chatgptAccountId: (tokens["account_id"] as? String) ?? account.externalAccountId,
                email: AccountDiscoveryService.extractEmailFromJWT(refreshed.idToken ?? refreshed.accessToken)
            )
        }

        throw QuotaError.missingCredential("未能解析 Codex OAuth 凭证结构")
    }

    private func refreshOpenAIToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, idToken: String?) {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload: [String: String] = [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw QuotaError.authFailed("Codex Token 刷新失败 (HTTP \(status))")
        }
        return (
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            idToken: json["id_token"] as? String
        )
    }

    /// 导出指定 Codex 账号为完整 `$CODEX_HOME/auth.json` UTF-8 JSON 数据（符合 Swift 6 Actor Sendable 隔离）
    func exportCodexAuthJSONData(for account: ProviderAccountConfig) async throws -> Data {
        let payload = try await exportCodexAuthJSONPayload(for: account)
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func exportCodexAuthJSONPayload(for account: ProviderAccountConfig) async throws -> [String: Any] {
        let now = Date()

        // 1. 手动存储在 Keychain 中的完整 JSON 或 Refresh Token
        if let raw = KeychainStore.loadSecret(for: account.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if raw.hasPrefix("{"),
               let data = raw.data(using: .utf8),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if var tokens = json["tokens"] as? [String: Any] {
                    let access = tokens["access_token"] as? String
                    let exp = AccountDiscoveryService.extractJWTExpiration(access)
                    if access == nil || exp == nil || exp! <= now.addingTimeInterval(60) {
                        if let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty {
                            let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
                            tokens["access_token"] = refreshed.accessToken
                            if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                                tokens["refresh_token"] = newRefresh
                            }
                            if let newId = refreshed.idToken, !newId.isEmpty {
                                tokens["id_token"] = newId
                            }
                        }
                    }
                    if tokens["account_id"] == nil,
                       let acctId = account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(tokens["access_token"] as? String) {
                        tokens["account_id"] = acctId
                    }
                    json["tokens"] = tokens
                    json["auth_mode"] = (json["auth_mode"] as? String) ?? "chatgpt"
                    if json["OPENAI_API_KEY"] == nil { json["OPENAI_API_KEY"] = NSNull() }
                    json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
                    return json
                }
            } else if !raw.hasPrefix("eyJ") {
                let refreshed = try await refreshOpenAIToken(refreshToken: raw)
                var tokens: [String: Any] = [
                    "access_token": refreshed.accessToken,
                    "refresh_token": refreshed.refreshToken ?? raw,
                ]
                if let idTok = refreshed.idToken { tokens["id_token"] = idTok }
                if let acctId = account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(refreshed.accessToken) {
                    tokens["account_id"] = acctId
                }
                return [
                    "auth_mode": "chatgpt",
                    "OPENAI_API_KEY": NSNull(),
                    "tokens": tokens,
                    "last_refresh": ISO8601DateFormatter().string(from: Date()),
                ]
            }
        }

        // 2. 磁盘凭证文件（auth.json / codex_oauth_auth.json / codex-login-stash.json / managed-codex-homes）
        guard let credPath = account.credentialFilePath else {
            throw QuotaError.missingCredential("该 Codex 账号没有可导出的 OAuth 凭证文件")
        }
        let fileURL = URL(fileURLWithPath: credPath)
        guard var root = AccountDiscoveryService.readJSONDictionary(at: fileURL) else {
            throw QuotaError.missingCredential("无法读取凭证文件: \(fileURL.lastPathComponent)")
        }

        // Case A: ~/.cc-switch/codex_oauth_auth.json
        if var accountsMap = root["accounts"] as? [String: Any],
           let lookupKey = account.credentialLookupKey,
           var entry = accountsMap[lookupKey] as? [String: Any] {
            guard let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty else {
                throw QuotaError.missingCredential("codex_oauth_auth 缺少 refresh_token")
            }
            let refreshed = try await refreshOpenAIToken(refreshToken: refreshToken)
            let finalRefresh = refreshed.refreshToken ?? refreshToken
            let finalIdToken = refreshed.idToken ?? (entry["id_token"] as? String)
            entry["refresh_token"] = finalRefresh
            if let finalIdToken { entry["id_token"] = finalIdToken }
            entry["token_updated_at_ms"] = Int(Date().timeIntervalSince1970 * 1000)
            accountsMap[lookupKey] = entry
            root["accounts"] = accountsMap
            writeJSONAtomically(root, to: fileURL, permissions: 0o600)

            var tokens: [String: Any] = [
                "access_token": refreshed.accessToken,
                "refresh_token": finalRefresh,
            ]
            if let finalIdToken { tokens["id_token"] = finalIdToken }
            if let acctId = (entry["chatgpt_account_id"] as? String)
                ?? (entry["account_id"] as? String)
                ?? account.externalAccountId
                ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(refreshed.accessToken) {
                tokens["account_id"] = acctId
            }
            return [
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": NSNull(),
                "tokens": tokens,
                "last_refresh": ISO8601DateFormatter().string(from: Date()),
            ]
        }

        // Case B: auth.json (含 managed-codex-homes/<id>/auth.json)
        if var tokens = root["tokens"] as? [String: Any] {
            let access = tokens["access_token"] as? String
            let exp = AccountDiscoveryService.extractJWTExpiration(access)
            if access == nil || exp == nil || exp! <= now.addingTimeInterval(60) {
                guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
                    throw QuotaError.missingCredential("auth.json 缺少 refresh_token")
                }
                let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
                tokens["access_token"] = refreshed.accessToken
                if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                    tokens["refresh_token"] = newRefresh
                }
                if let newId = refreshed.idToken, !newId.isEmpty {
                    tokens["id_token"] = newId
                }
                root["tokens"] = tokens
                root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
                writeJSONAtomically(root, to: fileURL, permissions: 0o600)
            }
            if tokens["account_id"] == nil,
               let acctId = account.externalAccountId ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(tokens["access_token"] as? String) {
                tokens["account_id"] = acctId
            }
            return [
                "auth_mode": (root["auth_mode"] as? String) ?? "chatgpt",
                "OPENAI_API_KEY": root["OPENAI_API_KEY"] ?? NSNull(),
                "tokens": tokens,
                "last_refresh": (root["last_refresh"] as? String) ?? ISO8601DateFormatter().string(from: Date()),
            ]
        }

        // Case C: ~/.cc-switch/codex-login-stash.json
        if var logins = root["logins"] as? [String: Any],
           let lookupKey = account.credentialLookupKey,
           var loginObj = logins[lookupKey] as? [String: Any],
           var tokens = loginObj["tokens"] as? [String: Any] {
            let access = tokens["access_token"] as? String
            let exp = AccountDiscoveryService.extractJWTExpiration(access)
            if access == nil || exp == nil || exp! <= now.addingTimeInterval(60) {
                guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
                    throw QuotaError.missingCredential("stash 缺少 refresh_token")
                }
                let refreshed = try await refreshOpenAIToken(refreshToken: refresh)
                tokens["access_token"] = refreshed.accessToken
                if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
                    tokens["refresh_token"] = newRefresh
                }
                if let newId = refreshed.idToken, !newId.isEmpty {
                    tokens["id_token"] = newId
                }
                loginObj["tokens"] = tokens
                logins[lookupKey] = loginObj
                root["logins"] = logins
                writeJSONAtomically(root, to: fileURL, permissions: 0o600)
            }
            return [
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": NSNull(),
                "tokens": tokens,
                "last_refresh": ISO8601DateFormatter().string(from: Date()),
            ]
        }

        throw QuotaError.missingCredential("未能从 \(fileURL.lastPathComponent) 导出 Codex OAuth 凭证")
    }

    // MARK: - 2. Xiaomi MiMo Token Plan & Desktop Membership

    private static let mimoNoPlanCodes: Set<String> = [
        "default", "none", "no_plan", "not_subscribed", "unsubscribed"
    ]

    private func fetchMiMoQuota(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async -> ProviderQuotaResult {
        // 1. 收集手动关联/保存的控制台 Cookie 与本机 Xiaomi MiMo.app 通行证 SSO Seed
        let attachedCookie = KeychainStore.loadSecret(for: SettingsManager.cookieKeychainKey(for: account.id))
        let directSecret = (account.authKind == .cookie)
            ? (KeychainStore.loadSecret(for: account.id) ?? ephemeralSecrets[account.id])
            : nil
        let rawManualCookie = [attachedCookie, directSecret]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let desktopSeedRaw = ephemeralSecrets["\(account.id).xiaomi_account"]
        let accountSeed = rawManualCookie.flatMap { MimoSessionMinter.extractAccountSeed(from: $0) }
            ?? desktopSeedRaw.flatMap { MimoSessionMinter.extractAccountSeed(from: $0) }
        let seedCacheKey = accountSeed.map { "mimo_seed:\($0.userId)" } ?? account.id

        let directConsoleCookie = rawManualCookie.flatMap { normalizeMiMoConsoleCookie($0, fallbackUserId: account.externalAccountId) }
        let hasAnyAuth = (directConsoleCookie != nil) || (accountSeed != nil)

        guard hasAnyAuth else {
            return ProviderQuotaResult(
                planBadge: "Token Plan",
                windows: [],
                statusMessage: "本地 Token 统计已启用 · 登录 Xiaomi MiMo 桌面端或在设置中登录小米控制台可查看套餐进度条",
                hasCustomConsoleAuth: false
            )
        }

        var windows: [QuotaWindow] = []
        var planBadge: String? = nil
        var walletBalanceText: String? = nil
        var resolvedLabel: String? = nil
        var consoleError: String? = nil

        // 2. 开放平台控制台查询（支持直接 Cookie 或由 passToken 无感换取，401/46109 自动重换一次）
        do {
            var activeConsoleCookie = directConsoleCookie ?? cachedMiMoConsoleSessions[seedCacheKey]
            if activeConsoleCookie == nil, let seed = accountSeed {
                if let minted = await MimoSessionMinter.mintConsoleSession(seed: seed)?.cookieHeader {
                    cachedMiMoConsoleSessions[seedCacheKey] = minted
                    activeConsoleCookie = minted
                }
            }

            if let initialCookie = activeConsoleCookie {
                let snapshot: MiMoConsolePayload
                do {
                    snapshot = try await loadMiMoConsolePayload(cookie: initialCookie)
                } catch QuotaError.authFailed(let msg) where accountSeed != nil {
                    cachedMiMoConsoleSessions.removeValue(forKey: seedCacheKey)
                    guard let reminted = await MimoSessionMinter.mintConsoleSession(seed: accountSeed!)?.cookieHeader else {
                        throw QuotaError.authFailed(msg)
                    }
                    cachedMiMoConsoleSessions[seedCacheKey] = reminted
                    snapshot = try await loadMiMoConsolePayload(cookie: reminted)
                }

                if let nick = snapshot.nickName, !nick.isEmpty {
                    resolvedLabel = nick
                } else if let email = snapshot.email, !email.isEmpty {
                    resolvedLabel = email
                }

                if let bal = snapshot.balanceAmount {
                    let symbol = (snapshot.currency == "USD") ? "$" : "¥"
                    walletBalanceText = String(format: "余额 %@%.2f", symbol, bal)
                }

                if snapshot.hasActivePlan, let pWin = snapshot.planWindow {
                    windows.append(pWin)
                    if let compWin = snapshot.compensationWindow {
                        windows.append(compWin)
                    }
                    planBadge = snapshot.planLabel ?? "Token Plan"
                } else if snapshot.isExpiredPlan {
                    planBadge = "\(snapshot.planLabel ?? "Token Plan") (已到期)"
                } else if snapshot.balanceAmount != nil {
                    planBadge = "按量计费"
                }
            }
        } catch {
            consoleError = error.localizedDescription
        }

        // 3. Xiaomi MiMo 桌面端会员周额度查询（若存在通行证 passToken Seed）
        if let seed = accountSeed {
            if let membershipResult = await fetchMiMoDesktopMembership(seed: seed, cacheKey: seedCacheKey) {
                windows.append(membershipResult.window)
                if planBadge == nil || planBadge == "按量计费" {
                    planBadge = membershipResult.planBadge
                } else if let badge = planBadge, !badge.contains(membershipResult.tierShort) {
                    planBadge = "\(badge) · \(membershipResult.tierShort)"
                }
            }
        }

        let hasCustomAuth = (rawManualCookie != nil)
        if windows.isEmpty && walletBalanceText == nil, let consoleError {
            return ProviderQuotaResult(
                resolvedLabel: resolvedLabel,
                planBadge: planBadge ?? "MiMo",
                errorMessage: "小米套餐查询失败: \(consoleError)",
                hasCustomConsoleAuth: hasCustomAuth
            )
        }

        let statusMsg: String? = windows.isEmpty
            ? (walletBalanceText != nil ? "当前未开通活跃套餐 · 已同步开放平台余额" : "当前未开通活跃 Token Plan 套餐")
            : nil

        return ProviderQuotaResult(
            resolvedLabel: resolvedLabel,
            planBadge: planBadge ?? "Token Plan",
            windows: windows,
            walletBalanceText: walletBalanceText,
            statusMessage: statusMsg,
            hasCustomConsoleAuth: hasCustomAuth
        )
    }

    private struct MiMoConsolePayload {
        var nickName: String?
        var email: String?
        var balanceAmount: Double?
        var currency: String = "CNY"
        var planLabel: String?
        var hasActivePlan: Bool = false
        var isExpiredPlan: Bool = false
        var planWindow: QuotaWindow?
        var compensationWindow: QuotaWindow?
    }

    private func loadMiMoConsolePayload(cookie: String) async throws -> MiMoConsolePayload {
        async let balanceTask = fetchMiMoConsoleData(path: "/api/v1/balance", cookie: cookie)
        async let profileTask = try? fetchMiMoConsoleData(path: "/api/v1/userProfile", cookie: cookie)
        async let detailTask = try? fetchMiMoConsoleData(path: "/api/v1/tokenPlan/detail", cookie: cookie)
        async let usageTask = try? fetchMiMoConsoleData(path: "/api/v1/tokenPlan/usage", cookie: cookie)

        // /balance 兼具会话有效性探测与钱包余额读取
        let balanceData = try await balanceTask
        let profileData = await profileTask
        let detailDataRaw = await detailTask
        let usageDataRaw = await usageTask

        guard let balanceJSON = try? JSONSerialization.jsonObject(with: balanceData) as? [String: Any] else {
            throw QuotaError.invalidResponse("MiMo balance 响应解析失败")
        }
        let profileJSON = profileData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let detailJSON = detailDataRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let usageJSON = usageDataRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        var out = MiMoConsolePayload()
        let balData = (balanceJSON["data"] as? [String: Any]) ?? balanceJSON
        if let rawBal = optionalDoubleValue(balData["balance"]) {
            out.balanceAmount = rawBal
            if let cur = (balData["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
               !cur.isEmpty {
                out.currency = cur
            }
        }

        if let profData = (profileJSON?["data"] as? [String: Any]) ?? profileJSON {
            let nick = ((profData["nickName"] as? String) ?? (profData["userName"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let email = ((profData["email"] as? String) ?? (profData["platformEmail"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let nick, !nick.isEmpty { out.nickName = nick }
            if let email, !email.isEmpty { out.email = email }
        }

        let now = Date()
        var periodEnd: Date? = nil
        var detailActive = false
        var detailExpired = false
        var detailLabel: String? = nil

        if let detailData = (detailJSON?["data"] as? [String: Any]) ?? detailJSON {
            let rawLabel = ((detailData["planName"] as? String)
                ?? (detailData["plan_name"] as? String)
                ?? (detailData["planCode"] as? String)
                ?? (detailData["plan_code"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normLabel = rawLabel.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            let rawStatus = (((detailData["planStatus"] as? String)
                ?? (detailData["plan_status"] as? String)
                ?? (detailData["subscriptionStatus"] as? String)
                ?? (detailData["status"] as? String)
                ?? (detailData["state"] as? String)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let endAny = detailData["currentPeriodEnd"] ?? detailData["current_period_end"]
            periodEnd = parseMiMoEndpointDate(endAny)

            let isNoPlan = Self.mimoNoPlanCodes.contains(normLabel) || Self.mimoNoPlanCodes.contains(rawStatus)
            let hasRealIdentity = !normLabel.isEmpty && !Self.mimoNoPlanCodes.contains(normLabel)
            if hasRealIdentity {
                detailLabel = rawLabel
            }

            let explicitActive = (rawStatus == "active" || rawStatus == "subscribed")
                || (detailData["active"] as? Bool == true)
                || (detailData["isActive"] as? Bool == true)
            let explicitExpired = (rawStatus == "expired" || rawStatus == "ended")
                || (detailData["expired"] as? Bool == true)
            let hasFutureEnd = periodEnd.map { $0 > now } ?? false
            let hasPastEnd = periodEnd.map { $0 <= now } ?? false
            let hasStatusField = !rawStatus.isEmpty || (detailData["active"] is Bool) || (detailData["isActive"] is Bool)

            detailExpired = !isNoPlan && (explicitExpired || (hasRealIdentity && hasPastEnd))
            detailActive = !isNoPlan && !detailExpired && (explicitActive || (!hasStatusField && hasRealIdentity && hasFutureEnd))
        }

        out.planLabel = detailLabel

        // 解析 /tokenPlan/usage：兼容新版 data.monthUsage.items (month_total_token) 与旧版 data.usage.items (plan_total_token)
        if let usageData = (usageJSON?["data"] as? [String: Any]) ?? usageJSON {
            let container = (usageData["monthUsage"] as? [String: Any])
                ?? (usageData["month_usage"] as? [String: Any])
                ?? (usageData["usage"] as? [String: Any])
                ?? (usageData["planUsage"] as? [String: Any])

            let items = (container?["items"] as? [[String: Any]]) ?? []
            let totalNames: Set<String> = [
                "month_total_token", "monthly_total_token", "plan_total_token", "total_token", "tokens"
            ]

            var matchedPlanWindow: QuotaWindow? = nil
            var matchedCompWindow: QuotaWindow? = nil

            for item in items {
                let name = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let used = optionalDoubleValue(item["used"])
                let limit = optionalDoubleValue(item["limit"])
                guard let usedPct = normalizeMiMoRatioPercent(rawPercent: item["percent"], used: used, limit: limit) else {
                    continue
                }
                let limitInt = Int(limit ?? 0)
                let usedInt = Int(used ?? 0)

                if totalNames.contains(name), limitInt > 0 {
                    let detail = "\(NumberFormatterUtil.formatCompact(usedInt)) / \(NumberFormatterUtil.formatCompact(limitInt))"
                    let winLabel = name.contains("month") ? "月度套餐额度" : "套餐总额度"
                    matchedPlanWindow = QuotaWindow(
                        id: "mimo.plan_total",
                        label: winLabel,
                        usedPercent: usedPct,
                        detailText: detail,
                        resetAt: periodEnd
                    )
                } else if name == "compensation_total_token", limitInt > 0 {
                    matchedCompWindow = QuotaWindow(
                        id: "mimo.compensation",
                        label: "补偿额度包",
                        usedPercent: usedPct,
                        detailText: "\(NumberFormatterUtil.formatCompact(usedInt)) / \(NumberFormatterUtil.formatCompact(limitInt))",
                        resetAt: periodEnd
                    )
                }
            }

            // 兼容直接在 monthUsage 顶层返回 used/limit/percent 的无 items 结构
            if matchedPlanWindow == nil, items.isEmpty, let container {
                let used = optionalDoubleValue(container["used"])
                let limit = optionalDoubleValue(container["limit"])
                if let limit, limit > 0,
                   let usedPct = normalizeMiMoRatioPercent(rawPercent: container["percent"], used: used, limit: limit) {
                    matchedPlanWindow = QuotaWindow(
                        id: "mimo.plan_total",
                        label: "月度套餐额度",
                        usedPercent: usedPct,
                        detailText: "\(NumberFormatterUtil.formatCompact(Int(used ?? 0))) / \(NumberFormatterUtil.formatCompact(Int(limit)))",
                        resetAt: periodEnd
                    )
                }
            }

            if let matchedPlanWindow {
                // 若 detail 未明确标记 expired，且 usage 给出了有效配额，则视为活跃套餐
                if detailActive || (!detailExpired && detailJSON == nil) || (!detailExpired && detailLabel != nil) {
                    out.hasActivePlan = true
                    out.planWindow = matchedPlanWindow
                    out.compensationWindow = matchedCompWindow
                } else if detailExpired {
                    out.isExpiredPlan = true
                }
            } else if detailExpired {
                out.isExpiredPlan = true
            }
        }

        return out
    }

    /// MiMo 接口中的 `percent` 始终为 0..1 比例（超额时如 1.005 代表 100.5% 已耗尽，绝不可误判为 1.005%！）
    private func normalizeMiMoRatioPercent(rawPercent: Any?, used: Double?, limit: Double?) -> Double? {
        if let used, let limit, limit > 0 {
            return min(100.0, max(0.0, (used / limit) * 100.0))
        }
        guard let explicit = optionalDoubleValue(rawPercent) else { return nil }
        return min(100.0, max(0.0, explicit * 100.0))
    }

    private func parseMiMoEndpointDate(_ any: Any?) -> Date? {
        guard let any else { return nil }
        if let str = any as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let num = Double(trimmed), num > 0 {
                return Date(timeIntervalSince1970: num > 1_000_000_000_000 ? num / 1000.0 : num)
            }
            if let d = FastDateParser.parseISO8601(trimmed) {
                return d
            }
            // 兼容小米服务端返回的无时区北京时间字符串 "YYYY-MM-DD HH:mm:ss"
            let normalized = trimmed.replacingOccurrences(of: " ", with: "T")
            if !normalized.hasSuffix("Z") && !normalized.contains("+") {
                if let d = FastDateParser.parseISO8601(normalized + "+08:00") {
                    return d
                }
            }
            return nil
        }
        let num = doubleValue(any)
        guard num > 0 else { return nil }
        return Date(timeIntervalSince1970: num > 1_000_000_000_000 ? num / 1000.0 : num)
    }

    private func normalizeMiMoConsoleCookie(_ raw: String, fallbackUserId: String?) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("cookie:") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.contains("=") {
            guard let uid = fallbackUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                return nil
            }
            return "api-platform_serviceToken=\(cleaned); userId=\(uid)"
        }
        let allowed: Set<String> = ["api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"]
        var map: [String: String] = [:]
        for part in cleaned.split(separator: ";") {
            let seg = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let k = String(seg[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let v = String(seg[seg.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if allowed.contains(k), !v.isEmpty {
                map[k] = v
            }
        }
        if map["userId"] == nil, let uid = fallbackUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
            map["userId"] = uid
        }
        guard map["api-platform_serviceToken"] != nil, map["userId"] != nil else {
            return nil
        }
        return map.keys.sorted().compactMap { k in map[k].map { "\(k)=\($0)" } }.joined(separator: "; ")
    }

    private func fetchMiMoConsoleData(path: String, cookie: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://platform.xiaomimimo.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(MimoSessionMinter.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await noRedirectSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 || (300..<400).contains(status) {
            throw QuotaError.authFailed("小米控制台会话已过期 (HTTP \(status))")
        }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse("小米接口返回 HTTP \(status)")
        }
        let bodyCode = intValue(json["code"], default: 0)
        // 46109 为小米网关在 HTTP 200 下返回的未登录/Token 失效状态码
        if bodyCode == 401 || bodyCode == 403 || bodyCode == 46109 {
            throw QuotaError.authFailed((json["message"] as? String) ?? "小米控制台鉴权失效 (\(bodyCode))")
        }
        if json["code"] != nil && bodyCode != 0 {
            throw QuotaError.invalidResponse((json["message"] as? String) ?? "MiMo code=\(bodyCode)")
        }
        return data
    }

    private func fetchMiMoDesktopMembership(
        seed: MimoSessionMinter.DesktopAccountSeed,
        cacheKey: String
    ) async -> (window: QuotaWindow, planBadge: String, tierShort: String)? {
        do {
            var sessionPair = cachedMiMoMembershipSessions[cacheKey]
            if sessionPair == nil,
               let minted = await MimoSessionMinter.mintMembershipSession(seed: seed) {
                sessionPair = (minted.cookieHeader, minted.region)
                cachedMiMoMembershipSessions[cacheKey] = sessionPair
            }
            guard let initialPair = sessionPair else { return nil }

            let subJSON: [String: Any]
            do {
                subJSON = try await requestMiMoMembershipSubscription(cookie: initialPair.cookie, region: initialPair.region)
            } catch QuotaError.authFailed(_) {
                cachedMiMoMembershipSessions.removeValue(forKey: cacheKey)
                guard let reminted = await MimoSessionMinter.mintMembershipSession(seed: seed) else {
                    return nil
                }
                cachedMiMoMembershipSessions[cacheKey] = (reminted.cookieHeader, reminted.region)
                subJSON = try await requestMiMoMembershipSubscription(cookie: reminted.cookieHeader, region: reminted.region)
            }

            let data = (subJSON["data"] as? [String: Any]) ?? subJSON
            guard let current = data["current"] as? [String: Any] else { return nil }

            let tierCode = intValue(current["planTier"] ?? current["plan_tier"], default: 0)
            let statusStr = ((current["status"] as? String) ?? "").lowercased()
            if statusStr == "expired" || statusStr == "canceled" || statusStr == "none" {
                return nil
            }
            // current.percent 在桌面会员接口中代表【剩余百分比 0..100】
            guard let remainingPct = optionalDoubleValue(current["percent"] ?? current["remainingPercent"]) else {
                return nil
            }
            let clampedRem = min(100.0, max(0.0, remainingPct))
            let usedPct = min(100.0, max(0.0, 100.0 - clampedRem))
            let resetAt = parseMiMoEndpointDate(current["nextResetTime"] ?? current["next_reset_time"] ?? current["resetTime"])

            let tierShort: String = {
                switch tierCode {
                case 1: return "Starter"
                case 2: return "Plus"
                case 3: return "Pro"
                case 4: return "Ultra"
                default:
                    if let name = (current["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        return name
                    }
                    return "会员"
                }
            }()

            let win = QuotaWindow(
                id: "mimo.membership",
                label: "桌面会员周限额",
                usedPercent: usedPct,
                detailText: String(format: "剩余 %.0f%%", clampedRem),
                resetAt: resetAt
            )
            return (win, "MiMo \(tierShort)", tierShort)
        } catch {
            return nil
        }
    }

    private func requestMiMoMembershipSubscription(cookie: String, region: String?) async throws -> [String: Any] {
        let base = (region?.lowercased() == "sg" || region?.lowercased() == "global")
            ? "https://mimo-server-sg.xiaomimimo.com"
            : "https://mimo-server-cn.xiaomimimo.com"
        var req = URLRequest(url: URL(string: "\(base)/api/user/xiaomi/subscription/self")!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(MimoSessionMinter.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await noRedirectSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 || (300..<400).contains(status) {
            throw QuotaError.authFailed("MiMo Membership HTTP \(status)")
        }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse("MiMo Membership HTTP \(status)")
        }
        let code = intValue(json["code"], default: 0)
        if code == 401 || code == 403 || code == 46109 {
            throw QuotaError.authFailed("MiMo Membership code=\(code)")
        }
        return json
    }

    // MARK: - 3. Moonshot Kimi Code & Web Console

    private func fetchKimiQuota(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async -> ProviderQuotaResult {
        if account.authKind == .localOnly {
            return ProviderQuotaResult(statusMessage: "仅本地会话日志模式")
        }

        do {
            // 若是 Web Cookie 凭证（如 kimi-auth=<jwt>），走 Kimi Web Console Billing + Membership 双接口
            if account.authKind == .cookie {
                let rawSecret = KeychainStore.loadSecret(for: account.id) ?? ephemeralSecrets[account.id] ?? ""
                guard let webToken = normalizeKimiWebToken(rawSecret), !webToken.isEmpty else {
                    throw QuotaError.missingCredential("未找到有效的 kimi-auth Web 凭证")
                }
                return try await fetchKimiWebConsoleQuota(webToken: webToken)
            }

            let token = try await resolveKimiToken(account: account, ephemeralSecrets: ephemeralSecrets)

            // 如果用户在 API Key 模式粘贴的是 kimi-auth Cookie 或纯 Web JWT（非 sk- 且无本地 OAuth 文件），自动兼容 Web 路由
            if account.credentialFilePath == nil,
               !token.hasPrefix("sk-"),
               let webToken = normalizeKimiWebToken(token),
               webToken.split(separator: ".").count == 3 {
                if let webRes = try? await fetchKimiWebConsoleQuota(webToken: webToken), !webRes.windows.isEmpty {
                    return webRes
                }
            }

            let baseURL = normalizedKimiBaseURL(account.regionOrBaseURL)
            async let usagesTask = fetchKimiData(url: URL(string: "\(baseURL)/usages")!, token: token)
            async let meTask = try? fetchKimiData(url: URL(string: "\(baseURL)/me")!, token: token)

            let rawUsagesData = try await usagesTask
            let rawMeData = await meTask

            guard let usagesJSON = try? JSONSerialization.jsonObject(with: rawUsagesData) as? [String: Any] else {
                throw QuotaError.invalidResponse("Kimi usages 响应解析失败")
            }
            let meJSON = rawMeData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

            let resolvedName: String? = {
                if let nick = meJSON?["nickname"] as? String, !nick.isEmpty { return nick }
                if let email = meJSON?["email"] as? String, !email.isEmpty { return email }
                return nil
            }()
            let userId = meJSON?["user_id"] as? String
            let planBadge = (meJSON?["user_level_name"] as? String)
                ?? (((usagesJSON["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String)

            let windows = parseKimiUsageWindows(from: usagesJSON)

            return ProviderQuotaResult(
                resolvedLabel: resolvedName,
                resolvedExternalId: userId,
                planBadge: (planBadge?.isEmpty == false) ? planBadge : "Kimi Code",
                windows: windows,
                statusMessage: windows.isEmpty ? "已连接 Kimi Code（暂无配额窗口限制）" : nil
            )
        } catch {
            return ProviderQuotaResult(errorMessage: error.localizedDescription)
        }
    }

    /// 统一解析 Kimi `/coding/v1/usages` 响应（同时保留 5h 窗口、7d 周限额与月度共享池！）
    private func parseKimiUsageWindows(from rawJSON: [String: Any]) -> [QuotaWindow] {
        let body = (rawJSON["data"] as? [String: Any]) ?? rawJSON
        var sessionWin: QuotaWindow? = nil
        var weeklyWin: QuotaWindow? = nil
        var monthlyWin: QuotaWindow? = nil

        // 1. 顶层 `usage`（FEATURE_CODING 权威周限额明细，如 24 / 100）
        if let usage = body["usage"] as? [String: Any],
           let parsed = parseKimiDetailPercent(usage) {
            let name = ((usage["name"] as? String) ?? (usage["label"] as? String) ?? (usage["title"] as? String) ?? "").lowercased()
            let reset = parseISO8601(
                (usage["resetTime"] as? String)
                ?? (usage["reset_time"] as? String)
                ?? (usage["resetAt"] as? String)
                ?? (usage["reset_at"] as? String)
            )
            if name.contains("hour") || name.contains("小时") {
                sessionWin = QuotaWindow(
                    id: "kimi.5h",
                    label: "5h 窗口",
                    usedPercent: parsed.usedPercent,
                    detailText: parsed.detailText,
                    resetAt: reset
                )
            } else {
                weeklyWin = QuotaWindow(
                    id: "kimi.7d",
                    label: "7d 周限额",
                    usedPercent: parsed.usedPercent,
                    detailText: parsed.detailText,
                    resetAt: reset
                )
            }
        }

        // 2. `limits[]`（通过 duration + timeUnit 分类 5h 与 7d）
        let limitsArray = (body["limits"] as? [[String: Any]])
            ?? (body["limitInfos"] as? [[String: Any]])
            ?? (body["rateLimits"] as? [[String: Any]])
            ?? []
        for entry in limitsArray {
            let detail = (entry["detail"] as? [String: Any]) ?? (entry["usage"] as? [String: Any]) ?? entry
            guard let parsed = parseKimiDetailPercent(detail) else { continue }
            let winObj = (entry["window"] as? [String: Any]) ?? (entry["period"] as? [String: Any]) ?? entry
            let duration = optionalDoubleValue(winObj["duration"] ?? winObj["windowDuration"] ?? winObj["size"])
            let unit = ((winObj["timeUnit"] as? String) ?? (winObj["time_unit"] as? String) ?? (winObj["unit"] as? String) ?? "").uppercased()
            let minutes: Double? = {
                guard let duration, duration > 0 else { return nil }
                if unit.contains("MIN") { return duration }
                if unit.contains("HOUR") { return duration * 60 }
                if unit.contains("DAY") { return duration * 1440 }
                if unit.contains("WEEK") { return duration * 10080 }
                if unit.contains("MONTH") { return duration * 43200 }
                return duration
            }()
            let reset = parseISO8601(
                (detail["resetTime"] as? String)
                ?? (detail["reset_time"] as? String)
                ?? (winObj["resetTime"] as? String)
            )
            let isSession = (minutes != nil && minutes! <= 360) || (limitsArray.count == 1 && weeklyWin != nil)
            if isSession {
                if sessionWin == nil {
                    sessionWin = QuotaWindow(
                        id: "kimi.5h",
                        label: "5h 窗口",
                        usedPercent: parsed.usedPercent,
                        detailText: parsed.detailText,
                        resetAt: reset
                    )
                }
            } else if weeklyWin == nil {
                weeklyWin = QuotaWindow(
                    id: "kimi.7d",
                    label: "7d 周限额",
                    usedPercent: parsed.usedPercent,
                    detailText: parsed.detailText,
                    resetAt: reset
                )
            }
        }

        // 3. `usages` 命名比例池（补充 limit_5h、limit_7d，并始终附加 limit_month_total 月度额度池！）
        if let pools = body["usages"] as? [String: Any] {
            if let l5h = pools["limit_5h"] as? [String: Any],
               let ratio = optionalDoubleValue(l5h["used_ratio"] ?? l5h["usedRatio"]), ratio >= 0 {
                let pct = min(100.0, max(0.0, ratio * 100.0))
                let reset = parseISO8601((l5h["reset_time"] as? String) ?? (l5h["resetTime"] as? String))
                if sessionWin == nil {
                    sessionWin = QuotaWindow(
                        id: "kimi.5h",
                        label: "5h 窗口",
                        usedPercent: pct,
                        detailText: String(format: "剩余 %.0f%%", max(0, 100 - pct)),
                        resetAt: reset
                    )
                } else if sessionWin?.resetAt == nil, let s = sessionWin {
                    sessionWin = QuotaWindow(id: s.id, label: s.label, usedPercent: s.usedPercent, detailText: s.detailText, resetAt: reset)
                }
            }

            if let l7d = pools["limit_7d"] as? [String: Any],
               let ratio = optionalDoubleValue(l7d["used_ratio"] ?? l7d["usedRatio"]), ratio >= 0 {
                let pct = min(100.0, max(0.0, ratio * 100.0))
                let reset = parseISO8601((l7d["reset_time"] as? String) ?? (l7d["resetTime"] as? String))
                if weeklyWin == nil {
                    weeklyWin = QuotaWindow(
                        id: "kimi.7d",
                        label: "7d 周限额",
                        usedPercent: pct,
                        detailText: String(format: "剩余 %.0f%%", max(0, 100 - pct)),
                        resetAt: reset
                    )
                } else if weeklyWin?.resetAt == nil, let w = weeklyWin {
                    weeklyWin = QuotaWindow(id: w.id, label: w.label, usedPercent: w.usedPercent, detailText: w.detailText, resetAt: reset)
                }
            }

            if let lMonth = pools["limit_month_total"] as? [String: Any],
               let rawRatio = optionalDoubleValue(lMonth["used_ratio"] ?? lMonth["usedRatio"]), rawRatio >= 0 {
                let rawUsedPct = rawRatio * 100.0
                let clampedPct = min(100.0, max(0.0, rawUsedPct))
                let reset = parseISO8601((lMonth["reset_time"] as? String) ?? (lMonth["resetTime"] as? String))
                var detail = String(format: "剩余 %.0f%%", max(0, 100 - clampedPct))
                if let lCode = pools["limit_month_code"] as? [String: Any],
                   let codeRatio = optionalDoubleValue(lCode["used_ratio"] ?? lCode["usedRatio"]), codeRatio >= 0 {
                    let safeCodePct = min(rawUsedPct, codeRatio * 100.0)
                    let kimiPct = max(0.0, rawUsedPct - safeCodePct)
                    detail = String(format: "Kimi %.0f%% · Code %.0f%%", kimiPct, safeCodePct)
                }
                monthlyWin = QuotaWindow(
                    id: "kimi.month",
                    label: "月度共享池",
                    usedPercent: clampedPct,
                    detailText: detail,
                    resetAt: reset
                )
            }
        }

        return [sessionWin, weeklyWin, monthlyWin].compactMap { $0 }
    }

    private func parseKimiDetailPercent(_ detail: [String: Any]) -> (usedPercent: Double, detailText: String)? {
        let used = optionalDoubleValue(detail["used"] ?? detail["usedValue"] ?? detail["used_value"] ?? detail["currentValue"])
        let limit = optionalDoubleValue(detail["limit"] ?? detail["limitValue"] ?? detail["limit_value"] ?? detail["total"] ?? detail["quota"])
        if let used, let limit, limit > 0 {
            let pct = min(100.0, max(0.0, (used / limit) * 100.0))
            let text = (Int(limit) == 100)
                ? String(format: "剩余 %.0f%%", max(0, 100 - pct))
                : "\(Int(used)) / \(Int(limit))"
            return (pct, text)
        }
        if let rem = optionalDoubleValue(detail["remaining"] ?? detail["remainingValue"] ?? detail["remaining_value"]),
           let limit, limit > 0 {
            let pct = min(100.0, max(0.0, ((limit - rem) / limit) * 100.0))
            return (pct, "\(Int(max(0, limit - rem))) / \(Int(limit))")
        }
        if let pct = optionalDoubleValue(detail["percent"] ?? detail["percentage"] ?? detail["usedPercent"] ?? detail["used_percent"]) {
            let clamped = min(100.0, max(0.0, pct))
            return (clamped, String(format: "剩余 %.0f%%", max(0, 100 - clamped)))
        }
        return nil
    }

    private func normalizeKimiWebToken(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("authorization:") {
            s = String(s.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.lowercased().hasPrefix("bearer ") {
            s = String(s.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = s.range(of: #"kimi-auth=([^;\s'"]+)"#, options: .regularExpression) {
            let match = String(s[range])
            if let eq = match.firstIndex(of: "=") {
                return String(match[match.index(after: eq)...])
            }
        }
        if s.lowercased().hasPrefix("cookie:") || s.contains(";") {
            return nil
        }
        return s
    }

    private func fetchKimiWebConsoleQuota(webToken: String) async throws -> ProviderQuotaResult {
        async let usageTask = try? postKimiWebRPCData(
            url: URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!,
            body: #"{"scope":["FEATURE_CODING"]}"#,
            webToken: webToken
        )
        async let membershipTask = try? postKimiWebRPCData(
            url: URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!,
            body: "{}",
            webToken: webToken
        )

        let usageRaw = await usageTask
        let membershipRaw = await membershipTask
        let usageJSON = usageRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let membershipJSON = membershipRaw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        guard usageJSON != nil || membershipJSON != nil else {
            throw QuotaError.authFailed("Kimi Web 控制台会话已失效，请更新 kimi-auth")
        }

        var byId: [String: QuotaWindow] = [:]
        if let usageJSON {
            let body = (usageJSON["data"] as? [String: Any]) ?? usageJSON
            if let usages = body["usages"] as? [[String: Any]],
               let coding = usages.first(where: { ($0["scope"] as? String) == "FEATURE_CODING" }) {
                var synthetic: [String: Any] = [:]
                if let d = coding["detail"] { synthetic["usage"] = d }
                if let l = coding["limits"] { synthetic["limits"] = l }
                for w in parseKimiUsageWindows(from: synthetic) {
                    byId[w.id] = w
                }
            }
        }

        if let membershipJSON {
            let body = (membershipJSON["data"] as? [String: Any]) ?? membershipJSON
            if byId["kimi.5h"] == nil,
               let r5h = (body["ratelimitCode5h"] as? [String: Any]) ?? (body["ratelimit_code_5h"] as? [String: Any]),
               (r5h["enabled"] as? Bool) != false,
               let ratio = optionalDoubleValue(r5h["ratio"] ?? r5h["usedRatio"] ?? r5h["used_ratio"]), ratio >= 0 {
                let pct = min(100.0, max(0.0, ratio * 100.0))
                byId["kimi.5h"] = QuotaWindow(
                    id: "kimi.5h",
                    label: "5h 窗口",
                    usedPercent: pct,
                    detailText: String(format: "剩余 %.0f%%", max(0, 100 - pct)),
                    resetAt: parseISO8601((r5h["resetTime"] as? String) ?? (r5h["reset_time"] as? String))
                )
            }
            if byId["kimi.7d"] == nil,
               let r7d = (body["ratelimitCode7d"] as? [String: Any]) ?? (body["ratelimit_code_7d"] as? [String: Any]),
               (r7d["enabled"] as? Bool) != false,
               let ratio = optionalDoubleValue(r7d["ratio"] ?? r7d["usedRatio"] ?? r7d["used_ratio"]), ratio >= 0 {
                let pct = min(100.0, max(0.0, ratio * 100.0))
                byId["kimi.7d"] = QuotaWindow(
                    id: "kimi.7d",
                    label: "7d 周限额",
                    usedPercent: pct,
                    detailText: String(format: "剩余 %.0f%%", max(0, 100 - pct)),
                    resetAt: parseISO8601((r7d["resetTime"] as? String) ?? (r7d["reset_time"] as? String))
                )
            }
            if byId["kimi.month"] == nil,
               let bal = (body["subscriptionBalance"] as? [String: Any]) ?? (body["subscription_balance"] as? [String: Any]),
               let rawRatio = optionalDoubleValue(bal["amountUsedRatio"] ?? bal["amount_used_ratio"]), rawRatio >= 0 {
                let rawUsedPct = rawRatio * 100.0
                let clampedPct = min(100.0, max(0.0, rawUsedPct))
                var detail = String(format: "剩余 %.0f%%", max(0, 100 - clampedPct))
                if let codeRatio = optionalDoubleValue(bal["kimiCodeUsedRatio"] ?? bal["kimi_code_used_ratio"]), codeRatio >= 0 {
                    let safeCode = min(rawUsedPct, codeRatio * 100.0)
                    detail = String(format: "Kimi %.0f%% · Code %.0f%%", max(0, rawUsedPct - safeCode), safeCode)
                }
                byId["kimi.month"] = QuotaWindow(
                    id: "kimi.month",
                    label: "月度共享池",
                    usedPercent: clampedPct,
                    detailText: detail,
                    resetAt: parseISO8601((bal["expireTime"] as? String) ?? (bal["expire_time"] as? String))
                )
            }
        }

        let ordered = ["kimi.5h", "kimi.7d", "kimi.month"].compactMap { byId[$0] }
        let claims = decodeJWTClaims(webToken)
        return ProviderQuotaResult(
            resolvedExternalId: claims["sub"] as? String,
            planBadge: "Kimi Web",
            windows: ordered,
            statusMessage: ordered.isEmpty ? "已连接 Kimi Web（暂无活跃配额限制）" : nil
        )
    }

    private func postKimiWebRPCData(url: URL, body: String, webToken: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(webToken)", forHTTPHeaderField: "Authorization")
        req.setValue("kimi-auth=\(webToken)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        req.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        req.setValue("zh-CN", forHTTPHeaderField: "x-language")
        req.setValue("web", forHTTPHeaderField: "x-msh-platform")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        req.setValue(MimoSessionMinter.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let claims = decodeJWTClaims(webToken)
        if let devId = claims["device_id"] as? String, !devId.isEmpty {
            req.setValue(devId, forHTTPHeaderField: "x-msh-device-id")
        }
        if let ssid = claims["ssid"] as? String, !ssid.isEmpty {
            req.setValue(ssid, forHTTPHeaderField: "x-msh-session-id")
        }
        if let sub = claims["sub"] as? String, !sub.isEmpty {
            req.setValue(sub, forHTTPHeaderField: "x-traffic-id")
        }
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw QuotaError.authFailed("Kimi Web HTTP \(status)")
        }
        return data
    }

    private func decodeJWTClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem > 0 { base64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func normalizedKimiBaseURL(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "https://api.kimi.com/coding/v1"
        }
        let lower = raw.lowercased()
        if lower == "global" || lower.contains("kimi.ai") {
            return "https://api.kimi.ai/coding/v1"
        }
        if lower == "cn" || lower.contains("kimi.com") {
            return "https://api.kimi.com/coding/v1"
        }
        if raw.hasPrefix("http") {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://api.kimi.com/coding/v1"
    }

    private func resolveKimiToken(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async throws -> String {
        let now = Date()
        if let cached = cachedAccessTokens[account.id], cached.expiry > now.addingTimeInterval(60) {
            return cached.token
        }

        if let credPath = account.credentialFilePath {
            let url = URL(fileURLWithPath: credPath)
            if var json = AccountDiscoveryService.readJSONDictionary(at: url),
               let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                let expiresAt = doubleValue(json["expires_at"])
                if expiresAt == 0 || expiresAt - now.timeIntervalSince1970 > 300 {
                    let exp = expiresAt > 0 ? Date(timeIntervalSince1970: expiresAt) : now.addingTimeInterval(1800)
                    cachedAccessTokens[account.id] = (accessToken, exp)
                    return accessToken
                }
                if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
                    let deviceIdPath = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("device_id")
                    let deviceId = (try? String(contentsOf: deviceIdPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let refreshed = try await refreshKimiOAuth(refreshToken: refreshToken, deviceId: deviceId)
                    json["access_token"] = refreshed.accessToken
                    json["refresh_token"] = refreshed.refreshToken
                    json["expires_at"] = refreshed.expiresAt
                    json["expires_in"] = refreshed.expiresIn
                    writeJSONAtomically(json, to: url, permissions: 0o600)
                    cachedAccessTokens[account.id] = (refreshed.accessToken, Date(timeIntervalSince1970: refreshed.expiresAt))
                    return refreshed.accessToken
                }
                return accessToken
            }
        }

        if let secret = KeychainStore.loadSecret(for: account.id) ?? ephemeralSecrets[account.id] {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let access = json["access_token"] as? String, !access.isEmpty {
                    let expiresAt = doubleValue(json["expires_at"])
                    if expiresAt == 0 || expiresAt - now.timeIntervalSince1970 > 300 {
                        return access
                    }
                    if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
                        let refreshed = try await refreshKimiOAuth(refreshToken: refresh, deviceId: nil)
                        var updated = json
                        updated["access_token"] = refreshed.accessToken
                        updated["refresh_token"] = refreshed.refreshToken
                        updated["expires_at"] = refreshed.expiresAt
                        if let outData = try? JSONSerialization.data(withJSONObject: updated),
                           let outStr = String(data: outData, encoding: .utf8) {
                            try? KeychainStore.saveSecret(outStr, for: account.id)
                        }
                        cachedAccessTokens[account.id] = (refreshed.accessToken, Date(timeIntervalSince1970: refreshed.expiresAt))
                        return refreshed.accessToken
                    }
                    return access
                }
            }
            return trimmed
        }

        throw QuotaError.missingCredential("未找到 Kimi Code 凭证")
    }

    private func refreshKimiOAuth(
        refreshToken: String,
        deviceId: String?
    ) async throws -> (accessToken: String, refreshToken: String, expiresAt: Double, expiresIn: Int) {
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("darwin", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue("2.0.0", forHTTPHeaderField: "X-Msh-Version")
        request.setValue("arm64", forHTTPHeaderField: "X-Msh-Device-Model")
        if let deviceId, !deviceId.isEmpty {
            request.setValue(deviceId, forHTTPHeaderField: "X-Msh-Device-Id")
        }

        let encodedRefresh = formEncode(refreshToken)
        let body = "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=\(encodedRefresh)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw QuotaError.authFailed("Kimi OAuth 刷新失败 (HTTP \(status))")
        }
        let newRefresh = (json["refresh_token"] as? String) ?? refreshToken
        let expiresIn = intValue(json["expires_in"], default: 3600)
        let expiresAt = Date().timeIntervalSince1970 + Double(expiresIn)
        return (accessToken, newRefresh, expiresAt, expiresIn)
    }

    private func fetchKimiData(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw QuotaError.authFailed("Kimi 接口返回 HTTP \(status)")
        }
        return data
    }

    // MARK: - 4. MiniMax Coding Plan / Token Plan

    private func fetchMiniMaxQuota(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async -> ProviderQuotaResult {
        if account.authKind == .localOnly {
            return ProviderQuotaResult(statusMessage: "仅本地会话日志模式")
        }

        guard let rawKey = (KeychainStore.loadSecret(for: account.id) ?? ephemeralSecrets[account.id])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKey.isEmpty else {
            return ProviderQuotaResult(errorMessage: "未配置 MiniMax API Key")
        }

        let lowerRegion = (account.regionOrBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let orderedHosts: [String] = {
            if lowerRegion == "cn" || lowerRegion.contains("minimaxi.com") {
                return ["https://api.minimaxi.com"]
            }
            if lowerRegion == "global" || lowerRegion == "intl" || lowerRegion == "en" || lowerRegion.contains("minimax.io") {
                return ["https://api.minimax.io"]
            }
            let defaultHosts = ["https://api.minimaxi.com", "https://api.minimax.io"]
            if let remembered = cachedMiniMaxRegionHost[account.id], defaultHosts.contains(remembered) {
                return [remembered] + defaultHosts.filter { $0 != remembered }
            }
            return defaultHosts
        }()

        // 优先查询新版 `/v1/token_plan/remains`，遇 404/405/旧版回退 `/v1/api/openplatform/coding_plan/remains`
        let endpoints = [
            "/v1/token_plan/remains",
            "/v1/api/openplatform/coding_plan/remains",
        ]

        var lastError = "请求失败"
        for host in orderedHosts {
            var hostUnreachable = false
            for path in endpoints {
                guard let url = URL(string: "\(host)\(path)") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Bearer \(rawKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                do {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        lastError = "HTTP \(status)"
                        if status == 429 { break }
                        continue
                    }

                    let dataEnvelope = json["data"] as? [String: Any]
                    let baseResp = (json["base_resp"] as? [String: Any]) ?? (dataEnvelope?["base_resp"] as? [String: Any])
                    let statusCode = intValue(baseResp?["status_code"], default: 0)
                    if statusCode != 0 {
                        lastError = (baseResp?["status_msg"] as? String) ?? "status_code=\(statusCode)"
                        // 1004 / 2049 等跨区 Key 拒绝码直接尝试下一路径或下一区域域名
                        continue
                    }

                    cachedMiniMaxRegionHost[account.id] = host
                    let regionTag = host.contains("minimaxi.com") ? "CN" : "Global"
                    let walletBalance = await fetchMiniMaxBalanceText(host: host, apiKey: rawKey)

                    let remainsList = (dataEnvelope?["model_remains"] as? [[String: Any]])
                        ?? (json["model_remains"] as? [[String: Any]])
                        ?? []

                    let rawPlanTitle = ((dataEnvelope?["current_subscribe_title"] as? String)
                        ?? (json["current_subscribe_title"] as? String)
                        ?? (dataEnvelope?["combo_title"] as? String)
                        ?? (json["combo_title"] as? String)
                        ?? (dataEnvelope?["plan_title"] as? String)
                        ?? (json["plan_title"] as? String))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !remainsList.isEmpty else {
                        return ProviderQuotaResult(
                            planBadge: (rawPlanTitle?.isEmpty == false) ? "\(rawPlanTitle!) · \(regionTag)" : "MiniMax · \(regionTag)",
                            windows: [],
                            walletBalanceText: walletBalance,
                            statusMessage: walletBalance != nil ? "当前无活跃 Token Plan · 已同步账户余额" : "暂无活跃 Token Plan 套餐记录"
                        )
                    }

                    let mediaBuckets: Set<String> = ["video", "image", "image-01", "speech", "music", "voice", "t2a", "hailuo"]
                    let selected = remainsList.first { ($0["model_name"] as? String)?.lowercased() == "general" }
                        ?? remainsList.first { (($0["model_name"] as? String)?.lowercased() ?? "").hasPrefix("minimax-m") }
                        ?? remainsList.first { !mediaBuckets.contains(($0["model_name"] as? String)?.lowercased() ?? "") }
                        ?? remainsList[0]

                    var windows: [QuotaWindow] = []

                    // 5h 窗口（注意：status == 3 是服务端无此项权益的占位符，应跳过，而非显示“不限额”！）
                    if !isMiniMaxPlaceholderLane(
                        selected,
                        percentField: "current_interval_remaining_percent",
                        totalField: "current_interval_total_count",
                        statusField: "current_interval_status"
                    ) {
                        let intervalReset = parseMiniMaxResetDate(
                            endRaw: selected["end_time"],
                            remainsRaw: selected["remains_time"]
                        )
                        let totalCount = intValue(selected["current_interval_total_count"])
                        let remainingCount = intValue(selected["current_interval_usage_count"])
                        if totalCount > 0 {
                            let usedCount = max(0, totalCount - remainingCount)
                            let pct = min(100.0, max(0.0, Double(usedCount) / Double(totalCount) * 100.0))
                            windows.append(QuotaWindow(
                                id: "minimax.5h",
                                label: "5h 窗口",
                                usedPercent: pct,
                                detailText: "\(usedCount) / \(totalCount)",
                                resetAt: intervalReset
                            ))
                        } else if let remPct = optionalDoubleValue(selected["current_interval_remaining_percent"]) {
                            let clampedRem = min(100.0, max(0.0, remPct))
                            windows.append(QuotaWindow(
                                id: "minimax.5h",
                                label: "5h 窗口",
                                usedPercent: max(0.0, 100.0 - clampedRem),
                                detailText: String(format: "剩余 %.0f%%", clampedRem),
                                resetAt: intervalReset
                            ))
                        }
                    }

                    // 7d 周窗口（同样过滤 status == 3 占位符）
                    if !isMiniMaxPlaceholderLane(
                        selected,
                        percentField: "current_weekly_remaining_percent",
                        totalField: "current_weekly_total_count",
                        statusField: "current_weekly_status"
                    ) {
                        let weeklyReset = parseMiniMaxResetDate(
                            endRaw: selected["weekly_end_time"],
                            remainsRaw: selected["weekly_remains_time"]
                        )
                        let wTotal = intValue(selected["current_weekly_total_count"])
                        let wRemaining = intValue(selected["current_weekly_usage_count"])
                        if wTotal > 0 {
                            let wUsed = max(0, wTotal - wRemaining)
                            let pct = min(100.0, max(0.0, Double(wUsed) / Double(wTotal) * 100.0))
                            windows.append(QuotaWindow(
                                id: "minimax.7d",
                                label: "7d 周限额",
                                usedPercent: pct,
                                detailText: "\(wUsed) / \(wTotal)",
                                resetAt: weeklyReset
                            ))
                        } else if let remPct = optionalDoubleValue(selected["current_weekly_remaining_percent"]) {
                            let clampedRem = min(100.0, max(0.0, remPct))
                            windows.append(QuotaWindow(
                                id: "minimax.7d",
                                label: "7d 周限额",
                                usedPercent: max(0.0, 100.0 - clampedRem),
                                detailText: String(format: "剩余 %.0f%%", clampedRem),
                                resetAt: weeklyReset
                            ))
                        }
                    }

                    let badgeBase = (rawPlanTitle?.isEmpty == false)
                        ? rawPlanTitle!
                        : (path.contains("token_plan") ? "Token Plan" : "Coding Plan")

                    return ProviderQuotaResult(
                        planBadge: "\(badgeBase) · \(regionTag)",
                        windows: windows,
                        walletBalanceText: walletBalance,
                        statusMessage: windows.isEmpty ? "当前套餐无活跃限流窗口" : nil
                    )
                } catch {
                    lastError = error.localizedDescription
                    hostUnreachable = true
                }
                if hostUnreachable { break }
            }
        }

        // 若套餐端点均未匹配，兜底尝试按量 API 余额接口
        for host in orderedHosts {
            if let walletBalance = await fetchMiniMaxBalanceText(host: host, apiKey: rawKey) {
                cachedMiniMaxRegionHost[account.id] = host
                let regionTag = host.contains("minimaxi.com") ? "CN" : "Global"
                return ProviderQuotaResult(
                    planBadge: "API 按量 · \(regionTag)",
                    windows: [],
                    walletBalanceText: walletBalance,
                    statusMessage: "已同步 MiniMax 按量账户可用余额"
                )
            }
        }

        return ProviderQuotaResult(errorMessage: "MiniMax 额度查询失败: \(lastError)")
    }

    private func isMiniMaxPlaceholderLane(
        _ item: [String: Any],
        percentField: String,
        totalField: String,
        statusField: String
    ) -> Bool {
        guard intValue(item[statusField], default: 0) == 3 else { return false }
        let total = intValue(item[totalField], default: 0)
        if total > 0 { return false }
        guard let pct = optionalDoubleValue(item[percentField]) else { return true }
        return pct >= 100.0
    }

    /// 兼容秒级 (`< 1e12`) 与毫秒级时间戳
    private func parseMiniMaxResetDate(endRaw: Any?, remainsRaw: Any?) -> Date? {
        if let endVal = optionalDoubleValue(endRaw), endVal > 0 {
            let secs = endVal < 1_000_000_000_000 ? endVal : (endVal / 1000.0)
            return Date(timeIntervalSince1970: secs)
        }
        if let remVal = optionalDoubleValue(remainsRaw), remVal > 0 {
            let secs = remVal < 1_000_000_000 ? remVal : (remVal / 1000.0)
            return Date().addingTimeInterval(secs)
        }
        return nil
    }

    private func fetchMiniMaxBalanceText(host: String, apiKey: String) async -> String? {
        guard let url = URL(string: "\(host)/account/query_balance") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let container = (json["data"] as? [String: Any]) ?? json
        guard let amount = optionalDoubleValue(container["available_amount"]) else { return nil }
        let sym = host.contains("minimaxi.com") ? "¥" : "$"
        return String(format: "余额 %@%.2f", sym, amount)
    }

    // MARK: - 5. Google Antigravity

    private static let antigravityModelBlacklist: Set<String> = [
        "MODEL_CHAT_20706",
        "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE",
        "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19",
        "MODEL_PLACEHOLDER_M9",
        "MODEL_PLACEHOLDER_M12",
    ]

    private struct LiveAntigravityStatus: Sendable {
        let email: String?
        let displayName: String?
        let tierName: String?
        let windows: [QuotaWindow]
        let hasGroupedSummary: Bool
    }

    private func fetchAntigravityQuota(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String],
        liveStatuses: [LiveAntigravityStatus]
    ) async -> ProviderQuotaResult {
        // 1. 优先匹配正在运行的本机 Antigravity Language Server 状态（若已拿到 5h+7d 分组摘要则直接采用）
        let acctEmail = account.externalAccountId?.lowercased()
        let matchedLive = acctEmail.flatMap { email in
            liveStatuses.first(where: { $0.email?.lowercased() == email })
        }

        if let matchedLive, matchedLive.hasGroupedSummary, !matchedLive.windows.isEmpty {
            return ProviderQuotaResult(
                resolvedLabel: matchedLive.email ?? matchedLive.displayName,
                resolvedExternalId: matchedLive.email,
                planBadge: matchedLive.tierName ?? "Antigravity",
                windows: matchedLive.windows
            )
        }

        if account.authKind == .localOnly {
            if let first = matchedLive ?? liveStatuses.first {
                return ProviderQuotaResult(
                    resolvedLabel: first.email ?? first.displayName,
                    resolvedExternalId: first.email,
                    planBadge: first.tierName ?? "Antigravity",
                    windows: first.windows
                )
            }
            return ProviderQuotaResult(statusMessage: "Antigravity 未在后台运行 · 已启用本地日志统计")
        }

        // 2. 通过 Google OAuth + Cloud Code Private API 查询（优先 daily 端点的 retrieveUserQuotaSummary，支持离线多账号！）
        do {
            let auth = try await resolveAntigravityAccessToken(account: account, ephemeralSecrets: ephemeralSecrets)
            let endpoints = [
                "https://daily-cloudcode-pa.googleapis.com",
                "https://cloudcode-pa.googleapis.com",
            ]

            for base in endpoints {
                if let result = try? await queryCloudCodeQuota(
                    baseURL: base,
                    accessToken: auth.accessToken,
                    email: auth.email ?? account.externalAccountId,
                    projectHint: account.regionOrBaseURL
                ), !result.windows.isEmpty {
                    // 若本机 RPC 有某分组窗口而云端缺失，可做互补合并
                    if let matchedLive, matchedLive.hasGroupedSummary {
                        let merged = mergeAntigravityGroupedWindows(primary: matchedLive.windows, fallback: result.windows)
                        return ProviderQuotaResult(
                            resolvedLabel: result.resolvedLabel ?? matchedLive.email,
                            resolvedExternalId: result.resolvedExternalId ?? matchedLive.email,
                            planBadge: result.planBadge ?? matchedLive.tierName,
                            windows: merged
                        )
                    }
                    return result
                }
            }

            if let fallbackLive = matchedLive ?? (account.externalAccountId == nil ? liveStatuses.first : nil) {
                return ProviderQuotaResult(
                    resolvedLabel: fallbackLive.email ?? fallbackLive.displayName,
                    resolvedExternalId: fallbackLive.email,
                    planBadge: fallbackLive.tierName ?? "Antigravity",
                    windows: fallbackLive.windows
                )
            }
            return ProviderQuotaResult(errorMessage: "无法从 Cloud Code 获取 Antigravity 模型配额")
        } catch {
            if let fallbackLive = matchedLive ?? (account.externalAccountId == nil ? liveStatuses.first : nil) {
                return ProviderQuotaResult(
                    resolvedLabel: fallbackLive.email ?? fallbackLive.displayName,
                    resolvedExternalId: fallbackLive.email,
                    planBadge: fallbackLive.tierName ?? "Antigravity",
                    windows: fallbackLive.windows
                )
            }
            return ProviderQuotaResult(errorMessage: error.localizedDescription)
        }
    }

    private func mergeAntigravityGroupedWindows(primary: [QuotaWindow], fallback: [QuotaWindow]) -> [QuotaWindow] {
        var seenIds = Set(primary.map(\.id))
        var out = primary
        for w in fallback where seenIds.insert(w.id).inserted {
            out.append(w)
        }
        return out
    }

    private func queryCloudCodeQuota(
        baseURL: String,
        accessToken: String,
        email: String?,
        projectHint: String?
    ) async throws -> ProviderQuotaResult {
        let hubUA = "antigravity/hub/2.23.1 darwin/arm64"

        // Step 1: loadCodeAssist 获取订阅等级与 cloudaicompanionProject
        var loadReq = URLRequest(url: URL(string: "\(baseURL)/v1internal:loadCodeAssist")!)
        loadReq.httpMethod = "POST"
        loadReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        loadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loadReq.setValue(hubUA, forHTTPHeaderField: "User-Agent")
        loadReq.httpBody = #"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.data(using: .utf8)

        var projectId: String? = projectHint
        var tierBadge: String? = nil

        if let (loadData, loadResp) = try? await session.data(for: loadReq),
           let code = (loadResp as? HTTPURLResponse)?.statusCode,
           (200..<300).contains(code),
           let loadJSON = try? JSONSerialization.jsonObject(with: loadData) as? [String: Any] {
            let container = (loadJSON["response"] as? [String: Any]) ?? loadJSON
            for key in ["cloudaicompanionProject", "projectId", "project"] {
                if let pStr = container[key] as? String, !pStr.isEmpty {
                    projectId = pStr
                    break
                } else if let pDict = container[key] as? [String: Any],
                          let pStr = (pDict["id"] as? String) ?? (pDict["value"] as? String) ?? (pDict["projectId"] as? String),
                          !pStr.isEmpty {
                    projectId = pStr
                    break
                }
            }
            let paidTier = container["paidTier"] as? [String: Any]
            let currentTier = container["currentTier"] as? [String: Any]
            if let pType = (container["planInfo"] as? [String: Any])?["planType"] as? String, !pType.isEmpty {
                tierBadge = pType
            } else if ((paidTier?["id"] as? String) ?? "").lowercased() == "g1-pro-tier" {
                tierBadge = "Pro"
            } else if let paidName = paidTier?["name"] as? String, !paidName.isEmpty {
                tierBadge = paidName
            } else if let curName = currentTier?["name"] as? String, !curName.isEmpty {
                tierBadge = curName
            }
        }

        let bodyDict: [String: Any] = (projectId?.isEmpty == false) ? ["project": projectId!] : [:]
        let projectBodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        // Step 2: 优先调用新版 `/v1internal:retrieveUserQuotaSummary`（原生 5h + 7d 分组双窗口！）
        if let summaryURL = URL(string: "\(baseURL)/v1internal:retrieveUserQuotaSummary") {
            var sumReq = URLRequest(url: summaryURL)
            sumReq.httpMethod = "POST"
            sumReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            sumReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sumReq.setValue(hubUA, forHTTPHeaderField: "User-Agent")
            sumReq.httpBody = projectBodyData

            if let (sumData, sumResp) = try? await session.data(for: sumReq),
               let sumStatus = (sumResp as? HTTPURLResponse)?.statusCode,
               (200..<300).contains(sumStatus),
               let sumJSON = try? JSONSerialization.jsonObject(with: sumData) as? [String: Any] {
                let summaryWindows = parseAntigravityQuotaSummary(sumJSON)
                if !summaryWindows.isEmpty {
                    return ProviderQuotaResult(
                        resolvedLabel: email,
                        resolvedExternalId: email,
                        planBadge: tierBadge ?? "Antigravity",
                        windows: summaryWindows
                    )
                }
            }
        }

        // Step 3: 回退旧版 `fetchAvailableModels`（若全部返回 100% 剩余，再以 `retrieveUserQuota` 交叉校验）
        var modelsReq = URLRequest(url: URL(string: "\(baseURL)/v1internal:fetchAvailableModels")!)
        modelsReq.httpMethod = "POST"
        modelsReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        modelsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        modelsReq.setValue(hubUA, forHTTPHeaderField: "User-Agent")
        modelsReq.httpBody = projectBodyData

        let (data, response) = try await session.data(for: modelsReq)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any] else {
            throw QuotaError.authFailed("HTTP \(status)")
        }

        var rawItems: [(label: String, modelId: String, usedPercent: Double, resetAt: Date?)] = []
        for (modelId, val) in models {
            guard !modelId.hasPrefix("chat_"), !modelId.hasPrefix("tab_"),
                  let mDict = val as? [String: Any] else { continue }
            let apiProvider = (mDict["apiProvider"] as? String) ?? ""
            if apiProvider == "API_PROVIDER_INTERNAL" { continue }
            let placeholder = (mDict["model"] as? String) ?? ""
            if Self.antigravityModelBlacklist.contains(placeholder) || Self.antigravityModelBlacklist.contains(modelId) {
                continue
            }
            guard let displayName = mDict["displayName"] as? String, !displayName.isEmpty else { continue }

            if !placeholder.isEmpty {
                cacheModelPlaceholder(placeholder, displayName: displayName)
            }

            guard let quotaInfo = mDict["quotaInfo"] as? [String: Any] else { continue }
            let resetStr = quotaInfo["resetTime"] as? String
            let resetAt = parseISO8601(resetStr)
            let remainingFraction: Double
            if let explicit = optionalDoubleValue(quotaInfo["remainingFraction"]) {
                remainingFraction = min(1.0, max(0.0, explicit))
            } else if resetStr != nil {
                remainingFraction = 0.0
            } else {
                remainingFraction = 1.0
            }
            let usedPct = max(0, min(100, (1.0 - remainingFraction) * 100.0))
            rawItems.append((displayName, modelId, usedPct, resetAt))
        }

        // 若 fetchAvailableModels 所有模型均显示 used == 0%，尝试 retrieveUserQuota 二次核验真实扣减
        if !rawItems.isEmpty, rawItems.allSatisfy({ $0.usedPercent <= 0.1 }),
           let verifyURL = URL(string: "\(baseURL)/v1internal:retrieveUserQuota") {
            var vReq = URLRequest(url: verifyURL)
            vReq.httpMethod = "POST"
            vReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            vReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            vReq.setValue(hubUA, forHTTPHeaderField: "User-Agent")
            vReq.httpBody = projectBodyData
            if let (vData, vResp) = try? await session.data(for: vReq),
               let vCode = (vResp as? HTTPURLResponse)?.statusCode,
               (200..<300).contains(vCode),
               let vJSON = try? JSONSerialization.jsonObject(with: vData) as? [String: Any],
               let buckets = vJSON["buckets"] as? [[String: Any]], !buckets.isEmpty {
                var verifiedByModel: [String: (usedPct: Double, resetAt: Date?)] = [:]
                for b in buckets {
                    guard let mId = (b["modelId"] as? String)?.lowercased(), !mId.isEmpty else { continue }
                    let rStr = b["resetTime"] as? String
                    let rem = optionalDoubleValue(b["remainingFraction"]) ?? (rStr != nil ? 0.0 : 1.0)
                    let usedPct = max(0, min(100, (1.0 - rem) * 100.0))
                    if let cur = verifiedByModel[mId], cur.usedPct >= usedPct { continue }
                    verifiedByModel[mId] = (usedPct, parseISO8601(rStr))
                }
                if !verifiedByModel.isEmpty {
                    rawItems = rawItems.map { item in
                        if let v = verifiedByModel[item.modelId.lowercased()] {
                            return (item.label, item.modelId, v.usedPct, v.resetAt ?? item.resetAt)
                        }
                        return item
                    }
                }
            }
        }

        let windows = groupAntigravityModelPools(rawItems)
        return ProviderQuotaResult(
            resolvedLabel: email,
            resolvedExternalId: email,
            planBadge: tierBadge ?? "Antigravity",
            windows: windows,
            statusMessage: windows.isEmpty ? "已连接 Antigravity（当前无受限模型池）" : nil
        )
    }

    /// 解析 `RetrieveUserQuotaSummary` / `retrieveUserQuotaSummary` 的分组 5h + 7d 窗口
    private func parseAntigravityQuotaSummary(_ payload: [String: Any]) -> [QuotaWindow] {
        let summary = (payload["response"] as? [String: Any])
            ?? (payload["summary"] as? [String: Any])
            ?? payload
        guard let groups = summary["groups"] as? [[String: Any]], !groups.isEmpty else {
            return []
        }

        var windows: [QuotaWindow] = []
        for group in groups {
            let rawName = ((group["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerName = rawName.lowercased()
            let groupTitle: String = {
                if lowerName == "gemini" || lowerName == "gemini models" {
                    return "Gemini"
                }
                if lowerName.contains("argon") {
                    return "Gemini 4 Argon"
                }
                if lowerName.contains("claude") || lowerName.contains("gpt") {
                    return "Claude/GPT"
                }
                return rawName.isEmpty ? "Quota" : rawName
            }()
            let slug = groupTitle.lowercased()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")

            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let kind = classifyAntigravityBucketKind(bucket) else { continue }
                guard let rem = extractAntigravityBucketRemaining(bucket) else { continue }
                let clampedRem = min(1.0, max(0.0, rem))
                let usedPct = min(100.0, max(0.0, (1.0 - clampedRem) * 100.0))
                let resetAt = parseAntigravityResetDate(bucket["resetTime"])
                let windowLabel = "\(groupTitle) \(kind == "session" ? "5h" : "7d")"
                windows.append(QuotaWindow(
                    id: "agy.\(slug).\(kind)",
                    label: windowLabel,
                    usedPercent: usedPct,
                    detailText: String(format: "剩余 %.0f%%", max(0, 100 - usedPct)),
                    resetAt: resetAt
                ))
            }
        }
        return windows
    }

    private func classifyAntigravityBucketKind(_ bucket: [String: Any]) -> String? {
        let sessionAliases: Set<String> = ["session", "5h", "5-hour", "five hour", "five-hour"]
        for rawVal in [bucket["window"], bucket["bucketId"], bucket["displayName"]] {
            guard var norm = (rawVal as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !norm.isEmpty else { continue }
            norm = norm.replacingOccurrences(of: "_", with: "-")
            if norm.hasSuffix(" limit") {
                norm = String(norm.dropLast(" limit".count))
            }
            if norm == "weekly" || norm.hasSuffix("-weekly") {
                return "weekly"
            }
            if sessionAliases.contains(norm) || sessionAliases.contains(where: { norm.hasSuffix("-\($0)") }) {
                return "session"
            }
        }
        return nil
    }

    private func extractAntigravityBucketRemaining(_ bucket: [String: Any]) -> Double? {
        if let direct = optionalDoubleValue(bucket["remainingFraction"]) {
            return direct
        }
        if let remObj = bucket["remaining"] as? [String: Any] {
            if let nested = optionalDoubleValue(remObj["remainingFraction"]) {
                return nested
            }
            if (remObj["case"] as? String) == "remainingFraction",
               let val = optionalDoubleValue(remObj["value"]) {
                return val
            }
        }
        if bucket["resetTime"] != nil {
            return 0.0
        }
        return nil
    }

    private func parseAntigravityResetDate(_ any: Any?) -> Date? {
        if let str = any as? String, !str.isEmpty {
            return parseISO8601(str)
        }
        if let num = optionalDoubleValue(any), num > 0 {
            return Date(timeIntervalSince1970: num > 20_000_000_000 ? num / 1000.0 : num)
        }
        return nil
    }

    private func probeRunningAntigravityServers() async -> [LiveAntigravityStatus] {
        let candidates = discoverAntigravityProcessTargets()
        guard !candidates.isEmpty else { return [] }

        var statuses: [LiveAntigravityStatus] = []
        for target in candidates {
            var foundForTarget = false
            for port in target.ports {
                for scheme in ["http", "https"] {
                    // 1. 优先尝试新版 `RetrieveUserQuotaSummary`（获取原生 5h + 7d 双窗口）
                    var groupedWindows: [QuotaWindow] = []
                    if let summaryJSON = await callLocalAntigravityRPC(
                        scheme: scheme,
                        port: port,
                        csrfToken: target.csrfToken,
                        method: "RetrieveUserQuotaSummary",
                        body: #"{"forceRefresh":true}"#
                    ) {
                        groupedWindows = parseAntigravityQuotaSummary(summaryJSON)
                    }

                    // 2. 调用 `GetUserStatus` 获取账号身份与旧版模型池回退数据
                    let statusJSON = await callLocalAntigravityRPC(
                        scheme: scheme,
                        port: port,
                        csrfToken: target.csrfToken,
                        method: "GetUserStatus",
                        body: #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#
                    )

                    if groupedWindows.isEmpty && statusJSON == nil {
                        continue
                    }

                    let userStatus = statusJSON?["userStatus"] as? [String: Any]
                    let email = (userStatus?["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = (userStatus?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let planInfo = ((userStatus?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])
                    let tier = ((userStatus?["userTier"] as? [String: Any])?["name"] as? String)
                        ?? (planInfo?["planDisplayName"] as? String)
                        ?? (planInfo?["displayName"] as? String)
                        ?? (planInfo?["productName"] as? String)
                        ?? (planInfo?["planName"] as? String)

                    var legacyItems: [(label: String, modelId: String, usedPercent: Double, resetAt: Date?)] = []
                    if let cascade = userStatus?["cascadeModelConfigData"] as? [String: Any],
                       let configs = cascade["clientModelConfigs"] as? [[String: Any]] {
                        for cfg in configs {
                            guard let label = cfg["label"] as? String, !label.isEmpty else { continue }
                            let modelId = (cfg["modelId"] as? String) ?? label
                            let alias = (cfg["modelOrAlias"] as? [String: Any])?["model"] as? String ?? ""
                            if !alias.isEmpty {
                                cacheModelPlaceholder(alias, displayName: label)
                            }
                            if Self.antigravityModelBlacklist.contains(alias) || Self.antigravityModelBlacklist.contains(modelId) {
                                continue
                            }
                            guard let quotaInfo = cfg["quotaInfo"] as? [String: Any] else { continue }
                            let resetStr = quotaInfo["resetTime"] as? String
                            let resetAt = parseISO8601(resetStr)
                            let rem: Double
                            if let explicit = optionalDoubleValue(quotaInfo["remainingFraction"]) {
                                rem = min(1.0, max(0.0, explicit))
                            } else if resetStr != nil {
                                rem = 0.0
                            } else {
                                rem = 1.0
                            }
                            legacyItems.append((label, modelId, max(0, min(100, (1.0 - rem) * 100.0)), resetAt))
                        }
                    }

                    let finalWindows = !groupedWindows.isEmpty
                        ? groupedWindows
                        : groupAntigravityModelPools(legacyItems)
                    guard !finalWindows.isEmpty else { continue }

                    statuses.append(LiveAntigravityStatus(
                        email: email,
                        displayName: name,
                        tierName: tier,
                        windows: finalWindows,
                        hasGroupedSummary: !groupedWindows.isEmpty
                    ))
                    foundForTarget = true
                    break
                }
                if foundForTarget { break }
            }
        }
        return statuses
    }

    private func callLocalAntigravityRPC(
        scheme: String,
        port: Int,
        csrfToken: String,
        method: String,
        body: String
    ) async -> [String: Any]? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !csrfToken.isEmpty {
            req.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        req.httpBody = body.data(using: .utf8)

        guard let (data, resp) = try? await insecureLocalSession.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func groupAntigravityModelPools(
        _ items: [(label: String, modelId: String, usedPercent: Double, resetAt: Date?)]
    ) -> [QuotaWindow] {
        guard !items.isEmpty else { return [] }

        struct PoolAccumulator {
            let id: String
            let title: String
            let order: Int
            var usedPercent: Double
            var resetAt: Date?
        }

        var pools: [String: PoolAccumulator] = [:]
        for item in items {
            let lower = (item.modelId + " " + item.label).lowercased()
            let poolKey: String
            let poolTitle: String
            let order: Int

            // 必须先判断 Argon 独立池，避免被通用 "gemini" 吞并！
            if lower.contains("argon") {
                poolKey = "agy.gemini_argon"
                poolTitle = "Gemini 4 Argon 池"
                order = 1
            } else if lower.contains("gemini") && lower.contains("flash") {
                poolKey = "agy.gemini_flash"
                poolTitle = "Gemini Flash 池"
                order = 3
            } else if lower.contains("gemini") {
                poolKey = "agy.gemini_pro"
                poolTitle = "Gemini Pro 池"
                order = 2
            } else if lower.contains("claude") || lower.contains("gpt") || lower.contains("opus") || lower.contains("sonnet") {
                poolKey = "agy.claude_gpt"
                poolTitle = "Claude / GPT 共享池"
                order = 4
            } else {
                poolKey = "agy.other.\(item.modelId)"
                poolTitle = item.label
                order = 5
            }

            if var existing = pools[poolKey] {
                if item.usedPercent > existing.usedPercent {
                    existing.usedPercent = item.usedPercent
                    existing.resetAt = item.resetAt ?? existing.resetAt
                } else if existing.resetAt == nil {
                    existing.resetAt = item.resetAt
                }
                pools[poolKey] = existing
            } else {
                pools[poolKey] = PoolAccumulator(
                    id: poolKey,
                    title: poolTitle,
                    order: order,
                    usedPercent: item.usedPercent,
                    resetAt: item.resetAt
                )
            }
        }

        return pools.values
            .sorted { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }
            .map { pool in
                QuotaWindow(
                    id: pool.id,
                    label: pool.title,
                    usedPercent: pool.usedPercent,
                    detailText: String(format: "剩余 %.0f%%", max(0, 100 - pool.usedPercent)),
                    resetAt: pool.resetAt
                )
            }
    }

    private func cacheModelPlaceholder(_ placeholder: String, displayName: String) {
        let prefix = "MODEL_PLACEHOLDER_M"
        guard placeholder.hasPrefix(prefix),
              let num = Int(placeholder.dropFirst(prefix.count)) else {
            return
        }
        dynamicAntigravityModelNames[1000 + num] = displayName
    }

    private func resolveAntigravityAccessToken(
        account: ProviderAccountConfig,
        ephemeralSecrets: [String: String]
    ) async throws -> (accessToken: String, email: String?) {
        let now = Date()
        if let cached = cachedAccessTokens[account.id], cached.expiry > now.addingTimeInterval(60) {
            return (cached.token, account.externalAccountId)
        }

        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?
        var email: String? = account.externalAccountId

        if let credPath = account.credentialFilePath,
           let root = AccountDiscoveryService.readJSONDictionary(at: URL(fileURLWithPath: credPath)) {
            if let tokenObj = root["token"] as? [String: Any] {
                accessToken = tokenObj["access_token"] as? String
                refreshToken = tokenObj["refresh_token"] as? String
                expiry = parseISO8601(tokenObj["expiry"] as? String)
            } else {
                accessToken = root["access_token"] as? String
                refreshToken = root["refresh_token"] as? String
            }
            email = email
                ?? (root["id_token_email"] as? String)
                ?? AccountDiscoveryService.extractEmailFromJWT(root["id_token"] as? String)
        }

        if refreshToken == nil, let raw = KeychainStore.loadSecret(for: account.id) ?? ephemeralSecrets[account.id] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let tokenObj = (json["token"] as? [String: Any]) ?? json
                accessToken = tokenObj["access_token"] as? String
                refreshToken = (tokenObj["refresh_token"] as? String) ?? (json["refreshToken"] as? String)
                expiry = parseISO8601(tokenObj["expiry"] as? String)
                email = email
                    ?? (json["email"] as? String)
                    ?? (json["id_token_email"] as? String)
                    ?? AccountDiscoveryService.extractEmailFromJWT(json["id_token"] as? String)
            } else if trimmed.hasPrefix("ya29.") {
                return (trimmed, email)
            } else {
                refreshToken = trimmed
            }
        }

        if let accessToken, !accessToken.isEmpty,
           let expiry, expiry > now.addingTimeInterval(60) {
            cachedAccessTokens[account.id] = (accessToken, expiry)
            return (accessToken, email)
        }

        guard let refreshToken, !refreshToken.isEmpty else {
            if let accessToken, !accessToken.isEmpty {
                return (accessToken, email)
            }
            throw QuotaError.missingCredential("缺少 Antigravity Google OAuth refresh_token")
        }

        let refreshed = try await refreshGoogleOAuthToken(refreshToken: refreshToken)
        cachedAccessTokens[account.id] = (refreshed.accessToken, refreshed.expiry)
        return (refreshed.accessToken, refreshed.email ?? email)
    }

    private func refreshGoogleOAuthToken(refreshToken: String) async throws -> (accessToken: String, expiry: Date, email: String?) {
        let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
        let secrets = resolveAntigravityClientSecrets()
        let secretCandidates = secrets.isEmpty ? [""] : secrets

        var lastStatus = 0
        for secret in secretCandidates {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let encRefresh = formEncode(refreshToken)
            var form = "grant_type=refresh_token&client_id=\(clientId)&refresh_token=\(encRefresh)"
            if !secret.isEmpty {
                let encSecret = formEncode(secret)
                form += "&client_secret=\(encSecret)"
            }
            req.httpBody = form.data(using: .utf8)

            let (data, resp) = try await session.data(for: req)
            lastStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(lastStatus),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                if !secret.isEmpty {
                    cachedAntigravityClientSecrets = [secret]
                }
                let expiresIn = intValue(json["expires_in"], default: 3599)
                let email = AccountDiscoveryService.extractEmailFromJWT(json["id_token"] as? String)
                return (accessToken, Date().addingTimeInterval(Double(expiresIn)), email)
            }
        }

        throw QuotaError.authFailed("Google OAuth 刷新失败 (HTTP \(lastStatus))")
    }

    /// 从本机已安装的 Antigravity 二进制只读提取桌面端公开 OAuth Client Secret 候选（仓库内不硬编码任何密钥）
    private func resolveAntigravityClientSecrets() -> [String] {
        if let cached = cachedAntigravityClientSecrets {
            return cached
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateBinaries = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "\(home)/.gemini/antigravity-cli/bin/agy",
        ]

        let prefix = Array("GOCSPX-".utf8)
        var found: [String] = []
        var seen = Set<String>()

        for path in candidateBinaries {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                continue
            }
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = rawBuf.count
                guard count > 40 else { return }
                var i = 0
                while i <= count - 35 {
                    if base[i] == prefix[0],
                       base[i + 1] == prefix[1],
                       base[i + 2] == prefix[2],
                       base[i + 3] == prefix[3],
                       base[i + 4] == prefix[4],
                       base[i + 5] == prefix[5],
                       base[i + 6] == prefix[6] {
                        var end = i + 7
                        while end < min(count, i + 48) {
                            let b = base[end]
                            let isAllowed = (b >= 48 && b <= 57) || (b >= 65 && b <= 90)
                                || (b >= 97 && b <= 122) || b == 45 || b == 95
                            if !isAllowed { break }
                            end += 1
                        }
                        let len = end - i
                        if len >= 28 && len <= 42 {
                            let slice = Data(bytes: base + i, count: len)
                            if let str = String(data: slice, encoding: .utf8), seen.insert(str).inserted {
                                found.append(str)
                            }
                        }
                        i = end
                        continue
                    }
                    i += 1
                }
            }
            if !found.isEmpty { break }
        }

        cachedAntigravityClientSecrets = found
        return found
    }

    private struct AntigravityProcessTarget {
        let pid: Int
        let kindOrder: Int // 0 = app, 1 = cli, 2 = ide
        let csrfToken: String
        let ports: [Int]
    }

    private func discoverAntigravityProcessTargets() -> [AntigravityProcessTarget] {
        guard let psOutput = runCommandOutput("/bin/ps", arguments: ["-axo", "pid=,command="]) else {
            return []
        }

        var targets: [AntigravityProcessTarget] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1])
            let lower = cmd.lowercased()

            let isLS = lower.contains("language_server") || lower.contains("language-server")
            let isAgyContext = (lower.contains("--app_data_dir") && lower.contains("antigravity"))
                || lower.contains("/antigravity/")
                || lower.contains("/antigravity.app/")
                || lower.contains("antigravity ide.app/")
            let isHubMode = lower.range(of: #"(?:^|\s)--hub(?:\s|=|$)"#, options: .regularExpression) != nil
            let isCLI = lower.range(of: #"(?:^|/|\\)(?:antigravity-cli|antigravity_cli)(?:\s|/|\\|$)"#, options: .regularExpression) != nil
                || (lower.range(of: #"(?:^|/|\\)agy(?:\s|$)"#, options: .regularExpression) != nil && (isLS || isHubMode))

            let kindOrder: Int? = {
                if isLS && isAgyContext {
                    let isIDE = lower.contains("antigravity ide.app/")
                        || lower.contains("--app_data_dir antigravity-ide")
                        || lower.contains("--app_data_dir=antigravity-ide")
                        || lower.contains("/extensions/antigravity/bin/language_server")
                    return isIDE ? 2 : 0
                }
                if isCLI { return 1 }
                return nil
            }()

            guard let kindOrder else { continue }
            let csrf = extractFlagValue("--csrf_token", in: cmd)
            // App / IDE 以及开启 --hub 的 CLI 需要 CSRF Token；普通本机 CLI 无需 CSRF Token
            if (kindOrder != 1 || isHubMode) && (csrf == nil || csrf!.isEmpty) {
                continue
            }

            let explicitHubPort = extractFlagValue("--hub-port", in: cmd).flatMap(Int.init)
            let extPort = extractFlagValue("--extension_server_port", in: cmd).flatMap(Int.init)
            var discoveredPorts = listeningLocalPorts(forPID: pid)
            if let extPort, !discoveredPorts.contains(extPort) {
                discoveredPorts.append(extPort)
            }
            if let explicitHubPort {
                discoveredPorts.removeAll { $0 == explicitHubPort }
                discoveredPorts.insert(explicitHubPort, at: 0)
            }

            if !discoveredPorts.isEmpty {
                targets.append(AntigravityProcessTarget(
                    pid: pid,
                    kindOrder: kindOrder,
                    csrfToken: csrf ?? "",
                    ports: discoveredPorts
                ))
            }
        }
        return targets.sorted { $0.kindOrder == $1.kindOrder ? $0.pid < $1.pid : $0.kindOrder < $1.kindOrder }
    }

    private func extractFlagValue(_ flag: String, in command: String) -> String? {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (idx, tok) in tokens.enumerated() {
            if tok == flag, idx + 1 < tokens.count {
                return tokens[idx + 1]
            }
            if tok.hasPrefix("\(flag)=") {
                return String(tok.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    private func listeningLocalPorts(forPID pid: Int) -> [Int] {
        guard let out = runCommandOutput("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]) else {
            return []
        }
        var ports: [Int] = []
        for line in out.split(separator: "\n") {
            guard line.contains("LISTEN") else { continue }
            for part in line.split(whereSeparator: { $0.isWhitespace }) {
                if let colonIdx = part.lastIndex(of: ":") {
                    let portStr = part[part.index(after: colonIdx)...]
                    if let port = Int(portStr), !ports.contains(port) {
                        ports.append(port)
                    }
                }
            }
        }
        // Antigravity 2.x 中较高端口一般为纯 HTTP，优先尝试更稳定快捷
        return ports.sorted(by: >)
    }

    private func runCommandOutput(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Shared Helpers

    private func writeJSONAtomically(_ dict: [String: Any], to url: URL, permissions: Int16) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func intValue(_ any: Any?, default fallback: Int = 0) -> Int {
        if let v = any as? Int { return v }
        if let v = any as? Double { return Int(v) }
        if let v = any as? NSNumber { return v.intValue }
        if let v = any as? String { return Int(v) ?? Int(Double(v) ?? Double(fallback)) }
        return fallback
    }

    private func doubleValue(_ any: Any?) -> Double {
        optionalDoubleValue(any) ?? 0
    }

    private func optionalDoubleValue(_ any: Any?) -> Double? {
        guard let any, !(any is NSNull), !(any is Bool) else { return nil }
        if let v = any as? Double, v.isFinite { return v }
        if let v = any as? Int { return Double(v) }
        if let v = any as? NSNumber { return v.doubleValue }
        if let s = any as? String {
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "%", with: "")
            if let v = Double(cleaned), v.isFinite { return v }
        }
        return nil
    }

    private func epochSecondsDate(_ any: Any?) -> Date? {
        let secs = doubleValue(any)
        guard secs > 0 else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        return FastDateParser.parseISO8601(str)
    }

    private func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

// MARK: - Supporting Types

struct OfflineCodexRateLimit: Sendable {
    var timestamp: Date
    var planType: String?
    var primaryUsedPercent: Double?
    var primaryResetAt: Date?
    var secondaryUsedPercent: Double?
    var secondaryResetAt: Date?
}

enum QuotaError: Error, LocalizedError {
    case missingCredential(String)
    case authFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let msg), .authFailed(let msg), .invalidResponse(let msg):
            return msg
        }
    }
}

/// 拦截 3xx 重定向，使小米控制台等网关的未登录 302 跳转能作为鉴权失效精准识别
private final class ManualRedirectBlockDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 仅用于 127.0.0.1 本机 Antigravity Language Server 自签名证书回退
private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - FastDateParser (零分配高速 ISO-8601 解析 + Formatter 兜底)

enum FastDateParser {
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 高速解析标准 ISO-8601 字符串（如 "2026-10-31T13:07:55.822Z" 或 "+08:00"），比每次创建 ISO8601DateFormatter 快 50 倍以上
    static func parseISO8601(_ raw: String) -> Date? {
        let utf8 = Array(raw.utf8)
        // 最小长度 "YYYY-MM-DDTHH:MM:SSZ" = 20 字节
        if utf8.count >= 20,
           utf8[4] == 45, utf8[7] == 45,
           (utf8[10] == 84 || utf8[10] == 116 || utf8[10] == 32),
           utf8[13] == 58, utf8[16] == 58 {
            if let year = parse4(utf8, 0),
               let month = parse2(utf8, 5),
               let day = parse2(utf8, 8),
               let hour = parse2(utf8, 11),
               let minute = parse2(utf8, 14),
               let second = parse2(utf8, 17) {
                var idx = 19
                var fracSeconds: Double = 0
                if idx < utf8.count && utf8[idx] == 46 { // '.'
                    idx += 1
                    var scale = 0.1
                    while idx < utf8.count && utf8[idx] >= 48 && utf8[idx] <= 57 {
                        fracSeconds += Double(utf8[idx] - 48) * scale
                        scale *= 0.1
                        idx += 1
                    }
                }
                var tzOffsetSeconds = 0
                if idx < utf8.count {
                    let c = utf8[idx]
                    if c == 90 || c == 122 { // 'Z' or 'z'
                        tzOffsetSeconds = 0
                    } else if (c == 43 || c == 45), idx + 5 < utf8.count,
                              let tzH = parse2(utf8, idx + 1),
                              let tzM = parse2(utf8, idx + 4) {
                        let sign = (c == 43) ? 1 : -1
                        tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
                    } else {
                        return fallbackParse(raw)
                    }
                }
                if let epoch = utcEpochSeconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second) {
                    return Date(timeIntervalSince1970: Double(epoch - tzOffsetSeconds) + fracSeconds)
                }
            }
        }
        return fallbackParse(raw)
    }

    private static func fallbackParse(_ raw: String) -> Date? {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        return isoFractional.date(from: raw) ?? isoBasic.date(from: raw)
    }

    @inline(__always)
    private static func parse2(_ bytes: [UInt8], _ offset: Int) -> Int? {
        let a = bytes[offset], b = bytes[offset + 1]
        guard a >= 48, a <= 57, b >= 48, b <= 57 else { return nil }
        return Int(a - 48) * 10 + Int(b - 48)
    }

    @inline(__always)
    private static func parse4(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard let hi = parse2(bytes, offset), let lo = parse2(bytes, offset + 2) else { return nil }
        return hi * 100 + lo
    }

    /// Howard Hinnant civil_from_days 逆运算：无锁纯算术计算 UTC epoch 秒
    @inline(__always)
    private static func utcEpochSeconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int? {
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month + (month > 2 ? -3 : 9)
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return days * 86400 + hour * 3600 + minute * 60 + second
    }
}
