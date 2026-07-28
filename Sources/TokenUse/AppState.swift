import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var stats: TokenStats?
    @Published var errorMessage: String?
    @Published var statusMessage: String = "Initializing..."
    @Published var isLoading: Bool = false

    private let nativeUsageService = NativeUsageService.shared
    private let reportManager = ReportManager.shared
    private var timer: Timer?
    private var hasCheckedInstall = false

    private init() {}

    func start() async {
        guard !hasCheckedInstall else { return }
        hasCheckedInstall = true

        await fetchData()
        startTimer()
    }

    func refresh() async {
        await fetchData()
    }

    private func fetchData() async {
        isLoading = true
        statusMessage = "Fetching data..."
        errorMessage = nil

        // 使用原生服务同时获取全量和今日数据
        async let allTimeResult: Result<TokscaleReport, Error> = {
            do { return .success(try await self.nativeUsageService.fetchAllTime()) }
            catch { return .failure(error) }
        }()

        async let todayResult: Result<TokscaleReport, Error> = {
            do { return .success(try await self.nativeUsageService.fetchToday()) }
            catch { return .failure(error) }
        }()

        let allTimeOutcome = await allTimeResult
        let todayOutcome = await todayResult

        let allTime: TokscaleReport? = {
            if case .success(let r) = allTimeOutcome { return r } else { return nil }
        }()
        let today: TokscaleReport? = {
            if case .success(let r) = todayOutcome { return r } else { return nil }
        }()

        // 保存全量报告作为缓存
        if let allTime {
            if let data = try? JSONEncoder().encode(allTime) {
                _ = try? await reportManager.saveReport(data)
            }
        }

        // 使用缓存的全量数据作为兜底
        let finalAllTime: TokscaleReport?
        if let allTime {
            finalAllTime = allTime
        } else {
            finalAllTime = await reportManager.loadLatestReport()
        }

        if let finalAllTime {
            self.stats = TokenStats(
                allTime: finalAllTime,
                today: today ?? TokscaleReport(
                    groupBy: "client,model",
                    entries: [],
                    totalInput: 0,
                    totalOutput: 0,
                    totalCacheRead: 0,
                    totalCacheWrite: 0,
                    totalReasoning: 0,
                    totalMessages: 0,
                    totalCost: 0
                ),
                updatedAt: Date()
            )
            statusMessage = "Updated at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
        } else {
            self.errorMessage = "无法获取数据，请检查本地日志是否存在。"
            statusMessage = "No data available"
        }

        // 如果今日数据获取失败，告知用户
        if finalAllTime != nil, today == nil, case .failure(let err) = todayOutcome {
            self.errorMessage = "今日数据获取失败：\(err.localizedDescription)"
        }

        isLoading = false
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = SettingsManager.shared.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchData()
            }
        }
    }

    func restartTimer() {
        startTimer()
    }
}
