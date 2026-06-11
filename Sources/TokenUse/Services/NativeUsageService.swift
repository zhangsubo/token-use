import Foundation

enum NativeUsageError: Error, LocalizedError {
    case noSupportedLogs

    var errorDescription: String? {
        switch self {
        case .noSupportedLogs:
            return "未找到 Codex、OpenCode、Kimi 或 Claude Code 的本地使用日志"
        }
    }
}

actor NativeUsageService {
    static let shared = NativeUsageService()

    private let fileManager = FileManager.default

    func fetchToday() async throws -> TokscaleReport {
        let interval = Self.localDayInterval(for: Date())
        var accumulator = UsageAccumulator()

        scanCodex(interval: interval, into: &accumulator)
        scanClaude(interval: interval, into: &accumulator)
        scanKimi(interval: interval, into: &accumulator)
        scanOpenCode(interval: interval, into: &accumulator)

        if accumulator.isEmpty {
            throw NativeUsageError.noSupportedLogs
        }
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

    private func scanOpenCode(interval: DateInterval, into accumulator: inout UsageAccumulator) {
        let root = homeDirectory.appendingPathComponent(".local/share/opencode")
        let databases = sqliteFiles(under: root)
        for database in databases {
            for row in openCodeRows(database: database, interval: interval) {
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

    private func openCodeRows(database: URL, interval: DateInterval) -> [OpenCodeRow] {
        guard fileManager.fileExists(atPath: database.path) else { return [] }

        let startMillis = Int(interval.start.timeIntervalSince1970 * 1000)
        let endMillis = Int(interval.end.timeIntervalSince1970 * 1000)
        let sql = """
        select model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost
        from session
        where time_updated >= \(startMillis) and time_updated < \(endMillis);
        """

        guard let output = runSQLite(database: database, sql: sql),
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rows.map { row in
            let modelInfo = decodeJSONObject(row["model"])
            let model = string(modelInfo?["id"]) ?? string(row["model"]) ?? "unknown"
            let provider = string(modelInfo?["providerID"]) ?? "opencode"
            return OpenCodeRow(
                provider: provider,
                model: model,
                input: int(row["tokens_input"]),
                output: int(row["tokens_output"]),
                cacheRead: int(row["tokens_cache_read"]),
                cacheWrite: int(row["tokens_cache_write"]),
                reasoning: int(row["tokens_reasoning"]),
                messageCount: 1,
                cost: double(row["cost"])
            )
        }
    }

    private func runSQLite(database: URL, sql: String) -> String? {
        let sqlitePath = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlitePath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-json", database.path, sql]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
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

        if normalized.contains("gpt-5") {
            return Price(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if normalized.contains("claude-opus") {
            return Price(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if normalized.contains("claude") || normalized.contains("sonnet") {
            return Price(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if normalized.contains("kimi") || normalizedProvider.contains("moonshot") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }
        if normalized.contains("glm") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }
        if normalized.contains("mimo") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }
        if normalized.contains("deepseek") {
            return Price(input: 0.27, output: 1.1, cacheRead: 0.07, cacheWrite: 0.27)
        }
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
