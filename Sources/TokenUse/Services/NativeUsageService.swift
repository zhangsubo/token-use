import Foundation
import SQLite

enum NativeUsageError: Error, LocalizedError {
    case noSupportedLogs

    var errorDescription: String? {
        switch self {
        case .noSupportedLogs:
            return "未找到 Codex、Claude、Kimi 或 Mimo 的本地使用日志"
        }
    }
}

actor NativeUsageService {
    static let shared = NativeUsageService()

    private let fileManager = FileManager.default

    func fetchToday() async throws -> TokscaleReport {
        DebugLogger.log("📅 [NativeUsage] fetchToday() 开始")
        let interval = Self.localDayInterval(for: Date())
        let report = try await fetch(interval: interval)
        DebugLogger.log("📅 [NativeUsage] fetchToday() 完成: \(report.entries.count) entries")
        return report
    }

    func fetchAllTime() async throws -> TokscaleReport {
        DebugLogger.log("📅 [NativeUsage] fetchAllTime() 开始")
        // OpenCode 数据库可能很大，全量查询会超时
        // 限制为最近 90 天避免性能问题
        let start = Date().addingTimeInterval(-86400 * 90)
        let interval = DateInterval(start: start, end: Date())
        let report = try await fetch(interval: interval)
        DebugLogger.log("📅 [NativeUsage] fetchAllTime() 完成: \(report.entries.count) entries")
        return report
    }

    private func fetch(interval: DateInterval) async throws -> TokscaleReport {
        DebugLogger.log("📅 [NativeUsage] fetch() 开始扫描...")
        var accumulator = UsageAccumulator()

        DebugLogger.log("📅 [NativeUsage] 扫描 Codex...")
        scanCodex(interval: interval, into: &accumulator)
        DebugLogger.log("📅 [NativeUsage] 扫描 Claude...")
        scanClaude(interval: interval, into: &accumulator)
        DebugLogger.log("📅 [NativeUsage] 扫描 Kimi...")
        scanKimi(interval: interval, into: &accumulator)
        DebugLogger.log("📅 [NativeUsage] 扫描 Mimo...")
        scanMimo(interval: interval, into: &accumulator)
        DebugLogger.log("📅 [NativeUsage] 扫描 OpenCode...")
        scanOpenCode(interval: interval, into: &accumulator)

        if accumulator.isEmpty {
            DebugLogger.log("❌ [NativeUsage] 未找到任何数据")
            throw NativeUsageError.noSupportedLogs
        }
        DebugLogger.log("✅ [NativeUsage] 扫描完成，生成报告")
        return accumulator.report()
    }

    private func scanCodex(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".codex/sessions")
        let components = Calendar.current.dateComponents([.year, .month, .day], from: interval.start)
        guard let year = components.year, let month = components.month, let day = components.day else { return }

        let dayRoot = root
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))

        for file in jsonlFiles(under: dayRoot) {
            for object in jsonObjects(in: file) {
                guard string(object["type"]) == "event_msg",
                      let timestamp = date(from: object["timestamp"]),
                      interval.contains(timestamp),
                      let payload = object["payload"] as? [String: Any],
                      string(payload["type"]) == "token_count",
                      let info = payload["info"] as? [String: Any] else {
                    continue
                }

                let usage = (info["last_token_usage"] as? [String: Any])
                    ?? (info["total_token_usage"] as? [String: Any])
                guard let usage else { continue }

                let input = int(usage["input_tokens"])
                let output = int(usage["output_tokens"])
                let cacheRead = int(usage["cached_input_tokens"])
                let reasoning = int(usage["reasoning_output_tokens"])

                accumulator.add(
                    client: "codex",
                    provider: "openai",
                    model: "gpt-5.5",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: 0,
                    reasoning: reasoning,
                    messageCount: 1,
                    cost: PriceResolver.estimate(model: "gpt-5.5", provider: "openai", input: input, output: output, cacheRead: cacheRead, cacheWrite: 0, reasoning: reasoning)
                )
            }
        }
    }

    private func scanClaude(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".claude/projects")
        for file in jsonlFiles(under: root) {
            guard (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map({ $0 >= interval.start.addingTimeInterval(-86_400) }) == true else {
                continue
            }

            for object in jsonObjects(in: file) {
                guard string(object["type"]) == "assistant",
                      let timestamp = date(from: object["timestamp"]),
                      interval.contains(timestamp),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                let model = string(message["model"]) ?? "unknown"
                let input = int(usage["input_tokens"])
                let output = int(usage["output_tokens"])
                let cacheRead = int(usage["cache_read_input_tokens"])
                let cacheWrite = int(usage["cache_creation_input_tokens"])
                    + int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
                    + int((usage["cache_creation"] as? [String: Any])?["ephemeral_5m_input_tokens"])

                accumulator.add(
                    client: "claude",
                    provider: "anthropic",
                    model: model,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    messageCount: input + output + cacheRead + cacheWrite > 0 ? 1 : 0,
                    cost: PriceResolver.estimate(model: model, provider: "anthropic", input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: 0)
                )
            }
        }
    }

    private func scanKimi(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".kimi/sessions")
        for file in files(under: root, named: "wire.jsonl") {
            for object in jsonObjects(in: file) {
                guard let timestamp = unixDate(object["timestamp"]),
                      interval.contains(timestamp),
                      let message = object["message"] as? [String: Any],
                      string(message["type"]) == "StatusUpdate",
                      let payload = message["payload"] as? [String: Any],
                      let usage = payload["token_usage"] as? [String: Any] else {
                    continue
                }

                let input = int(usage["input_other"])
                let output = int(usage["output"])
                let cacheRead = int(usage["input_cache_read"])
                let cacheWrite = int(usage["input_cache_creation"])

                accumulator.add(
                    client: "kimi",
                    provider: "moonshot",
                    model: "kimi-for-coding",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    messageCount: input + output + cacheRead + cacheWrite > 0 ? 1 : 0,
                    cost: PriceResolver.estimate(model: "kimi-for-coding", provider: "moonshot", input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: 0)
                )
            }
        }
    }

    private func scanMimo(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".mimo/sessions")
        for file in jsonlFiles(under: root) {
            guard (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map({ $0 >= interval.start.addingTimeInterval(-86_400) }) == true else {
                continue
            }

            for object in jsonObjects(in: file) {
                guard string(object["type"]) == "assistant",
                      let timestamp = date(from: object["timestamp"]),
                      interval.contains(timestamp),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                let model = string(message["model"]) ?? "unknown"
                let input = int(usage["input_tokens"])
                let output = int(usage["output_tokens"])
                let cacheRead = int(usage["cache_read_input_tokens"])
                let cacheWrite = int(usage["cache_creation_input_tokens"])

                accumulator.add(
                    client: "mimocode",
                    provider: "xiaomi",
                    model: model,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    messageCount: input + output + cacheRead + cacheWrite > 0 ? 1 : 0,
                    cost: PriceResolver.estimate(model: model, provider: "xiaomi", input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: 0)
                )
            }
        }
    }

    private func scanOpenCode(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".local/share/opencode")
        let databases = sqliteFiles(under: root)
        DebugLogger.log("📅 [NativeUsage] 找到 \(databases.count) 个 OpenCode 数据库")
        for database in databases {
            DebugLogger.log("📅 [NativeUsage] 查询数据库: \(database.lastPathComponent)")
            let rows = openCodeRowsViaSQLite(database: database, interval: interval)
            DebugLogger.log("📅 [NativeUsage] 查询完成，返回 \(rows.count) 行")
            for row in rows {
                accumulator.add(
                    client: "opencode",
                    provider: row.provider,
                    model: row.model,
                    input: row.input,
                    output: row.output,
                    cacheRead: row.cacheRead,
                    cacheWrite: row.cacheWrite,
                    reasoning: row.reasoning,
                    messageCount: row.messageCount,
                    cost: row.cost
                )
            }
        }
    }

    private func openCodeRowsViaSQLite(database: URL, interval: DateInterval) -> [OpenCodeRow] {
        guard fileManager.fileExists(atPath: database.path) else {
            DebugLogger.log("⚠️ [NativeUsage] 数据库不存在: \(database.path)")
            return []
        }

        do {
            let db = try Connection(database.path, readonly: true)

            let sessions = Table("session")
            let model = Expression<String?>("model")
            let tokensInput = Expression<Int>("tokens_input")
            let tokensOutput = Expression<Int>("tokens_output")
            let tokensCacheRead = Expression<Int>("tokens_cache_read")
            let tokensCacheWrite = Expression<Int>("tokens_cache_write")
            let tokensReasoning = Expression<Int>("tokens_reasoning")
            let cost = Expression<Double>("cost")
            let timeUpdated = Expression<Int>("time_updated")

            let startMillis = Int(interval.start.timeIntervalSince1970 * 1000)
            let endMillis = Int(interval.end.timeIntervalSince1970 * 1000)

            let query = sessions
                .select(model, tokensInput, tokensOutput, tokensCacheRead, tokensCacheWrite, tokensReasoning, cost)
                .filter(timeUpdated >= startMillis && timeUpdated < endMillis)

            var results: [OpenCodeRow] = []
            for row in try db.prepare(query) {
                let modelStr = try row.get(model)
                let modelInfo = decodeJSONObject(modelStr)
                let modelId = string(modelInfo?["id"]) ?? modelStr ?? "unknown"
                let providerId = string(modelInfo?["providerID"]) ?? "opencode"

                results.append(OpenCodeRow(
                    provider: providerId,
                    model: modelId,
                    input: try row.get(tokensInput),
                    output: try row.get(tokensOutput),
                    cacheRead: try row.get(tokensCacheRead),
                    cacheWrite: try row.get(tokensCacheWrite),
                    reasoning: try row.get(tokensReasoning),
                    messageCount: 1,
                    cost: try row.get(cost)
                ))
            }

            DebugLogger.log("✅ [NativeUsage] SQLite 直接查询成功，返回 \(results.count) 行")
            return results
        } catch {
            DebugLogger.log("❌ [NativeUsage] SQLite 查询失败: \(error)")
            return []
        }
    }


    private var homeDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        files(under: root) { $0.pathExtension == "jsonl" }
    }

    private func sqliteFiles(under root: URL) -> [URL] {
        files(under: root) {
            let name = $0.lastPathComponent
            return name == "opencode.db" || (name.hasPrefix("opencode-") && name.hasSuffix(".db"))
        }
    }

    private func files(under root: URL, named name: String) -> [URL] {
        files(under: root) { $0.lastPathComponent == name }
    }

    private func files(under root: URL, where shouldInclude: (URL) -> Bool = { _ in true }) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  shouldInclude(url) else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private func jsonObjects(in file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var objects: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            objects.append(object)
        }
        return objects
    }

    private static func localDayInterval(for date: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}

private struct OpenCodeRow {
    let provider: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int
    let messageCount: Int
    let cost: Double
}

private struct UsageKey: Hashable {
    let client: String
    let provider: String
    let model: String
}

private struct UsageBucket {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0
    var messageCount = 0
    var cost = 0.0
}

private struct UsageAccumulator {
    private var buckets: [UsageKey: UsageBucket] = [:]

    var isEmpty: Bool {
        buckets.values.allSatisfy {
            $0.input + $0.output + $0.cacheRead + $0.cacheWrite + $0.reasoning == 0
        }
    }

    mutating func add(
        client: String,
        provider: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int,
        messageCount: Int,
        cost: Double
    ) {
        guard input + output + cacheRead + cacheWrite + reasoning > 0 else { return }
        let key = UsageKey(client: client, provider: provider, model: model)
        var bucket = buckets[key] ?? UsageBucket()
        bucket.input += input
        bucket.output += output
        bucket.cacheRead += cacheRead
        bucket.cacheWrite += cacheWrite
        bucket.reasoning += reasoning
        bucket.messageCount += messageCount
        bucket.cost += cost
        buckets[key] = bucket
    }

    func report() -> TokscaleReport {
        let entries = buckets.map { key, bucket in
            TokscaleEntry(
                client: key.client,
                mergedClients: nil,
                model: key.model,
                provider: key.provider,
                input: bucket.input,
                output: bucket.output,
                cacheRead: bucket.cacheRead,
                cacheWrite: bucket.cacheWrite,
                reasoning: bucket.reasoning,
                messageCount: bucket.messageCount,
                cost: bucket.cost
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return TokscaleReport(
            groupBy: "client,model",
            entries: entries,
            totalInput: entries.reduce(0) { $0 + $1.input },
            totalOutput: entries.reduce(0) { $0 + $1.output },
            totalCacheRead: entries.reduce(0) { $0 + $1.cacheRead },
            totalCacheWrite: entries.reduce(0) { $0 + $1.cacheWrite },
            totalReasoning: entries.reduce(0) { $0 + $1.reasoning },
            totalMessages: entries.reduce(0) { $0 + $1.messageCount },
            totalCost: entries.reduce(0) { $0 + $1.cost }
        )
    }
}

private enum PriceResolver {
    struct Price {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static func estimate(
        model: String,
        provider: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int
    ) -> Double {
        let price = price(for: model, provider: provider)
        let outputLike = output + reasoning
        return (
            Double(input) * price.input
            + Double(outputLike) * price.output
            + Double(cacheRead) * price.cacheRead
            + Double(cacheWrite) * price.cacheWrite
        ) / 1_000_000
    }

    private static func price(for model: String, provider: String) -> Price {
        let normalized = model.lowercased()
        let normalizedProvider = provider.lowercased()

        // OpenAI GPT 系列
        if normalized.contains("gpt-5.5") || normalized.contains("gpt5.5") {
            return Price(input: 1.5, output: 12.0, cacheRead: 0.15, cacheWrite: 1.5)
        }
        if normalized.contains("gpt-5.4") || normalized.contains("gpt5.4") {
            return Price(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if normalized.contains("gpt-5") || normalized.contains("gpt5") {
            return Price(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if normalized.contains("gpt-4o") {
            return Price(input: 5.0, output: 15.0, cacheRead: 2.5, cacheWrite: 5.0)
        }
        if normalized.contains("gpt-4") {
            return Price(input: 30.0, output: 60.0, cacheRead: 0, cacheWrite: 0)
        }
        if normalized.contains("gpt-3.5") {
            return Price(input: 0.5, output: 1.5, cacheRead: 0, cacheWrite: 0)
        }

        // Anthropic Claude 系列
        if normalized.contains("claude-opus-5") || normalized.contains("opus-5") {
            return Price(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if normalized.contains("claude-opus-4") || normalized.contains("opus-4") {
            return Price(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if normalized.contains("claude-opus") || normalized.contains("opus") {
            return Price(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if normalized.contains("claude-sonnet-4") || normalized.contains("sonnet-4") {
            return Price(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if normalized.contains("claude-sonnet") || normalized.contains("sonnet") {
            return Price(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if normalized.contains("claude-haiku") || normalized.contains("haiku") {
            return Price(input: 0.8, output: 4.0, cacheRead: 0.08, cacheWrite: 1.0)
        }
        if normalized.contains("claude") {
            return Price(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }

        // Google Gemini 系列
        if normalized.contains("gemini-2.0") {
            return Price(input: 1.25, output: 5.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if normalized.contains("gemini-1.5-pro") {
            return Price(input: 1.25, output: 5.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if normalized.contains("gemini-1.5-flash") {
            return Price(input: 0.075, output: 0.3, cacheRead: 0.01875, cacheWrite: 0.075)
        }
        if normalized.contains("gemini") {
            return Price(input: 1.25, output: 5.0, cacheRead: 0.125, cacheWrite: 1.25)
        }

        // Moonshot Kimi 系列
        if normalized.contains("kimi-k2.7") || normalized.contains("k2.7") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }
        if normalized.contains("kimi-k2.6") || normalized.contains("k2.6") || normalized.contains("k2p6") {
            return Price(input: 0.95, output: 4.0, cacheRead: 0.16, cacheWrite: 0.95)
        }
        if normalized.contains("kimi-k2.5") || normalized.contains("k2.5") || normalized.contains("k2p5") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }
        if normalized.contains("kimi") || normalizedProvider.contains("moonshot") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }

        // Zhipu GLM 系列
        if normalized.contains("glm-5.2") || normalized.contains("glm5.2") {
            return Price(input: 1.5, output: 6.0, cacheRead: 0.3, cacheWrite: 1.5)
        }
        if normalized.contains("glm-5.1") || normalized.contains("glm5.1") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }
        if normalized.contains("glm-5") || normalized.contains("glm5") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }
        if normalized.contains("glm-4.7") || normalized.contains("glm4.7") || normalized.contains("big-pickle") {
            return Price(input: 0.5, output: 2.0, cacheRead: 0.1, cacheWrite: 0.5)
        }
        if normalized.contains("glm") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }

        // Xiaomi MiMo 系列
        if normalized.contains("mimo-v2.5-pro") {
            return Price(input: 0.8, output: 3.0, cacheRead: 0.16, cacheWrite: 0.8)
        }
        if normalized.contains("mimo-v2.5") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }
        if normalized.contains("mimo") || normalizedProvider.contains("xiaomi") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }

        // DeepSeek 系列
        if normalized.contains("deepseek-v4") {
            return Price(input: 0.27, output: 1.1, cacheRead: 0.07, cacheWrite: 0.27)
        }
        if normalized.contains("deepseek-v3") {
            return Price(input: 0.27, output: 1.1, cacheRead: 0.07, cacheWrite: 0.27)
        }
        if normalized.contains("deepseek") {
            return Price(input: 0.27, output: 1.1, cacheRead: 0.07, cacheWrite: 0.27)
        }

        // Alibaba Qwen 系列
        if normalized.contains("qwen-turbo") || normalized.contains("qwen3.5-plus") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.12, cacheWrite: 0.6)
        }
        if normalized.contains("qwen-plus") || normalized.contains("qwen3.5-pro") {
            return Price(input: 2.0, output: 8.0, cacheRead: 0.4, cacheWrite: 2.0)
        }
        if normalized.contains("qwen") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.12, cacheWrite: 0.6)
        }

        // MiniMax 系列
        if normalized.contains("minimax-m3") {
            return Price(input: 0.5, output: 2.0, cacheRead: 0.1, cacheWrite: 0.5)
        }
        if normalized.contains("minimax-m2.7") {
            return Price(input: 0.4, output: 1.6, cacheRead: 0.08, cacheWrite: 0.4)
        }
        if normalized.contains("minimax") {
            return Price(input: 0.5, output: 2.0, cacheRead: 0.1, cacheWrite: 0.5)
        }

        // xAI Grok 系列
        if normalized.contains("grok-code") {
            return Price(input: 0.2, output: 1.5, cacheRead: 0, cacheWrite: 0)
        }
        if normalized.contains("grok") {
            return Price(input: 5.0, output: 15.0, cacheRead: 0, cacheWrite: 0)
        }

        // Meta Llama 系列
        if normalized.contains("llama-3.3") || normalized.contains("llama3.3") {
            return Price(input: 0.06, output: 0.06, cacheRead: 0, cacheWrite: 0)
        }
        if normalized.contains("llama-3.1") || normalized.contains("llama3.1") {
            return Price(input: 0.18, output: 0.18, cacheRead: 0, cacheWrite: 0)
        }
        if normalized.contains("llama") {
            return Price(input: 0.18, output: 0.18, cacheRead: 0, cacheWrite: 0)
        }

        // 其他常见模型
        if normalized.contains("mistral") {
            return Price(input: 1.0, output: 3.0, cacheRead: 0, cacheWrite: 0)
        }
        if normalized.contains("mixtral") {
            return Price(input: 0.7, output: 0.7, cacheRead: 0, cacheWrite: 0)
        }

        // 默认价格（未知模型）
        return Price(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    }
}

private func decodeJSONObject(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] {
        return object
    }
    guard let string = value as? String,
          let data = string.data(using: .utf8) else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func string(_ value: Any?) -> String? {
    value as? String
}

private func int(_ value: Any?) -> Int {
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
}

private func double(_ value: Any?) -> Double {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) ?? 0 }
    return 0
}

private func unixDate(_ value: Any?) -> Date? {
    let seconds = double(value)
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func date(from value: Any?) -> Date? {
    guard let raw = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
}
