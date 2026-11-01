import Foundation
import CryptoKit
import SQLite

/// 自动扫描本机已有配置（~/.codex、~/.cc-switch、~/.local/share/mimocode、~/.kimi*、~/.local/share/opencode、~/.gemini/antigravity*）
/// 并与用户在设置页添加/覆盖的多账号配置合并。
struct DiscoveredAccountBundle: Sendable {
    let allAccounts: [ProviderAccountConfig]
    let enabledAccounts: [ProviderAccountConfig]
    /// 自动发现阶段从本机配置文件/数据库中提取的内存态密钥（不额外落盘）
    let ephemeralSecrets: [String: String]
    /// 当前在 `$CODEX_HOME/auth.json` 中处于系统激活状态的 Codex 账号 ID 集合
    let activeCodexAccountIds: Set<String>
}

enum AccountDiscoveryService {
    static func resolveAccounts(
        manualAccounts: [ProviderAccountConfig],
        overrides: [String: AccountOverride],
        enableAutoDiscovery: Bool
    ) -> DiscoveredAccountBundle {
        var discovered: [ProviderAccountConfig] = []
        var secrets: [String: String] = [:]
        var activeCodexIds = Set<String>()

        let home = FileManager.default.homeDirectoryForCurrentUser
        if enableAutoDiscovery {
            discoverCodex(home: home, into: &discovered, secrets: &secrets, activeIds: &activeCodexIds)
            discoverMiMoAndMiniMaxAndKimi(home: home, into: &discovered, secrets: &secrets)
            discoverAntigravity(home: home, into: &discovered, secrets: &secrets)
        }

        // 若手动添加的 Codex OAuth 账号恰好是当前 ~/.codex/auth.json 活跃账号，同样标记激活态
        let liveCodex = CodexAccountSwitchService.currentActiveIdentity(home: home)
        if let liveAcctId = liveCodex.chatgptAccountId?.lowercased(), !liveAcctId.isEmpty {
            for manual in manualAccounts where manual.provider == .codex {
                if manual.externalAccountId?.lowercased() == liveAcctId {
                    activeCodexIds.insert(manual.id)
                }
            }
        }

        // 应用用户对自动发现账号的本地覆盖
        let adjustedDiscovered: [ProviderAccountConfig] = discovered.map { raw in
            guard let ov = overrides[raw.id] else { return raw }
            var copy = raw
            if let customLabel = ov.customLabel, !customLabel.isEmpty {
                copy.label = customLabel
            }
            if let isEnabled = ov.isEnabled {
                copy.isEnabled = isEnabled
            }
            if let customLogPath = ov.customLogPath, !customLogPath.isEmpty {
                copy.customLogPath = customLogPath
            }
            if let region = ov.regionOrBaseURL, !region.isEmpty {
                copy.regionOrBaseURL = region
            }
            return copy
        }

        let all = adjustedDiscovered + manualAccounts
        let enabled = all.filter(\.isEnabled)
        return DiscoveredAccountBundle(
            allAccounts: all,
            enabledAccounts: enabled,
            ephemeralSecrets: secrets,
            activeCodexAccountIds: activeCodexIds
        )
    }

    // MARK: - 1. Codex Discovery

    private static func discoverCodex(
        home: URL,
        into accounts: inout [ProviderAccountConfig],
        secrets: inout [String: String],
        activeIds: inout Set<String>
    ) {
        var seenChatGPTAccountIds = Set<String>()
        let ccSwitchNames = loadCCSwitchCodexOAuthNames(home: home)
        let codexHome = CodexAccountSwitchService.codexHomeDirectory(home: home)

        // 1) ~/.cc-switch/codex_oauth_auth.json (主多账号 OAuth 库)
        let ccOAuthURL = home.appendingPathComponent(".cc-switch/codex_oauth_auth.json")
        if let root = readJSONDictionary(at: ccOAuthURL),
           let accountsDict = root["accounts"] as? [String: Any] {
            let sortedKeys = accountsDict.keys.sorted()
            for key in sortedKeys {
                guard let item = accountsDict[key] as? [String: Any] else { continue }
                let chatgptAcctId = (item["chatgpt_account_id"] as? String)
                    ?? (item["account_id"] as? String)
                    ?? key
                let email = (item["email"] as? String)
                    ?? extractEmailFromJWT(item["id_token"] as? String)
                let friendlyName = ccSwitchNames[key] ?? email ?? "Codex (\(chatgptAcctId.prefix(8)))"
                let id = "auto.codex.oauth.\(shortHash(chatgptAcctId))"
                seenChatGPTAccountIds.insert(chatgptAcctId)

                let cfg = ProviderAccountConfig(
                    id: id,
                    provider: .codex,
                    label: friendlyName,
                    source: .autoDiscovered,
                    authKind: .oauthToken,
                    isEnabled: true,
                    externalAccountId: chatgptAcctId,
                    credentialFilePath: ccOAuthURL.path,
                    credentialLookupKey: key,
                    originDescription: "CC Switch"
                )
                accounts.append(cfg)
            }
        }

        // 2) $CODEX_HOME/auth.json (当前活跃 Codex CLI / Desktop 凭证)
        let codexAuthURL = codexHome.appendingPathComponent("auth.json")
        if let root = readJSONDictionary(at: codexAuthURL) {
            if let tokens = root["tokens"] as? [String: Any] {
                let accessToken = tokens["access_token"] as? String
                let refreshToken = tokens["refresh_token"] as? String
                let idToken = tokens["id_token"] as? String
                let chatgptAcctId = (tokens["account_id"] as? String)
                    ?? extractChatGPTAccountIdFromJWT(accessToken)
                    ?? extractChatGPTAccountIdFromJWT(idToken)
                let email = extractEmailFromJWT(idToken) ?? extractEmailFromJWT(accessToken)

                if let chatgptAcctId, seenChatGPTAccountIds.contains(chatgptAcctId) {
                    // 若已在 CC Switch 发现同一账号，补充活跃态 access_token 以便免刷新直接调接口，并标记为当前活跃账号
                    let existingId = "auto.codex.oauth.\(shortHash(chatgptAcctId))"
                    activeIds.insert(existingId)
                    if let accessToken, !accessToken.isEmpty {
                        secrets["\(existingId).live_access"] = accessToken
                    }
                    if let idx = accounts.firstIndex(where: { $0.id == existingId }),
                       accounts[idx].customLogPath == nil {
                        accounts[idx].customLogPath = codexHome.path
                    }
                } else if (accessToken != nil || refreshToken != nil) {
                    let keySeed = chatgptAcctId ?? email ?? "default"
                    let id = "auto.codex.cli.\(shortHash(keySeed))"
                    activeIds.insert(id)
                    if let chatgptAcctId { seenChatGPTAccountIds.insert(chatgptAcctId) }
                    if let accessToken { secrets["\(id).live_access"] = accessToken }
                    let cfg = ProviderAccountConfig(
                        id: id,
                        provider: .codex,
                        label: email ?? "Codex 本机默认",
                        source: .autoDiscovered,
                        authKind: .oauthToken,
                        isEnabled: true,
                        externalAccountId: chatgptAcctId,
                        credentialFilePath: codexAuthURL.path,
                        originDescription: "~/.codex",
                        customLogPath: codexHome.path
                    )
                    accounts.append(cfg)
                }
            } else if let apiKey = root["OPENAI_API_KEY"] as? String,
                      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let configText = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
                let lowerCfg = configText.lowercased()
                if !lowerCfg.contains("xiaomimimo.com")
                    && !lowerCfg.contains("minimaxi.com")
                    && !lowerCfg.contains("minimax.io")
                    && !lowerCfg.contains("kimi.com") {
                    let id = "auto.codex.apikey.\(shortHash(apiKey))"
                    activeIds.insert(id)
                    secrets[id] = apiKey
                    accounts.append(ProviderAccountConfig(
                        id: id,
                        provider: .codex,
                        label: "Codex (API Key)",
                        source: .autoDiscovered,
                        authKind: .apiKey,
                        isEnabled: true,
                        credentialFilePath: codexAuthURL.path,
                        originDescription: "~/.codex",
                        customLogPath: codexHome.path
                    ))
                }
            }
        }

        // 3) TokenUse 自动托管备份的 Codex 账号目录 (managed-codex-homes/*/auth.json)
        let managedDir = CodexAccountSwitchService.managedHomesDirectory()
        if let folders = try? FileManager.default.contentsOfDirectory(at: managedDir, includingPropertiesForKeys: nil) {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let authFile = folder.appendingPathComponent("auth.json")
                guard let root = readJSONDictionary(at: authFile),
                      let tokens = root["tokens"] as? [String: Any],
                      let refreshToken = tokens["refresh_token"] as? String,
                      !refreshToken.isEmpty else { continue }
                let accessToken = tokens["access_token"] as? String
                let idToken = tokens["id_token"] as? String
                let chatgptAcctId = (tokens["account_id"] as? String)
                    ?? extractChatGPTAccountIdFromJWT(accessToken)
                    ?? extractChatGPTAccountIdFromJWT(idToken)
                if let chatgptAcctId, seenChatGPTAccountIds.contains(chatgptAcctId) {
                    continue
                }
                if let chatgptAcctId { seenChatGPTAccountIds.insert(chatgptAcctId) }
                let email = extractEmailFromJWT(idToken) ?? extractEmailFromJWT(accessToken)
                let id = "auto.codex.managed.\(shortHash(chatgptAcctId ?? email ?? folder.lastPathComponent))"
                if let accessToken { secrets["\(id).live_access"] = accessToken }
                accounts.append(ProviderAccountConfig(
                    id: id,
                    provider: .codex,
                    label: email ?? "Codex 托管账号",
                    source: .autoDiscovered,
                    authKind: .oauthToken,
                    isEnabled: true,
                    externalAccountId: chatgptAcctId,
                    credentialFilePath: authFile.path,
                    originDescription: "已备份账号"
                ))
            }
        }

        // 4) ~/.cc-switch/codex-login-stash.json (暂存登录)
        let stashURL = home.appendingPathComponent(".cc-switch/codex-login-stash.json")
        if let root = readJSONDictionary(at: stashURL),
           let logins = root["logins"] as? [String: Any] {
            for (stashKey, value) in logins {
                guard let loginObj = value as? [String: Any],
                      let tokens = loginObj["tokens"] as? [String: Any] else { continue }
                let idToken = tokens["id_token"] as? String
                let accessToken = tokens["access_token"] as? String
                let chatgptAcctId = (tokens["account_id"] as? String)
                    ?? extractChatGPTAccountIdFromJWT(accessToken)
                    ?? extractChatGPTAccountIdFromJWT(idToken)
                if let chatgptAcctId, seenChatGPTAccountIds.contains(chatgptAcctId) {
                    continue
                }
                if let chatgptAcctId { seenChatGPTAccountIds.insert(chatgptAcctId) }
                let email = extractEmailFromJWT(idToken) ?? extractEmailFromJWT(accessToken)
                let id = "auto.codex.stash.\(shortHash(chatgptAcctId ?? stashKey))"
                if let accessToken { secrets["\(id).live_access"] = accessToken }
                accounts.append(ProviderAccountConfig(
                    id: id,
                    provider: .codex,
                    label: email ?? "Codex 暂存 (\(stashKey.prefix(8)))",
                    source: .autoDiscovered,
                    authKind: .oauthToken,
                    isEnabled: true,
                    externalAccountId: chatgptAcctId,
                    credentialFilePath: stashURL.path,
                    credentialLookupKey: stashKey,
                    originDescription: "CC Switch Stash"
                ))
            }
        }
    }

    private static func loadCCSwitchCodexOAuthNames(home: URL) -> [String: String] {
        let dbURL = home.appendingPathComponent(".cc-switch/cc-switch.db")
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = try? Connection(dbURL.path, readonly: true) else {
            return [:]
        }
        var map: [String: String] = [:]
        let sql = "SELECT name, meta FROM providers WHERE app_type = 'codex'"
        if let stmt = try? db.prepare(sql) {
            for row in stmt {
                guard let name = row[0] as? String,
                      let metaStr = row[1] as? String,
                      let metaData = metaStr.data(using: .utf8),
                      let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                      let binding = meta["authBinding"] as? [String: Any],
                      let accountId = binding["accountId"] as? String else {
                    continue
                }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    map[accountId] = trimmed
                }
            }
        }
        return map
    }

    // MARK: - 2. MiMo / Kimi / MiniMax Discovery

    private static func discoverMiMoAndMiniMaxAndKimi(
        home: URL,
        into accounts: inout [ProviderAccountConfig],
        secrets: inout [String: String]
    ) {
        var seenKeyHashes: [TrackedProvider: Set<String>] = [
            .mimo: [],
            .kimi: [],
            .minimax: [],
        ]

        func appendKeyAccount(
            provider: TrackedProvider,
            rawKey: String,
            label: String,
            regionOrBaseURL: String?,
            externalId: String? = nil,
            origin: String,
            logPath: String? = nil
        ) {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let hash = shortHash(trimmed)
            guard seenKeyHashes[provider, default: []].insert(hash).inserted else { return }

            let id = "auto.\(provider.rawValue).key.\(hash)"
            secrets[id] = trimmed
            accounts.append(ProviderAccountConfig(
                id: id,
                provider: provider,
                label: label,
                source: .autoDiscovered,
                authKind: .apiKey,
                isEnabled: true,
                regionOrBaseURL: regionOrBaseURL,
                externalAccountId: externalId,
                originDescription: origin,
                customLogPath: logPath
            ))
        }

        let envMap = ProcessInfo.processInfo.environment

        // A) MiMo: ~/.local/share/mimocode, $XDG_DATA_HOME/mimocode, Orca 沙盒目录, ~/.config/mimocode/mimocode.json
        let mimoShareDir = home.appendingPathComponent(".local/share/mimocode")
        let orcaMimoDir = home.appendingPathComponent("Library/Application Support/orca/mimocode-hooks/shared/data")
        var mimoDataDirs: [(URL, String)] = [
            (mimoShareDir, "mimocode"),
            (orcaMimoDir, "MiMo Desktop"),
        ]
        if let xdg = envMap["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            mimoDataDirs.insert((URL(fileURLWithPath: xdg).appendingPathComponent("mimocode"), "mimocode"), at: 0)
        }

        for (dir, originTag) in mimoDataDirs {
            let authURL = dir.appendingPathComponent("auth.json")
            guard let root = readJSONDictionary(at: authURL) else { continue }
            for (providerKey, val) in root {
                let lowerKey = providerKey.lowercased()
                guard lowerKey.contains("xiaomi") || lowerKey.contains("mimo"),
                      let dict = val as? [String: Any],
                      let apiKey = dict["key"] as? String else { continue }
                let meta = dict["metadata"] as? [String: Any]
                let uid: String? = {
                    if let s = meta?["uid"] as? String, !s.isEmpty { return s }
                    if let n = meta?["uid"] as? NSNumber { return n.stringValue }
                    return nil
                }()
                let baseURL = meta?["base_url"] as? String
                let label = uid.map { "MiMo (\(maskIdentifier($0)))" } ?? "MiMo Code (\(providerKey))"
                appendKeyAccount(
                    provider: .mimo,
                    rawKey: apiKey,
                    label: label,
                    regionOrBaseURL: baseURL,
                    externalId: uid,
                    origin: originTag,
                    logPath: dir.path
                )
            }
        }

        let mimoConfigURL = home.appendingPathComponent(".config/mimocode/mimocode.json")
        if let root = readJSONDictionary(at: mimoConfigURL),
           let providers = root["provider"] as? [String: Any] {
            for (pKey, val) in providers {
                let lower = pKey.lowercased()
                guard lower.contains("xiaomi") || lower.contains("mimo"),
                      let pDict = val as? [String: Any],
                      let options = pDict["options"] as? [String: Any],
                      let apiKey = options["apiKey"] as? String else { continue }
                let baseURL = options["baseURL"] as? String
                let name = (pDict["name"] as? String) ?? "MiMo (\(pKey))"
                appendKeyAccount(
                    provider: .mimo,
                    rawKey: apiKey,
                    label: name,
                    regionOrBaseURL: baseURL,
                    origin: "mimocode.json",
                    logPath: mimoShareDir.path
                )
            }
        }

        // A2) Xiaomi MiMo 桌面端免登录通行证会话 (Partitions/xiaomi-account/Cookies -> passToken + userId)
        if let desktopSeed = MimoSessionMinter.readLocalDesktopAccountSeed(home: home) {
            if let matchedIdx = accounts.firstIndex(where: {
                $0.provider == .mimo && $0.externalAccountId == desktopSeed.userId
            }) ?? accounts.firstIndex(where: {
                $0.provider == .mimo && $0.externalAccountId == nil
            }) {
                let targetId = accounts[matchedIdx].id
                accounts[matchedIdx].externalAccountId = desktopSeed.userId
                secrets["\(targetId).xiaomi_account"] = desktopSeed.accountCookieHeader
            } else {
                let id = "auto.mimo.desktop.\(shortHash(desktopSeed.userId))"
                secrets["\(id).xiaomi_account"] = desktopSeed.accountCookieHeader
                accounts.append(ProviderAccountConfig(
                    id: id,
                    provider: .mimo,
                    label: "MiMo (\(maskIdentifier(desktopSeed.userId)))",
                    source: .autoDiscovered,
                    authKind: .cookie,
                    isEnabled: true,
                    externalAccountId: desktopSeed.userId,
                    originDescription: "MiMo Desktop",
                    customLogPath: mimoShareDir.path
                ))
            }
        } else if let envMimoCookie = envMap["MIMO_COOKIE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !envMimoCookie.isEmpty {
            let id = "auto.mimo.env.\(shortHash(envMimoCookie))"
            secrets[id] = envMimoCookie
            accounts.append(ProviderAccountConfig(
                id: id,
                provider: .mimo,
                label: "MiMo (MIMO_COOKIE)",
                source: .autoDiscovered,
                authKind: .cookie,
                isEnabled: true,
                originDescription: "ENV"
            ))
        }

        // B) Kimi: $KIMI_CODE_HOME, ~/.kimi-code, Kimi Desktop (kimi-desktop), ~/.kimi
        var kimiDirs: [(URL, String)] = []
        if let envKimiHome = envMap["KIMI_CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envKimiHome.isEmpty {
            kimiDirs.append((URL(fileURLWithPath: envKimiHome), "$KIMI_CODE_HOME"))
        }
        kimiDirs.append((home.appendingPathComponent(".kimi-code"), "~/.kimi-code"))
        kimiDirs.append((
            home.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home"),
            "Kimi Desktop"
        ))
        kimiDirs.append((home.appendingPathComponent(".kimi"), "~/.kimi"))

        var seenKimiRefreshHashes = Set<String>()
        var seenKimiPaths = Set<String>()
        for (dir, origin) in kimiDirs {
            let canonical = dir.standardizedFileURL.path
            guard seenKimiPaths.insert(canonical).inserted,
                  FileManager.default.fileExists(atPath: canonical) else { continue }
            let configText = (try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            let baseURL = extractTOMLValue(key: "base_url", in: configText) ?? "https://api.kimi.com/coding/v1"

            let credsDir = dir.appendingPathComponent("credentials")
            if let files = try? FileManager.default.contentsOfDirectory(at: credsDir, includingPropertiesForKeys: nil) {
                for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                    guard let cred = readJSONDictionary(at: file),
                          let accessToken = cred["access_token"] as? String,
                          !accessToken.isEmpty else { continue }
                    let refreshToken = (cred["refresh_token"] as? String) ?? accessToken
                    let rHash = shortHash(refreshToken)
                    guard seenKimiRefreshHashes.insert(rHash).inserted else { continue }

                    let stem = file.deletingPathExtension().lastPathComponent
                    let label = stem == "kimi-code" ? "Kimi Code (\(origin))" : "Kimi (\(stem))"
                    let id = "auto.kimi.oauth.\(rHash)"
                    accounts.append(ProviderAccountConfig(
                        id: id,
                        provider: .kimi,
                        label: label,
                        source: .autoDiscovered,
                        authKind: .oauthToken,
                        isEnabled: true,
                        regionOrBaseURL: baseURL,
                        credentialFilePath: file.path,
                        originDescription: origin,
                        customLogPath: dir.path
                    ))
                }
            }

            if let staticKey = extractTOMLValue(key: "api_key", in: configText),
               !staticKey.isEmpty {
                appendKeyAccount(
                    provider: .kimi,
                    rawKey: staticKey,
                    label: "Kimi API (\(origin))",
                    regionOrBaseURL: baseURL,
                    origin: origin,
                    logPath: dir.path
                )
            }
        }

        if let envKimiKey = envMap["KIMI_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envKimiKey.isEmpty {
            appendKeyAccount(
                provider: .kimi,
                rawKey: envKimiKey,
                label: "Kimi Code (ENV)",
                regionOrBaseURL: nil,
                origin: "ENV"
            )
        }
        if let envKimiWeb = (envMap["KIMI_AUTH_TOKEN"] ?? envMap["KIMI_MANUAL_COOKIE"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKimiWeb.isEmpty {
            let id = "auto.kimi.web.\(shortHash(envKimiWeb))"
            secrets[id] = envKimiWeb
            accounts.append(ProviderAccountConfig(
                id: id,
                provider: .kimi,
                label: "Kimi Web (ENV)",
                source: .autoDiscovered,
                authKind: .cookie,
                isEnabled: true,
                originDescription: "Kimi Web"
            ))
        }

        // C) OpenCode: ~/.local/share/opencode/auth.json (MiniMax / MiMo / Kimi)
        let openCodeAuthURL = home.appendingPathComponent(".local/share/opencode/auth.json")
        if let root = readJSONDictionary(at: openCodeAuthURL) {
            for (providerKey, val) in root {
                guard let dict = val as? [String: Any],
                      let key = dict["key"] as? String,
                      !key.isEmpty else { continue }
                let lower = providerKey.lowercased()
                if lower.contains("minimax") || key.hasPrefix("sk-cp-") {
                    let region = lower.contains("-cn") ? "cn" : nil
                    appendKeyAccount(
                        provider: .minimax,
                        rawKey: key,
                        label: "MiniMax (\(providerKey))",
                        regionOrBaseURL: region,
                        origin: "OpenCode",
                        logPath: home.appendingPathComponent(".local/share/opencode").path
                    )
                } else if lower.contains("xiaomi") || lower.contains("mimo") || key.hasPrefix("tp-") {
                    appendKeyAccount(
                        provider: .mimo,
                        rawKey: key,
                        label: "MiMo (\(providerKey))",
                        regionOrBaseURL: nil,
                        origin: "OpenCode"
                    )
                } else if lower.contains("kimi") || lower.contains("moonshot") || key.hasPrefix("sk-kimi-") {
                    appendKeyAccount(
                        provider: .kimi,
                        rawKey: key,
                        label: "Kimi (\(providerKey))",
                        regionOrBaseURL: nil,
                        origin: "OpenCode"
                    )
                }
            }
        }

        // D) Claude Code settings.json: ~/.claude/settings.json
        let claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
        if let root = readJSONDictionary(at: claudeSettingsURL),
           let env = root["env"] as? [String: Any] {
            let token = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String)
            let baseURL = (env["ANTHROPIC_BASE_URL"] as? String) ?? ""
            let lowerURL = baseURL.lowercased()
            if let token, !token.isEmpty {
                if lowerURL.contains("minimaxi.com") || lowerURL.contains("minimax.io") || token.hasPrefix("sk-cp-") {
                    appendKeyAccount(
                        provider: .minimax,
                        rawKey: token,
                        label: "MiniMax (Claude Code)",
                        regionOrBaseURL: baseURL,
                        origin: "~/.claude"
                    )
                } else if lowerURL.contains("xiaomimimo.com") || token.hasPrefix("tp-") {
                    appendKeyAccount(
                        provider: .mimo,
                        rawKey: token,
                        label: "MiMo (Claude Code)",
                        regionOrBaseURL: baseURL,
                        origin: "~/.claude"
                    )
                } else if lowerURL.contains("kimi.com") || lowerURL.contains("kimi.ai") || token.hasPrefix("sk-kimi-") {
                    appendKeyAccount(
                        provider: .kimi,
                        rawKey: token,
                        label: "Kimi (Claude Code)",
                        regionOrBaseURL: baseURL,
                        origin: "~/.claude"
                    )
                }
            }
        }

        // E) CC Switch 数据库: ~/.cc-switch/cc-switch.db (支持同一平台配置多个 Provider 行)
        let ccDBURL = home.appendingPathComponent(".cc-switch/cc-switch.db")
        if FileManager.default.fileExists(atPath: ccDBURL.path),
           let db = try? Connection(ccDBURL.path, readonly: true) {
            let sql = "SELECT id, app_type, name, settings_config, website_url, icon, meta FROM providers ORDER BY sort_index ASC, created_at ASC"
            if let stmt = try? db.prepare(sql) {
                for row in stmt {
                    let appType = (row[1] as? String) ?? ""
                    let name = (row[2] as? String) ?? ""
                    let settingsStr = (row[3] as? String) ?? "{}"
                    let websiteURL = (row[4] as? String) ?? ""
                    let icon = ((row[5] as? String) ?? "").lowercased()
                    let metaStr = (row[6] as? String) ?? "{}"

                    let settings = (settingsStr.data(using: .utf8)).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    } ?? [:]
                    let meta = (metaStr.data(using: .utf8)).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    } ?? [:]

                    let extracted = extractCCSwitchCredentials(settings: settings, websiteURL: websiteURL)
                    guard let apiKey = extracted.apiKey, !apiKey.isEmpty else { continue }
                    let lowerURL = (extracted.baseURL ?? websiteURL).lowercased()
                    let codingPlanProvider = ((meta["usage_script"] as? [String: Any])?["codingPlanProvider"] as? String)?.lowercased()

                    if icon == "minimax" || codingPlanProvider == "minimax"
                        || lowerURL.contains("minimaxi.com") || lowerURL.contains("minimax.io")
                        || apiKey.hasPrefix("sk-cp-") {
                        appendKeyAccount(
                            provider: .minimax,
                            rawKey: apiKey,
                            label: name.isEmpty ? "MiniMax (\(appType))" : "\(name) (\(appType))",
                            regionOrBaseURL: extracted.baseURL ?? websiteURL,
                            origin: "CC Switch"
                        )
                    } else if icon == "xiaomi" || icon == "mimo" || codingPlanProvider == "xiaomi"
                        || lowerURL.contains("xiaomimimo.com") || apiKey.hasPrefix("tp-") {
                        appendKeyAccount(
                            provider: .mimo,
                            rawKey: apiKey,
                            label: name.isEmpty ? "MiMo (\(appType))" : "\(name) (\(appType))",
                            regionOrBaseURL: extracted.baseURL ?? websiteURL,
                            origin: "CC Switch"
                        )
                    } else if icon == "kimi" || icon == "moonshot" || codingPlanProvider == "kimi"
                        || lowerURL.contains("kimi.com") || lowerURL.contains("kimi.ai")
                        || apiKey.hasPrefix("sk-kimi-") {
                        appendKeyAccount(
                            provider: .kimi,
                            rawKey: apiKey,
                            label: name.isEmpty ? "Kimi (\(appType))" : "\(name) (\(appType))",
                            regionOrBaseURL: extracted.baseURL ?? websiteURL,
                            origin: "CC Switch"
                        )
                    }
                }
            }
        }

        // E2) MiniMax 环境变量与 MiniMax Code 本地目录发现
        if let envMinimaxKey = (envMap["MINIMAX_CODING_API_KEY"] ?? envMap["MINIMAX_API_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envMinimaxKey.isEmpty {
            let regionHint = envMap["MINIMAX_API_REGION"] ?? envMap["MINIMAX_API_HOST"]
            appendKeyAccount(
                provider: .minimax,
                rawKey: envMinimaxKey,
                label: "MiniMax (ENV)",
                regionOrBaseURL: regionHint,
                origin: "ENV"
            )
        }

        let hasMiniMax = accounts.contains { $0.provider == .minimax }
        if !hasMiniMax {
            let mcodeCandidates = [
                envMap["MINIMAX_DATA_DIR"].map { URL(fileURLWithPath: $0) },
                envMap["MAVIS_DATA_DIR"].map { URL(fileURLWithPath: $0) },
                home.appendingPathComponent(".minimax"),
                home.appendingPathComponent(".mavis"),
            ].compactMap { $0 }
            if let existingMcode = mcodeCandidates.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("v2/sessions").path)
            }) {
                accounts.append(ProviderAccountConfig(
                    id: "auto.minimax.local",
                    provider: .minimax,
                    label: "MiniMax Code 本机日志",
                    source: .autoDiscovered,
                    authKind: .localOnly,
                    isEnabled: true,
                    originDescription: existingMcode.lastPathComponent,
                    customLogPath: existingMcode.path
                ))
            }
        }

        // F) 保底：若未发现任何带密钥的 MiMo 账号，但 mimocode.db 存在，建立本地统计账号以便挂载控制台 Cookie
        let hasMiMo = accounts.contains { $0.provider == .mimo }
        let mimoDBCandidates = [
            mimoShareDir.appendingPathComponent("mimocode.db"),
            orcaMimoDir.appendingPathComponent("mimocode.db"),
        ]
        if !hasMiMo, let existingDB = mimoDBCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            accounts.append(ProviderAccountConfig(
                id: "auto.mimo.local",
                provider: .mimo,
                label: "MiMo Code 本机日志",
                source: .autoDiscovered,
                authKind: .localOnly,
                isEnabled: true,
                originDescription: "mimocode.db",
                customLogPath: existingDB.deletingLastPathComponent().path
            ))
        }
    }

    private static func extractCCSwitchCredentials(
        settings: [String: Any],
        websiteURL: String
    ) -> (apiKey: String?, baseURL: String?) {
        let env = settings["env"] as? [String: Any]
        let auth = settings["auth"] as? [String: Any]
        let options = settings["options"] as? [String: Any]
        let configTOML = settings["config"] as? String

        let keyCandidates: [String?] = [
            env?["ANTHROPIC_AUTH_TOKEN"] as? String,
            env?["ANTHROPIC_API_KEY"] as? String,
            auth?["OPENAI_API_KEY"] as? String,
            env?["OPENAI_API_KEY"] as? String,
            settings["apiKey"] as? String,
            options?["apiKey"] as? String,
        ]
        let apiKey = keyCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let urlCandidates: [String?] = [
            env?["ANTHROPIC_BASE_URL"] as? String,
            settings["baseUrl"] as? String,
            options?["baseURL"] as? String,
            configTOML.flatMap { extractTOMLValue(key: "base_url", in: $0) },
            websiteURL,
        ]
        let baseURL = urlCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return (apiKey, baseURL)
    }

    // MARK: - 3. Antigravity Discovery

    private static func discoverAntigravity(
        home: URL,
        into accounts: inout [ProviderAccountConfig],
        secrets: inout [String: String]
    ) {
        var seenEmails = Set<String>()
        let envMap = ProcessInfo.processInfo.environment

        var officialSources: [(URL, String, URL)] = [
            (
                home.appendingPathComponent(".gemini/jetski-standalone-oauth-token"),
                "Antigravity IDE",
                home.appendingPathComponent(".gemini/antigravity")
            ),
            (
                home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
                "Antigravity CLI",
                home.appendingPathComponent(".gemini/antigravity-cli")
            ),
        ]
        if let geminiCliHome = envMap["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !geminiCliHome.isEmpty {
            let cliDir = URL(fileURLWithPath: geminiCliHome).appendingPathComponent("antigravity-cli")
            officialSources.append((
                cliDir.appendingPathComponent("antigravity-oauth-token"),
                "Antigravity CLI",
                cliDir
            ))
        }

        for (tokenURL, origin, defaultLogDir) in officialSources {
            guard let root = readJSONDictionary(at: tokenURL),
                  let tokenDict = root["token"] as? [String: Any],
                  let refreshToken = tokenDict["refresh_token"] as? String,
                  !refreshToken.isEmpty else {
                continue
            }
            let email = (root["id_token_email"] as? String)
                ?? extractEmailFromJWT(root["id_token"] as? String)
            let normalizedEmail = email?.lowercased()

            if let normalizedEmail, seenEmails.contains(normalizedEmail) {
                continue
            }
            if let normalizedEmail { seenEmails.insert(normalizedEmail) }

            let keySeed = normalizedEmail ?? shortHash(refreshToken)
            let id = "auto.antigravity.oauth.\(shortHash(keySeed))"
            accounts.append(ProviderAccountConfig(
                id: id,
                provider: .antigravity,
                label: email ?? origin,
                source: .autoDiscovered,
                authKind: .oauthToken,
                isEnabled: true,
                externalAccountId: email,
                credentialFilePath: tokenURL.path,
                originDescription: origin,
                customLogPath: defaultLogDir.path
            ))
        }

        // OpenCode Antigravity Auth 插件多账号库（若存在）
        let openCodeAgyURL = home.appendingPathComponent(".config/opencode/antigravity-accounts.json")
        if let root = readJSONDictionary(at: openCodeAgyURL),
           let list = root["accounts"] as? [[String: Any]] {
            for item in list {
                guard let refreshToken = item["refreshToken"] as? String, !refreshToken.isEmpty else { continue }
                let email = item["email"] as? String
                let normalizedEmail = email?.lowercased()
                if let normalizedEmail, seenEmails.contains(normalizedEmail) { continue }
                if let normalizedEmail { seenEmails.insert(normalizedEmail) }

                let id = "auto.antigravity.opencode.\(shortHash(normalizedEmail ?? refreshToken))"
                secrets[id] = refreshToken
                accounts.append(ProviderAccountConfig(
                    id: id,
                    provider: .antigravity,
                    label: email ?? "Antigravity (OpenCode)",
                    source: .autoDiscovered,
                    authKind: .oauthToken,
                    isEnabled: true,
                    regionOrBaseURL: item["projectId"] as? String,
                    externalAccountId: email,
                    credentialFilePath: openCodeAgyURL.path,
                    originDescription: "OpenCode Plugin"
                ))
            }
        }

        // ~/.antigravity_tools/accounts/*.json（若存在）
        let agyToolsDir = home.appendingPathComponent(".antigravity_tools/accounts")
        if let files = try? FileManager.default.contentsOfDirectory(at: agyToolsDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                guard let dict = readJSONDictionary(at: file) else { continue }
                let refreshToken = (dict["refresh_token"] as? String)
                    ?? ((dict["token"] as? [String: Any])?["refresh_token"] as? String)
                guard let refreshToken, !refreshToken.isEmpty else { continue }
                let email = (dict["email"] as? String) ?? extractEmailFromJWT(dict["id_token"] as? String)
                let normalizedEmail = email?.lowercased()
                if let normalizedEmail, seenEmails.contains(normalizedEmail) { continue }
                if let normalizedEmail { seenEmails.insert(normalizedEmail) }

                let id = "auto.antigravity.tools.\(shortHash(normalizedEmail ?? refreshToken))"
                secrets[id] = refreshToken
                accounts.append(ProviderAccountConfig(
                    id: id,
                    provider: .antigravity,
                    label: email ?? file.deletingPathExtension().lastPathComponent,
                    source: .autoDiscovered,
                    authKind: .oauthToken,
                    isEnabled: true,
                    externalAccountId: email,
                    credentialFilePath: file.path,
                    originDescription: "Antigravity Tools"
                ))
            }
        }

        // 若未找到 OAuth 文件但本地存在 ~/.gemini/antigravity* 目录，添加本机探测账号
        let hasAgy = accounts.contains { $0.provider == .antigravity }
        let agyCandidates = [
            home.appendingPathComponent(".gemini/antigravity"),
            home.appendingPathComponent(".gemini/antigravity-ide"),
            home.appendingPathComponent(".gemini/antigravity-cli"),
        ]
        if !hasAgy, let firstAgy = agyCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            accounts.append(ProviderAccountConfig(
                id: "auto.antigravity.local",
                provider: .antigravity,
                label: "Antigravity 本机服务",
                source: .autoDiscovered,
                authKind: .localOnly,
                isEnabled: true,
                originDescription: "Local RPC",
                customLogPath: firstAgy.path
            ))
        }
    }

    // MARK: - Helpers

    static func readJSONDictionary(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func shortHash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func maskIdentifier(_ raw: String) -> String {
        guard raw.count > 6 else { return raw }
        return "\(raw.prefix(3))...\(raw.suffix(3))"
    }

    static func decodeJWTPayload(_ jwt: String?) -> [String: Any]? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func extractEmailFromJWT(_ jwt: String?) -> String? {
        guard let payload = decodeJWTPayload(jwt) else { return nil }
        if let email = payload["email"] as? String, !email.isEmpty {
            return email
        }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    static func extractChatGPTAccountIdFromJWT(_ jwt: String?) -> String? {
        guard let payload = decodeJWTPayload(jwt),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let acct = auth["chatgpt_account_id"] as? String,
              !acct.isEmpty else {
            return nil
        }
        return acct
    }

    static func extractJWTExpiration(_ jwt: String?) -> Date? {
        guard let payload = decodeJWTPayload(jwt) else { return nil }
        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: Double(exp))
        }
        return nil
    }

    static func extractTOMLValue(key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.contains("=") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var val = parts[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val.removeFirst()
                val.removeLast()
            } else if val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2 {
                val.removeFirst()
                val.removeLast()
            }
            return val
        }
        return nil
    }
}
