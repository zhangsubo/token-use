import Foundation

/// Codex 本机系统账号一键切换服务（参考 `Javis603/token-monitor` 的安全切换协议）：
/// 1. 切换前若当前 `$CODEX_HOME/auth.json` 含有尚未托管的活跃 OAuth 登录态，自动快照备份至
///    `~/Library/Application Support/com.tokenuse.app/managed-codex-homes/<accountId>/auth.json`，确保原账号绝不丢失；
/// 2. 将目标账号的 OAuth `tokens`（含工作区 `account_id`）写入临时文件并设置 `0o600` 权限，再原子替换 `$CODEX_HOME/auth.json`。
enum CodexAccountSwitchService {
    enum SwitchError: LocalizedError {
        case unsupportedAccountType
        case missingSourceCredentials
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAccountType:
                return "仅支持切换 ChatGPT OAuth 类型的 Codex 账号"
            case .missingSourceCredentials:
                return "未能读取目标 Codex 账号的 OAuth 凭证"
            case .writeFailed(let detail):
                return "写入 ~/.codex/auth.json 失败: \(detail)"
            }
        }
    }

    static func codexHomeDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            let expanded = env.hasPrefix("~/")
                ? home.appendingPathComponent(String(env.dropFirst(2))).path
                : env
            return URL(fileURLWithPath: expanded)
        }
        return home.appendingPathComponent(".codex")
    }

    static func managedHomesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("com.tokenuse.app/managed-codex-homes", isDirectory: true)
    }

    /// 读取当前 `$CODEX_HOME/auth.json` 激活的 `(chatgptAccountId, email)`
    static func currentActiveIdentity(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (chatgptAccountId: String?, email: String?) {
        let authURL = codexHomeDirectory(home: home).appendingPathComponent("auth.json")
        guard let root = AccountDiscoveryService.readJSONDictionary(at: authURL),
              let tokens = root["tokens"] as? [String: Any] else {
            return (nil, nil)
        }
        let accessToken = tokens["access_token"] as? String
        let idToken = tokens["id_token"] as? String
        let acctId = (tokens["account_id"] as? String)
            ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(accessToken)
            ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(idToken)
        let email = AccountDiscoveryService.extractEmailFromJWT(idToken)
            ?? AccountDiscoveryService.extractEmailFromJWT(accessToken)
        return (acctId, email)
    }

    /// 一键将指定 Codex 账号切换为本机当前活跃 `$CODEX_HOME/auth.json` 账号
    static func switchActiveSystemAccount(to target: ProviderAccountConfig) async throws {
        guard target.provider == .codex, target.authKind == .oauthToken else {
            throw SwitchError.unsupportedAccountType
        }

        let codexHome = codexHomeDirectory()
        let liveAuthURL = codexHome.appendingPathComponent("auth.json")

        // 1. 先自动备份当前活跃的 ~/.codex/auth.json 至 managed-codex-homes（防止切走后丢失原账号）
        preserveCurrentLiveAuthIfNeeded(liveAuthURL: liveAuthURL)

        // 2. 提取并确保目标账号拥有可用的 access_token + refresh_token + id_token
        let data = try await ProviderQuotaService.shared.exportCodexAuthJSONData(for: target)

        // 3. 原子写入 0o600 的 auth.json
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let tmpURL = codexHome.appendingPathComponent(".auth.json.tokenuse-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            if FileManager.default.fileExists(atPath: liveAuthURL.path) {
                _ = try FileManager.default.replaceItemAt(liveAuthURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: liveAuthURL)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveAuthURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SwitchError.writeFailed(error.localizedDescription)
        }
    }

    private static func preserveCurrentLiveAuthIfNeeded(liveAuthURL: URL) {
        guard let root = AccountDiscoveryService.readJSONDictionary(at: liveAuthURL),
              let tokens = root["tokens"] as? [String: Any],
              let refresh = tokens["refresh_token"] as? String,
              !refresh.isEmpty else {
            return
        }
        let accessToken = tokens["access_token"] as? String
        let idToken = tokens["id_token"] as? String
        let acctId = (tokens["account_id"] as? String)
            ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(accessToken)
            ?? AccountDiscoveryService.extractChatGPTAccountIdFromJWT(idToken)
        let email = AccountDiscoveryService.extractEmailFromJWT(idToken)
            ?? AccountDiscoveryService.extractEmailFromJWT(accessToken)

        let seed = [email?.lowercased() ?? "", acctId?.lowercased() ?? refresh].joined(separator: "|")
        let folderName = "codex-\(AccountDiscoveryService.shortHash(seed))"
        let destDir = managedHomesDirectory().appendingPathComponent(folderName, isDirectory: true)
        let destAuth = destDir.appendingPathComponent("auth.json")

        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destAuth, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destAuth.path)
        }
    }
}
