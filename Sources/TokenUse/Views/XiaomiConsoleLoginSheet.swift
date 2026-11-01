import SwiftUI
import WebKit

/// 内置隔离会话的小米 MiMo 控制台登录页（使用 nonPersistent DataStore，支持连续登录多个不同小米账号而不串号！）
/// 登录成功后自动从 WKHTTPCookieStore 提取 `api-platform_serviceToken` 与 `userId`。
struct XiaomiConsoleLoginSheet: View {
    let accountLabel: String
    let onCookieCaptured: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = XiaomiWebAuthStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录小米 MiMo 控制台 — \(accountLabel)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("独立无痕会话：登录后将自动提取当前账号的 Token Plan 会话凭证并存入 Keychain")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()

                Button("手动提取当前会话") {
                    coordinator.checkCookiesNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.75))

            XiaomiWebViewContainer(store: coordinator)
                .frame(minWidth: 760, minHeight: 540)
        }
        .frame(width: 780, height: 600)
        .onDisappear {
            coordinator.stopPolling()
        }
        .onReceive(coordinator.$capturedCookie) { cookie in
            guard let cookie, !cookie.isEmpty else { return }
            coordinator.stopPolling()
            onCookieCaptured(cookie)
            dismiss()
        }
    }
}

@MainActor
final class XiaomiWebAuthStore: NSObject, ObservableObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    @Published var capturedCookie: String?

    let dataStore: WKWebsiteDataStore
    weak var webView: WKWebView?
    private var pollTimer: Timer?

    override init() {
        self.dataStore = WKWebsiteDataStore.nonPersistent()
        super.init()
        self.dataStore.httpCookieStore.add(self)
        self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCookiesNow()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.checkCookiesNow()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookiesNow()
    }

    func checkCookiesNow() {
        guard capturedCookie == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.capturedCookie == nil else { return }
            let cookies = await self.dataStore.httpCookieStore.allCookies()

            var serviceToken: String?
            var userId: String?
            var passToken: String?
            var platformPH: String?
            var platformSLH: String?

            for c in cookies where c.domain.contains("xiaomimimo.com") || c.domain.contains("xiaomi.com") {
                guard !c.value.isEmpty else { continue }
                switch c.name {
                case "api-platform_serviceToken":
                    serviceToken = c.value
                case "userId":
                    if userId == nil || c.domain.contains("xiaomimimo.com") {
                        userId = c.value
                    }
                case "passToken":
                    if c.domain.contains("xiaomi.com") {
                        passToken = c.value
                    }
                case "api-platform_ph":
                    platformPH = c.value
                case "api-platform_slh":
                    platformSLH = c.value
                default:
                    break
                }
            }

            // 小米控制台接口强制要求同时具备 api-platform_serviceToken 与 userId
            guard let serviceToken, let userId, !userId.isEmpty else { return }

            var segments: [String] = [
                "api-platform_serviceToken=\(serviceToken)",
                "userId=\(userId)",
            ]
            if let platformPH { segments.append("api-platform_ph=\(platformPH)") }
            if let platformSLH { segments.append("api-platform_slh=\(platformSLH)") }
            if let passToken { segments.append("passToken=\(passToken)") }

            guard self.capturedCookie == nil else { return }
            self.stopPolling()
            self.capturedCookie = segments.joined(separator: "; ")
        }
    }
}

private struct XiaomiWebViewContainer: NSViewRepresentable {
    @ObservedObject var store: XiaomiWebAuthStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = store
        store.webView = webView
        if let url = URL(string: "https://platform.xiaomimimo.com/console/plan-manage") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
