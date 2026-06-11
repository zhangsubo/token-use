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
    private let nativeUsageService = NativeUsageService.shared
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

        // Fetch allTime and today independently — one failure must not cancel the other.
        // 用 Result 包裹是为了同时拿到成功值与失败原因（不能只 try?，否则失败信息被吞）
        async let allTimeResult: Result<TokscaleReport, Error> = {
            do { return .success(try await self.service.fetchModels(todayOnly: false)) }
            catch { return .failure(error) }
        }()

        let todayDate = Self.todayDateString()

        // Today 拉取顺序：tokscale --today -> tokscale --since -> 原生本地日志聚合。
        // 非零结果优先；如果三步都成功但均为 0，则接受最后一个 0 结果。
        let todayResult: Result<TokscaleReport, Error> = await {
            var firstError: Error?
            var zeroReport: TokscaleReport?

            do {
                let report = try await self.service.fetchModels(todayOnly: true)
                if report.totalTokens > 0 {
                    return .success(report)
                }
                zeroReport = report
            } catch {
                firstError = error
            }

            do {
                let report = try await self.service.fetchModels(todayOnly: false, since: todayDate)
                if report.totalTokens > 0 {
                    return .success(report)
                }
                zeroReport = report
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }

            do {
                let report = try await self.nativeUsageService.fetchToday()
                if report.totalTokens > 0 {
                    return .success(report)
                }
                zeroReport = report
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }

            if let zeroReport {
                return .success(zeroReport)
            }
            return .failure(firstError ?? NativeUsageError.noSupportedLogs)
        }()

        let allTimeOutcome = await allTimeResult
        let allTime: TokscaleReport? = {
            if case .success(let r) = allTimeOutcome { return r } else { return nil }
        }()
        let today: TokscaleReport? = {
            if case .success(let r) = todayResult { return r } else { return nil }
        }()

        if let allTime {
            // Save report
            if let data = try? JSONEncoder().encode(allTime) {
                _ = try? await reportManager.saveReport(data)
            }
        }

        // Use cached allTime if live fetch failed
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
        } else {
            self.errorMessage = "无法获取数据，请检查 tokscale 是否已安装。"
        }

        // 关键修复：allTime 拉取成功但 today 失败时，必须把根因告诉用户
        // （原先 today 静默为零值，UI 显示 0 但用户不知道为什么）
        if finalAllTime != nil, today == nil, case .failure(let err) = todayResult {
            self.errorMessage = "今日数据获取失败：\(err.localizedDescription)"
        }

        isLoading = false
    }

    /// 用户本地"今日"日期，YYYY-MM-DD。
    /// Why: --since 需要本地日历日期（不是 UTC），否则跨时区用户会在凌晨看到"昨日"窗口
    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
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
