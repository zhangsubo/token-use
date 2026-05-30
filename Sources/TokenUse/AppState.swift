import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var stats: TokenStats?
    @Published var errorMessage: String?
    @Published var statusMessage: String = "Initializing..."
    @Published var isLoading: Bool = false

    private let service = TokscaleService.shared
    private let reportManager = ReportManager.shared
    private var timer: Timer?
    private var hasCheckedInstall = false

    private init() {}

    func start() async {
        guard !hasCheckedInstall else { return }
        hasCheckedInstall = true

        let isInstalled = await service.checkInstallation()
        if !isInstalled {
            statusMessage = "Tokscale not installed"
            showInstallAlert()
            return
        }

        await fetchData()
        startTimer()
    }

    func refresh() async {
        await fetchData()
    }

    private func showInstallAlert() {
        let alert = NSAlert()
        alert.messageText = "需要安装 Tokscale"
        alert.informativeText = "TokenUse 需要 tokscale CLI 工具来读取您的 token 使用数据。点击「安装」将自动执行 `npm install -g tokscale`。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                self.statusMessage = "Installing tokscale..."
                do {
                    try await self.service.installTokscale()
                    self.statusMessage = "Tokscale installed, fetching data..."
                    await self.fetchData()
                    self.startTimer()
                } catch {
                    self.errorMessage = "安装失败: \(error.localizedDescription)"
                }
            }
        } else {
            self.errorMessage = "Tokscale 未安装，应用无法运行。"
        }
    }

    private func fetchData() async {
        isLoading = true
        statusMessage = "Fetching data..."
        errorMessage = nil

        do {
            async let allTimeTask = service.fetchModels(todayOnly: false)
            async let todayTask = service.fetchModels(todayOnly: true)

            let allTime = try await allTimeTask
            let today = try await todayTask

            // Save report
            if let data = try? JSONEncoder().encode(allTime) {
                _ = try? await reportManager.saveReport(data)
            }

            let newStats = TokenStats(
                allTime: allTime,
                today: today,
                updatedAt: Date()
            )

            self.stats = newStats
        } catch {
            // Try to load from cache
            if let cached = await reportManager.loadLatestReport() {
                let today = try? await service.fetchModels(todayOnly: true)
                self.stats = TokenStats(
                    allTime: cached,
                    today: today ?? TokscaleReport(
                        groupBy: "client,model",
                        entries: [],
                        totalInput: 0,
                        totalOutput: 0,
                        totalCacheRead: 0,
                        totalCacheWrite: 0,
                        totalMessages: 0,
                        totalCost: 0
                    ),
                    updatedAt: Date()
                )
            } else {
                self.errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchData()
            }
        }
    }
}
