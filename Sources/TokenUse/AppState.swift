import SwiftUI
import Combine

// MARK: - AppState
/// 全局应用状态管理
/// 职责：
/// - 智能缓存策略（1小时有效期）：缓存有效时立即加载，后台更新今日数据
/// - 定时刷新（默认 30 分钟，可在设置中调整）
/// - 协调 NativeUsageService 和 ReportManager 的数据流

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

        DebugLogger.log("🚀 [AppState] start() 被调用")
        await fetchData()
        startTimer()
        DebugLogger.log("🚀 [AppState] start() 完成")
    }

    func refresh() async {
        await fetchData()
    }

    private func fetchData() async {
        isLoading = true
        statusMessage = "Fetching data..."
        errorMessage = nil

        DebugLogger.log("📊 [AppState] 开始获取数据...")

        // 智能缓存策略：如果缓存有效，立即加载并后台更新
        let isCacheValid = await reportManager.isCacheValid()
        if isCacheValid, let cachedReport = await reportManager.loadLatestReport() {
            DebugLogger.log("✅ [AppState] 缓存有效，立即加载缓存数据")
            // 立即显示缓存数据
            self.stats = TokenStats(
                allTime: cachedReport,
                today: TokscaleReport(
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
            statusMessage = "Loaded from cache"
            isLoading = false

            // 后台异步更新今日数据
            DebugLogger.log("📊 [AppState] 后台更新今日数据...")
            Task {
                await updateTodayData()
            }
            return
        }

        DebugLogger.log("📊 [AppState] 缓存无效或不存在，执行完整扫描...")

        // 使用原生服务同时获取全量和今日数据
        async let allTimeResult: Result<TokscaleReport, Error> = {
            DebugLogger.log("📊 [AppState] 开始获取全量数据...")
            do {
                let report = try await self.nativeUsageService.fetchAllTime()
                DebugLogger.log("📊 [AppState] 全量数据获取成功: \(report.entries.count) entries")
                return .success(report)
            }
            catch {
                DebugLogger.log("❌ [AppState] 全量数据获取失败: \(error)")
                return .failure(error)
            }
        }()

        async let todayResult: Result<TokscaleReport, Error> = {
            DebugLogger.log("📊 [AppState] 开始获取今日数据...")
            do {
                let report = try await self.nativeUsageService.fetchToday()
                DebugLogger.log("📊 [AppState] 今日数据获取成功: \(report.entries.count) entries")
                return .success(report)
            }
            catch {
                DebugLogger.log("❌ [AppState] 今日数据获取失败: \(error)")
                return .failure(error)
            }
        }()

        DebugLogger.log("📊 [AppState] 等待数据获取完成...")
        let allTimeOutcome = await allTimeResult
        let todayOutcome = await todayResult
        DebugLogger.log("📊 [AppState] 数据获取完成")

        let allTime: TokscaleReport? = {
            if case .success(let r) = allTimeOutcome { return r } else { return nil }
        }()
        let today: TokscaleReport? = {
            if case .success(let r) = todayOutcome { return r } else { return nil }
        }()

        DebugLogger.log("📊 [AppState] allTime: \(allTime != nil ? "存在" : "nil"), today: \(today != nil ? "存在" : "nil")")

        // 保存全量报告作为缓存
        if let allTime {
            DebugLogger.log("📊 [AppState] 保存全量报告到缓存...")
            if let data = try? JSONEncoder().encode(allTime) {
                _ = try? await reportManager.saveReport(data)
                DebugLogger.log("📊 [AppState] 缓存保存成功")
            }
        }

        // 使用缓存的全量数据作为兜底
        DebugLogger.log("📊 [AppState] 检查是否需要从缓存加载...")
        let finalAllTime: TokscaleReport?
        if let allTime {
            finalAllTime = allTime
            DebugLogger.log("📊 [AppState] 使用实时全量数据")
        } else {
            DebugLogger.log("📊 [AppState] 从缓存加载全量数据...")
            finalAllTime = await reportManager.loadLatestReport()
            DebugLogger.log("📊 [AppState] 缓存加载结果: \(finalAllTime != nil ? "成功" : "失败")")
        }

        if let finalAllTime {
            DebugLogger.log("📊 [AppState] 构建 TokenStats...")
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
            DebugLogger.log("✅ [AppState] 数据更新成功")
        } else {
            DebugLogger.log("❌ [AppState] 无可用数据")
            self.errorMessage = "无法获取数据，请检查本地日志是否存在。"
            statusMessage = "No data available"
        }

        // 如果今日数据获取失败，告知用户
        if finalAllTime != nil, today == nil, case .failure(let err) = todayOutcome {
            DebugLogger.log("⚠️ [AppState] 今日数据失败但全量数据成功: \(err.localizedDescription)")
            self.errorMessage = "今日数据获取失败：\(err.localizedDescription)"
        }

        isLoading = false
        DebugLogger.log("📊 [AppState] fetchData 完成")
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

    /// 后台更新今日数据（当使用缓存时调用）
    private func updateTodayData() async {
        do {
            let todayReport = try await nativeUsageService.fetchToday()
            DebugLogger.log("✅ [AppState] 今日数据后台更新成功: \(todayReport.entries.count) entries")

            // 更新 stats 中的今日数据
            if let currentStats = stats {
                self.stats = TokenStats(
                    allTime: currentStats.allTime,
                    today: todayReport,
                    updatedAt: Date()
                )
                statusMessage = "Updated at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
            }
        } catch {
            DebugLogger.log("❌ [AppState] 今日数据后台更新失败: \(error)")
        }
    }
}
