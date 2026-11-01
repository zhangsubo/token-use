import Foundation
import SQLite

/// 小米通行证 SSO 会话无感换票与 MiMo 桌面端会话发现：
/// - 支持从本机 `~/Library/Application Support/Xiaomi MiMo/Partitions/xiaomi-account/Cookies`
///   只读提取 `.account.xiaomi.com` 的明文 `passToken` + `userId`；
/// - 支持使用 `passToken` + `userId` 手动跟随 3xx 重定向（不落盘、自动将回调 `http://` 升级为 `https://`），
///   分别为小米开放平台控制台 (`platform.xiaomimimo.com`) 与 MiMo 桌面会员服务 (`mimo-server-cn.xiaomimimo.com`)
///   静默签发短期 `serviceToken`，避免会话过期后需要反复手动重登。
enum MimoSessionMinter {
    private static let maxExchangeHops = 8
    private static let loginDomains = ["xiaomi.com", "mi.com", "miui.com"]
    private static let cookieDomains = ["xiaomimimo.com", "xiaomi.com", "mi.com", "miui.com"]
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    struct DesktopAccountSeed: Sendable {
        let userId: String
        let passToken: String

        var accountCookieHeader: String {
            "passToken=\(passToken); userId=\(userId)"
        }
    }

    struct MintedSession: Sendable {
        let cookieHeader: String
        let userId: String?
        let region: String?
    }

    /// 从本机已安装的 Xiaomi MiMo 桌面端读取明文 `.account.xiaomi.com` 通行证 Cookie（无需访问 macOS 钥匙串）
    static func readLocalDesktopAccountSeed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DesktopAccountSeed? {
        let cookieDB = home.appendingPathComponent("Library/Application Support/Xiaomi MiMo/Partitions/xiaomi-account/Cookies")
        guard FileManager.default.fileExists(atPath: cookieDB.path) else { return nil }

        // 复制到临时快照目录再只读查询，避免与运行中的 Electron Chromium SQLite WAL 锁冲突
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenuse-mimo-cookie-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dstDB = tempDir.appendingPathComponent("Cookies")
        guard (try? FileManager.default.copyItem(at: cookieDB, to: dstDB)) != nil else {
            return queryCookiesSQLite(at: cookieDB.path)
        }
        for suffix in ["-wal", "-shm"] {
            let srcAux = URL(fileURLWithPath: cookieDB.path + suffix)
            if FileManager.default.fileExists(atPath: srcAux.path) {
                try? FileManager.default.copyItem(at: srcAux, to: URL(fileURLWithPath: dstDB.path + suffix))
            }
        }
        return queryCookiesSQLite(at: dstDB.path)
    }

    private static func queryCookiesSQLite(at path: String) -> DesktopAccountSeed? {
        guard let db = try? Connection(path, readonly: true) else { return nil }
        let sql = """
            SELECT name, value FROM cookies
            WHERE (host_key = '.account.xiaomi.com' OR host_key = 'account.xiaomi.com')
              AND name IN ('passToken', 'userId')
            """
        guard let stmt = try? db.prepare(sql) else { return nil }

        var passToken: String?
        var userId: String?
        for row in stmt {
            guard let name = row[0] as? String,
                  let val = row[1] as? String else { continue }
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if name == "passToken" { passToken = trimmed }
            if name == "userId" { userId = trimmed }
        }
        guard let passToken, let userId else { return nil }
        return DesktopAccountSeed(userId: userId, passToken: passToken)
    }

    /// 判断一段原始 Cookie 字符串中是否包含可用于 SSO 自动换票的 `passToken` 与 `userId`
    static func extractAccountSeed(from rawCookie: String) -> DesktopAccountSeed? {
        let pairs = parseCookiePairs(rawCookie)
        guard let passToken = pairs["passToken"], !passToken.isEmpty,
              let userId = pairs["userId"], !userId.isEmpty else {
            return nil
        }
        return DesktopAccountSeed(userId: userId, passToken: passToken)
    }

    /// 规范化小米控制台 Cookie（仅保留控制台允许的白名单字段）
    static func sanitizeConsoleCookie(_ rawCookie: String) -> (header: String, userId: String?, hasServiceToken: Bool) {
        var cleaned = rawCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("cookie:") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.contains("=") {
            return ("api-platform_serviceToken=\(cleaned)", nil, !cleaned.isEmpty)
        }
        let pairs = parseCookiePairs(cleaned)
        let allowlist = ["api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"]
        var out: [String] = []
        for key in allowlist {
            if let val = pairs[key], !val.isEmpty {
                out.append("\(key)=\(val)")
            }
        }
        let hasServiceToken = (pairs["api-platform_serviceToken"]?.isEmpty == false)
        if out.isEmpty {
            return (cleaned, pairs["userId"], hasServiceToken)
        }
        return (out.joined(separator: "; "), pairs["userId"], hasServiceToken)
    }

    static func parseCookiePairs(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !value.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    // MARK: - SSO Exchange

    /// 为小米开放平台控制台 (`https://platform.xiaomimimo.com/api/v1` + `/balance`) 签发会话
    static func mintConsoleSession(seed: DesktopAccountSeed) async -> MintedSession? {
        await mintServiceSession(
            baseURL: "https://platform.xiaomimimo.com/api/v1",
            entryPath: "/balance",
            seed: seed,
            requireUserIdInEnvelope: false
        )
    }

    /// 为 MiMo 桌面会员接口 (`https://mimo-server-cn.xiaomimimo.com/api` + `/user/xiaomi/me`) 签发会话
    static func mintMembershipSession(seed: DesktopAccountSeed) async -> MintedSession? {
        await mintServiceSession(
            baseURL: "https://mimo-server-cn.xiaomimimo.com/api",
            entryPath: "/user/xiaomi/me",
            seed: seed,
            requireUserIdInEnvelope: true
        )
    }

    private static func mintServiceSession(
        baseURL: String,
        entryPath: String,
        seed: DesktopAccountSeed,
        requireUserIdInEnvelope: Bool
    ) async -> MintedSession? {
        guard let entryURL = URL(string: baseURL + entryPath),
              let accountOrigin = URL(string: "https://account.xiaomi.com/") else {
            return nil
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        let session = URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var jar = ScopedCookieJar()
        jar.seed(accountCookieHeader: seed.accountCookieHeader, origin: accountOrigin)

        func isValidAnswer(status: Int, data: Data) -> (ok: Bool, userId: String?, region: String?) {
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["code"] as? Int) == 0 else {
                return (false, nil, nil)
            }
            if requireUserIdInEnvelope {
                guard let dataObj = json["data"] as? [String: Any] else { return (false, nil, nil) }
                let uidStr: String? = {
                    if let s = dataObj["userId"] as? String, !s.isEmpty { return s }
                    if let n = dataObj["userId"] as? NSNumber { return n.stringValue }
                    return nil
                }()
                guard let uidStr, !uidStr.isEmpty else { return (false, nil, nil) }
                let region = dataObj["region"] as? String
                return (true, uidStr, region)
            }
            return (true, seed.userId, nil)
        }

        guard var walked = await walk(url: entryURL, serviceHost: entryURL.host?.lowercased() ?? "", session: session, jar: &jar) else {
            return nil
        }

        if walked.status == 401 {
            guard let json = try? JSONSerialization.jsonObject(with: walked.data) as? [String: Any],
                  let loginURLStr = json["loginUrl"] as? String,
                  let loginURL = allowedLoginURL(loginURLStr, relativeTo: entryURL) else {
                return nil
            }
            guard let afterLogin = await walk(url: loginURL, serviceHost: entryURL.host?.lowercased() ?? "", session: session, jar: &jar) else {
                return nil
            }
            walked = afterLogin
            if !isValidAnswer(status: walked.status, data: walked.data).ok {
                guard let retried = await walk(url: entryURL, serviceHost: entryURL.host?.lowercased() ?? "", session: session, jar: &jar) else {
                    return nil
                }
                walked = retried
            }
        }

        guard walked.finalURL.host?.lowercased() == entryURL.host?.lowercased() else {
            return nil
        }
        let check = isValidAnswer(status: walked.status, data: walked.data)
        guard check.ok else { return nil }

        let header = jar.cookieHeader(for: entryURL)
        guard !header.isEmpty else { return nil }
        return MintedSession(cookieHeader: header, userId: check.userId ?? seed.userId, region: check.region)
    }

    private struct WalkResult {
        let status: Int
        let data: Data
        let finalURL: URL
    }

    private static func walk(
        url: URL,
        serviceHost: String,
        session: URLSession,
        jar: inout ScopedCookieJar
    ) async -> WalkResult? {
        var current = url
        for _ in 0..<maxExchangeHops {
            var req = URLRequest(url: current)
            req.httpMethod = "GET"
            let cookie = jar.cookieHeader(for: current)
            if !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            req.setValue("zh-CN,zh;q=0.9,en-US;q=0.8", forHTTPHeaderField: "Accept-Language")
            req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                return nil
            }

            jar.absorb(response: http, for: current)

            let status = http.statusCode
            if (300..<400).contains(status) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = allowedExchangeURL(location, relativeTo: current, serviceHost: serviceHost) else {
                    return nil
                }
                current = next
                continue
            }
            return WalkResult(status: status, data: data, finalURL: current)
        }
        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        let h = host.lowercased()
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return h == d || h.hasSuffix(".\(d)")
    }

    private static func allowedLoginURL(_ raw: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(),
              loginDomains.contains(where: { hostMatches(host, domain: $0) }) else {
            return nil
        }
        return url
    }

    private static func allowedExchangeURL(_ raw: String, relativeTo base: URL, serviceHost: String) -> URL? {
        guard var comps = URLComponents(url: URL(string: raw, relativeTo: base)?.absoluteURL ?? base, resolvingAgainstBaseURL: true),
              comps.user == nil, comps.password == nil, comps.port == nil,
              let host = comps.host?.lowercased() else {
            return nil
        }
        if host == serviceHost {
            if comps.scheme?.lowercased() == "http" {
                comps.scheme = "https"
            }
            guard comps.scheme?.lowercased() == "https" else { return nil }
            return comps.url
        }
        guard comps.scheme?.lowercased() == "https",
              loginDomains.contains(where: { hostMatches(host, domain: $0) }) else {
            return nil
        }
        return comps.url
    }

    // MARK: - ScopedCookieJar & Redirect Blocker

    private struct StoredCookie {
        let name: String
        let value: String
        let domain: String
        let path: String
        let hostOnly: Bool
        let secure: Bool
        let expiresAt: Date?
    }

    private struct ScopedCookieJar {
        private var items: [StoredCookie] = []

        mutating func seed(accountCookieHeader: String, origin: URL) {
            guard let host = origin.host?.lowercased() else { return }
            for (name, value) in parseCookiePairs(accountCookieHeader) {
                upsert(StoredCookie(
                    name: name,
                    value: value,
                    domain: host,
                    path: "/",
                    hostOnly: true,
                    secure: true,
                    expiresAt: nil
                ))
            }
        }

        mutating func absorb(response: HTTPURLResponse, for url: URL) {
            var headerStrings: [String: String] = [:]
            for (k, v) in response.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    headerStrings[ks] = vs
                }
            }
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerStrings, for: url)
            guard let reqHost = url.host?.lowercased() else { return }

            for c in parsed {
                let rawDomain = c.domain.lowercased()
                let cleanDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard hostMatches(reqHost, domain: cleanDomain),
                      cookieDomains.contains(where: { hostMatches(cleanDomain, domain: $0) }) else {
                    continue
                }
                let hostOnly = !rawDomain.hasPrefix(".") && cleanDomain == reqHost
                upsert(StoredCookie(
                    name: c.name,
                    value: c.value,
                    domain: cleanDomain,
                    path: c.path.isEmpty ? "/" : c.path,
                    hostOnly: hostOnly,
                    secure: c.isSecure,
                    expiresAt: c.expiresDate
                ))
            }
        }

        private mutating func upsert(_ cookie: StoredCookie) {
            let now = Date()
            items.removeAll {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
            }
            if let exp = cookie.expiresAt, exp <= now {
                return
            }
            items.append(cookie)
        }

        func cookieHeader(for url: URL) -> String {
            guard let host = url.host?.lowercased() else { return "" }
            let now = Date()
            let path = url.path.isEmpty ? "/" : url.path
            let isHTTPS = url.scheme?.lowercased() == "https"

            let matched = items
                .filter { c in
                    if let exp = c.expiresAt, exp <= now { return false }
                    if c.secure && !isHTTPS { return false }
                    if c.hostOnly {
                        guard c.domain == host else { return false }
                    } else {
                        guard hostMatches(host, domain: c.domain) else { return false }
                    }
                    if path == c.path { return true }
                    if path.hasPrefix(c.path) {
                        return c.path.hasSuffix("/") || path.dropFirst(c.path.count).first == "/"
                    }
                    return false
                }
                .sorted { $0.path.count > $1.path.count }

            return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
}
