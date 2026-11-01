import Foundation
import Darwin
import SQLite

// MARK: - NativeUsageService
/// 高性能原生日志与数据库扫描服务（Swift 6 Actor）
/// 单次遍历同时产出近 90 天总量与今日用量，并按 5 大平台（Codex / MiMo / Kimi / MiniMax / Antigravity）与多账号归集。

struct CombinedLocalUsageResult: Sendable {
    let allTimeReport: TokscaleReport
    let todayReport: TokscaleReport
    let perAccountAllTime: [String: UsageTotals]
    let perAccountToday: [String: UsageTotals]
    let perProviderAllTime: [TrackedProvider: UsageTotals]
    let perProviderToday: [TrackedProvider: UsageTotals]
    let offlineCodexSnapshots: [String: OfflineCodexRateLimit]
}

struct UsageTotals: Sendable, Codable, Equatable {
    var tokens: Int = 0
    var cost: Double = 0.0
    var breakdown: TokenBreakdownSnapshot = TokenBreakdownSnapshot()

    mutating func add(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int,
        cost: Double
    ) {
        let total = input + output + cacheRead + cacheWrite + reasoning
        self.tokens += total
        self.cost += cost
        self.breakdown.input += input
        self.breakdown.output += output
        self.breakdown.cacheRead += cacheRead
        self.breakdown.cacheWrite += cacheWrite
        self.breakdown.reasoning += reasoning
    }
}

actor NativeUsageService {
    static let shared = NativeUsageService()

    private static let codexNeedles: [[UInt8]] = [
        Array("\"token_count\"".utf8),
        Array("\"turn_context\"".utf8),
        Array("\"session_meta\"".utf8),
    ]
    private static let kimiNeedles: [[UInt8]] = [
        Array("\"usage.record\"".utf8),
        Array("\"StatusUpdate\"".utf8),
    ]
    private static let assistantUsageNeedles: [[UInt8]] = [
        Array("\"assistant\"".utf8),
        Array("\"usage\"".utf8),
    ]
    private static let antigravityTranscriptNeedles: [[UInt8]] = [
        Array("\"PLANNER_RESPONSE\"".utf8),
    ]

    private let fileManager = FileManager.default

    func fetchToday() async throws -> TokscaleReport {
        let combined = await fetchCombined(accounts: [], dynamicAntigravityModels: [:])
        return combined.todayReport
    }

    func fetchAllTime() async throws -> TokscaleReport {
        let combined = await fetchCombined(accounts: [], dynamicAntigravityModels: [:])
        return combined.allTimeReport
    }

    /// 单次遍历同时计算近 90 天与今日数据，避免冷启动串行扫两遍磁盘
    func fetchCombined(
        accounts: [ProviderAccountConfig],
        dynamicAntigravityModels: [Int: String]
    ) async -> CombinedLocalUsageResult {
        let now = Date()
        let allTimeInterval = DateInterval(start: now.addingTimeInterval(-86_400 * 90), end: now.addingTimeInterval(3600))
        let todayInterval = Self.localDayInterval(for: now)

        var state = DualScanState(
            allTimeInterval: allTimeInterval,
            todayInterval: todayInterval,
            accounts: accounts
        )

        scanCodex(state: &state)
        scanMiMo(state: &state)
        scanKimi(state: &state)
        scanMiniMaxCode(state: &state)
        scanOpenCode(state: &state)
        scanClaudeRoutedModels(state: &state)
        scanAntigravity(state: &state, dynamicModels: dynamicAntigravityModels)

        return CombinedLocalUsageResult(
            allTimeReport: state.allTimeAccumulator.report(),
            todayReport: state.todayAccumulator.report(),
            perAccountAllTime: state.perAccountAllTime,
            perAccountToday: state.perAccountToday,
            perProviderAllTime: state.perProviderAllTime,
            perProviderToday: state.perProviderToday,
            offlineCodexSnapshots: state.offlineCodexSnapshots
        )
    }

    // MARK: - 1. Codex Scanner (sessions + archived_sessions + .jsonl.zst + 真实模型 + 账号归属)

    private func scanCodex(state: inout DualScanState) {
        var roots: [(url: URL, ownerAccountId: String?)] = []
        for acct in state.accounts where acct.provider == .codex {
            if let custom = acct.customLogPath, !custom.isEmpty {
                roots.append((URL(fileURLWithPath: expandTilde(custom)), acct.id))
            }
        }

        let activeCodexHome = CodexAccountSwitchService.codexHomeDirectory()
        roots.append((activeCodexHome, nil))
        let defaultCodexHome = homeDirectory.appendingPathComponent(".codex")
        if activeCodexHome.resolvingSymlinksInPath().standardizedFileURL.path
            != defaultCodexHome.resolvingSymlinksInPath().standardizedFileURL.path {
            roots.append((defaultCodexHome, nil))
        }

        var scannedFiles = Set<String>()
        var seenRolloutKeys = Set<String>()
        let cutoff = state.allTimeInterval.start.addingTimeInterval(-86_400)

        for (root, ownerId) in roots {
            let rootCanonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            let subdirs: [URL]
            let lastComp = root.lastPathComponent
            if lastComp == "sessions" || lastComp == "archived_sessions" {
                subdirs = [root]
            } else {
                subdirs = [
                    root.appendingPathComponent("sessions"),
                    root.appendingPathComponent("archived_sessions"),
                ]
            }

            var candidateFiles: [URL] = []
            for dir in subdirs where fileManager.fileExists(atPath: dir.path) {
                let found = recentFiles(under: dir, cutoff: cutoff) { url in
                    let name = url.lastPathComponent
                    return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
                }
                candidateFiles.append(contentsOf: found)
            }

            // 优先扫描未压缩的 .jsonl；若同一 rollout 同时存在 .jsonl 与 .jsonl.zst，则跳过压缩副本
            candidateFiles.sort { lhs, rhs in
                let lZst = lhs.lastPathComponent.hasSuffix(".jsonl.zst")
                let rZst = rhs.lastPathComponent.hasSuffix(".jsonl.zst")
                if lZst != rZst { return !lZst }
                return lhs.path < rhs.path
            }

            for file in candidateFiles {
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard scannedFiles.insert(canonical).inserted else { continue }

                let fileName = file.lastPathComponent
                let stem: String
                if fileName.hasSuffix(".jsonl.zst") {
                    stem = String(fileName.dropLast(".jsonl.zst".count))
                } else if fileName.hasSuffix(".jsonl") {
                    stem = String(fileName.dropLast(".jsonl".count))
                } else {
                    stem = fileName
                }
                let rolloutKey = "\(rootCanonical)::\(stem)"
                guard seenRolloutKeys.insert(rolloutKey).inserted else { continue }

                parseCodexSessionFile(file, defaultAccountId: ownerId, state: &state)
            }
        }
    }

    private func parseCodexSessionFile(
        _ file: URL,
        defaultAccountId: String?,
        state: inout DualScanState
    ) {
        let fileData: Data?
        if file.lastPathComponent.hasSuffix(".jsonl.zst") {
            fileData = ZstdDecompressor.decompressData(at: file)
        } else {
            fileData = readMappedData(file)
        }
        guard let fileData else { return }

        var creatorChatGPTAccountId: String? = nil
        var currentModel: String = "codex-default"
        var lastTotalTokens: Int = -1

        forEachJSONLLine(in: fileData, matchingAny: Self.codexNeedles) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else {
                return
            }

            if type == "session_meta", let payload = obj["payload"] as? [String: Any] {
                if let acct = payload["creator_account_id"] as? String, !acct.isEmpty {
                    creatorChatGPTAccountId = acct
                }
                if let baseInst = payload["base_instructions"] as? [String: Any],
                   let prov = baseInst["provenance"] as? [String: Any],
                   let m = prov["model"] as? String, !m.isEmpty {
                    currentModel = m
                }
                return
            }

            if type == "turn_context", let payload = obj["payload"] as? [String: Any] {
                if let m = payload["model"] as? String, !m.isEmpty {
                    currentModel = m
                } else if let collab = payload["collaboration_mode"] as? [String: Any],
                          let settings = collab["settings"] as? [String: Any],
                          let m = settings["model"] as? String, !m.isEmpty {
                    currentModel = m
                }
                return
            }

            guard type == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let timestamp = parseISO(obj["timestamp"]) else {
                return
            }

            // 捕获离线速率限制快照
            if let rateLimits = payload["rate_limits"] as? [String: Any] {
                recordOfflineCodexSnapshot(
                    rateLimits,
                    timestamp: timestamp,
                    chatgptAccountId: creatorChatGPTAccountId,
                    into: &state.offlineCodexSnapshots
                )
            }

            guard state.allTimeInterval.contains(timestamp),
                  let info = payload["info"] as? [String: Any] else {
                return
            }

            // 去重连续重复的 token_count 事件
            if let totalUsage = info["total_token_usage"] as? [String: Any] {
                let sessionTotal = int(totalUsage["total_tokens"])
                if sessionTotal > 0 && sessionTotal == lastTotalTokens {
                    return
                }
                if sessionTotal > 0 {
                    lastTotalTokens = sessionTotal
                }
            }

            // 仅读取单步增量 last_token_usage（绝不把累计 total_token_usage 当单步累加！）
            guard let usage = info["last_token_usage"] as? [String: Any] else { return }

            let rawInput = int(usage["input_tokens"])
            let cacheRead = int(usage["cached_input_tokens"])
            let cacheWrite = int(usage["cache_write_input_tokens"])
            let uncachedInput = max(0, rawInput - cacheRead - cacheWrite)

            let rawOutput = int(usage["output_tokens"])
            let reasoning = int(usage["reasoning_output_tokens"])
            let nonReasoningOutput = max(0, rawOutput - reasoning)

            let resolvedAcctId = state.matchCodexAccount(
                chatgptAccountId: creatorChatGPTAccountId,
                fallbackAccountId: defaultAccountId
            )

            let cost = PriceResolver.estimate(
                model: currentModel,
                provider: "openai",
                input: uncachedInput,
                output: nonReasoningOutput,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning
            )

            state.record(
                timestamp: timestamp,
                client: "codex",
                provider: "openai",
                model: currentModel,
                explicitProvider: nil,
                accountId: resolvedAcctId,
                input: uncachedInput,
                output: nonReasoningOutput,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                cost: cost
            )
        }
    }

    private func recordOfflineCodexSnapshot(
        _ rl: [String: Any],
        timestamp: Date,
        chatgptAccountId: String?,
        into map: inout [String: OfflineCodexRateLimit]
    ) {
        let primary = rl["primary"] as? [String: Any]
        let secondary = rl["secondary"] as? [String: Any]
        let snap = OfflineCodexRateLimit(
            timestamp: timestamp,
            planType: rl["plan_type"] as? String,
            primaryUsedPercent: primary?["used_percent"] != nil ? double(primary?["used_percent"]) : nil,
            primaryResetAt: unixSecondsDate(primary?["resets_at"]),
            secondaryUsedPercent: secondary?["used_percent"] != nil ? double(secondary?["used_percent"]) : nil,
            secondaryResetAt: unixSecondsDate(secondary?["resets_at"])
        )
        let keys = [chatgptAccountId, "__default__"].compactMap { $0 }
        for k in keys {
            if let existing = map[k], existing.timestamp >= timestamp { continue }
            map[k] = snap
        }
    }

    // MARK: - 2. Xiaomi MiMo Scanner (mimocode.db / micode.db + Orca 桌面端沙盒去重)

    private func scanMiMo(state: inout DualScanState) {
        var dbTargets: [(url: URL, ownerAccountId: String?)] = []
        let dbFilenames = ["mimocode.db", "micode.db"]

        for acct in state.accounts where acct.provider == .mimo {
            if let custom = acct.customLogPath, !custom.isEmpty {
                let expanded = URL(fileURLWithPath: expandTilde(custom))
                if expanded.pathExtension == "db" {
                    dbTargets.append((expanded, acct.id))
                } else {
                    for name in dbFilenames {
                        dbTargets.append((expanded.appendingPathComponent(name), acct.id))
                    }
                }
            }
        }

        var sharedDirs: [URL] = []
        if let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgData.isEmpty {
            sharedDirs.append(URL(fileURLWithPath: expandTilde(xdgData)).appendingPathComponent("mimocode"))
        }
        sharedDirs.append(homeDirectory.appendingPathComponent(".local/share/mimocode"))
        // Xiaomi MiMo Desktop 内置 Orca 运行时沙盒数据库
        sharedDirs.append(homeDirectory.appendingPathComponent("Library/Application Support/orca/mimocode-hooks/shared/data"))

        for dir in sharedDirs {
            for name in dbFilenames {
                dbTargets.append((dir.appendingPathComponent(name), nil))
            }
        }

        var scannedDBs = Set<String>()
        var seenMessageIds = Set<String>()
        let startMs = Int64(state.allTimeInterval.start.timeIntervalSince1970 * 1000)

        for (dbURL, ownerId) in dbTargets {
            let canonical = dbURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard scannedDBs.insert(canonical).inserted,
                  fileManager.fileExists(atPath: canonical),
                  let db = try? Connection(canonical, readonly: true) else {
                continue
            }

            let stmtJsonFiltered = try? db.prepare(
                "SELECT id, time_created, data FROM message WHERE time_created >= ? AND json_extract(data, '$.role') = 'assistant'",
                startMs
            )
            let stmtWithId = stmtJsonFiltered ?? (try? db.prepare("SELECT id, time_created, data FROM message WHERE time_created >= ?", startMs))
            let hasIdColumn = stmtWithId != nil
            guard let stmt = stmtWithId ?? (try? db.prepare("SELECT time_created, data FROM message WHERE time_created >= ?", startMs)) else {
                continue
            }

            for row in stmt {
                let msgId: String?
                let createdMsOpt: Int64?
                let dataStrOpt: String?
                if hasIdColumn {
                    msgId = row[0] as? String
                    createdMsOpt = row[1] as? Int64
                    dataStrOpt = row[2] as? String
                } else {
                    msgId = nil
                    createdMsOpt = row[0] as? Int64
                    dataStrOpt = row[1] as? String
                }

                if let msgId, !msgId.isEmpty {
                    guard seenMessageIds.insert(msgId).inserted else { continue }
                }

                guard let createdMs = createdMsOpt,
                      let dataStr = dataStrOpt,
                      dataStr.contains("\"assistant\""),
                      let jsonData = dataStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      (obj["role"] as? String) == "assistant" else {
                    continue
                }

                if msgId == nil, let bodyId = obj["id"] as? String, !bodyId.isEmpty {
                    guard seenMessageIds.insert(bodyId).inserted else { continue }
                }

                let timestamp = Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
                guard state.allTimeInterval.contains(timestamp),
                      let tokens = obj["tokens"] as? [String: Any] else {
                    continue
                }

                let modelId = (obj["modelID"] as? String) ?? "mimo-v2.6-pro"
                let providerId = (obj["providerID"] as? String) ?? "xiaomi"
                let cache = tokens["cache"] as? [String: Any]

                // mimocode.db 中 tokens 各字段互不包含（disjoint）
                let input = int(tokens["input"])
                let output = int(tokens["output"])
                let reasoning = int(tokens["reasoning"])
                let cacheRead = int(cache?["read"])
                let cacheWrite = int(cache?["write"])

                let rawCost = double(obj["cost"])
                let cost = rawCost > 0 ? rawCost : PriceResolver.estimate(
                    model: modelId,
                    provider: providerId,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning
                )

                let acctId = ownerId ?? state.primaryAccountId(for: .mimo)
                state.record(
                    timestamp: timestamp,
                    client: "mimocode",
                    provider: providerId,
                    model: modelId,
                    explicitProvider: nil,
                    accountId: acctId,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning,
                    cost: cost
                )
            }
        }
    }

    // MARK: - 3. Kimi Code Scanner (CLI + Kimi Desktop daimon-share + usageScope 去重)

    private func scanKimi(state: inout DualScanState) {
        var roots: [(url: URL, ownerAccountId: String?)] = []
        // 先绑定各 Kimi 账号声明的目录，确保精确归属
        for acct in state.accounts where acct.provider == .kimi {
            if let custom = acct.customLogPath, !custom.isEmpty {
                roots.append((URL(fileURLWithPath: expandTilde(custom)), acct.id))
            }
        }
        if let kimiHomeEnv = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !kimiHomeEnv.isEmpty {
            roots.append((URL(fileURLWithPath: expandTilde(kimiHomeEnv)), nil))
        }
        roots.append((homeDirectory.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home"), nil))
        roots.append((homeDirectory.appendingPathComponent(".kimi-code"), nil))
        roots.append((homeDirectory.appendingPathComponent(".kimi"), nil))

        var scannedFiles = Set<String>()
        let cutoff = state.allTimeInterval.start.addingTimeInterval(-86_400)

        for (root, ownerId) in roots {
            let sessionsDir = root.lastPathComponent == "sessions"
                ? root
                : root.appendingPathComponent("sessions")
            guard fileManager.fileExists(atPath: sessionsDir.path) else { continue }

            let resolvedOwner = ownerId ?? state.primaryAccountId(for: .kimi)
            for file in recentFiles(under: sessionsDir, cutoff: cutoff, where: { $0.lastPathComponent == "wire.jsonl" }) {
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard scannedFiles.insert(canonical).inserted else { continue }
                parseKimiWireFile(file, accountId: resolvedOwner, state: &state)
            }
        }
    }

    private func parseKimiWireFile(
        _ file: URL,
        accountId: String?,
        state: inout DualScanState
    ) {
        guard let fileData = readMappedData(file) else { return }

        forEachJSONLLine(in: fileData, matchingAny: Self.kimiNeedles) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            if (obj["type"] as? String) == "usage.record" {
                // 跳过会话级汇总行，防止与单步 turn 记录叠加导致 2 倍重复计数
                if (obj["usageScope"] as? String) == "session" {
                    return
                }
                let timeMs = double(obj["time"])
                guard timeMs > 0 else { return }
                let timestamp = Date(timeIntervalSince1970: timeMs > 1_000_000_000_000 ? timeMs / 1000.0 : timeMs)
                guard state.allTimeInterval.contains(timestamp),
                      let usage = obj["usage"] as? [String: Any] else { return }

                var model = (obj["model"] as? String) ?? "kimi-for-coding"
                if model.hasPrefix("kimi-code/") {
                    model = String(model.dropFirst("kimi-code/".count))
                }
                let input = int(usage["inputOther"])
                let output = int(usage["output"])
                let cacheRead = int(usage["inputCacheRead"])
                let cacheWrite = int(usage["inputCacheCreation"])
                let cost = PriceResolver.estimate(
                    model: model,
                    provider: "moonshot",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0
                )

                state.record(
                    timestamp: timestamp,
                    client: "kimi-code",
                    provider: "moonshot",
                    model: model,
                    explicitProvider: .kimi,
                    accountId: accountId,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    cost: cost
                )
            } else if let timestamp = unixSecondsDate(obj["timestamp"]),
                      state.allTimeInterval.contains(timestamp),
                      let msg = obj["message"] as? [String: Any],
                      (msg["type"] as? String) == "StatusUpdate",
                      let payload = msg["payload"] as? [String: Any],
                      let usage = payload["token_usage"] as? [String: Any] {
                let input = int(usage["input_other"])
                let output = int(usage["output"])
                let cacheRead = int(usage["input_cache_read"])
                let cacheWrite = int(usage["input_cache_creation"])
                let model = "kimi-for-coding"
                let cost = PriceResolver.estimate(
                    model: model,
                    provider: "moonshot",
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0
                )

                state.record(
                    timestamp: timestamp,
                    client: "kimi",
                    provider: "moonshot",
                    model: model,
                    explicitProvider: .kimi,
                    accountId: accountId,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: 0,
                    cost: cost
                )
            }
        }
    }

    // MARK: - 3b. MiniMax Code (mcode) Runtime Scanner (~/.minimax/v2/sessions + ~/.mavis/v2/sessions)

    private func scanMiniMaxCode(state: inout DualScanState) {
        var sessionRoots: [(url: URL, ownerAccountId: String?)] = []

        for acct in state.accounts where acct.provider == .minimax {
            if let custom = acct.customLogPath, !custom.isEmpty {
                let expanded = URL(fileURLWithPath: expandTilde(custom))
                if expanded.pathExtension != "db" {
                    let v2Dir = expanded.lastPathComponent == "sessions"
                        ? expanded
                        : expanded.appendingPathComponent("v2/sessions")
                    if fileManager.fileExists(atPath: v2Dir.path) {
                        sessionRoots.append((v2Dir, acct.id))
                    }
                }
            }
        }

        let env = ProcessInfo.processInfo.environment
        if let minimaxEnv = env["MINIMAX_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !minimaxEnv.isEmpty {
            sessionRoots.append((URL(fileURLWithPath: expandTilde(minimaxEnv)).appendingPathComponent("v2/sessions"), nil))
        } else if let mavisEnv = env["MAVIS_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !mavisEnv.isEmpty {
            sessionRoots.append((URL(fileURLWithPath: expandTilde(mavisEnv)).appendingPathComponent("v2/sessions"), nil))
        } else {
            var dataDirs: [URL] = [
                homeDirectory.appendingPathComponent(".minimax"),
                homeDirectory.appendingPathComponent(".mavis"),
            ]
            if let entries = try? fileManager.contentsOfDirectory(at: homeDirectory, includingPropertiesForKeys: nil, options: []) {
                let profileDirs = entries.filter { url in
                    let name = url.lastPathComponent
                    return (name.hasPrefix(".minimax-") && name.count > 9)
                        || (name.hasPrefix(".mavis-") && name.count > 7)
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                dataDirs.append(contentsOf: profileDirs)
            }
            for dir in dataDirs {
                sessionRoots.append((dir.appendingPathComponent("v2/sessions"), nil))
            }
        }

        var seenStores = Set<String>()
        var seenMessageIds = Set<String>()
        let cutoff = state.allTimeInterval.start.addingTimeInterval(-86_400)

        for (sessionsDir, ownerId) in sessionRoots {
            guard fileManager.fileExists(atPath: sessionsDir.path) else { continue }
            let canonicalStore = sessionsDir.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenStores.insert(canonicalStore).inserted else { continue }

            let resolvedOwner = ownerId ?? state.primaryAccountId(for: .minimax)
            var files = recentFiles(under: sessionsDir, cutoff: cutoff) { url in
                url.pathExtension == "jsonl"
            }
            // 先扫描活跃历史 messages.jsonl，再扫描 snapshots/g*.jsonl，按 message_id 去重
            files.sort { lhs, rhs in
                let lActive = lhs.lastPathComponent == "messages.jsonl"
                let rActive = rhs.lastPathComponent == "messages.jsonl"
                if lActive != rActive { return lActive }
                return lhs.path < rhs.path
            }

            for file in files {
                parseMiniMaxCodeSessionFile(
                    file,
                    accountId: resolvedOwner,
                    seenMessageIds: &seenMessageIds,
                    state: &state
                )
            }
        }
    }

    private func parseMiniMaxCodeSessionFile(
        _ file: URL,
        accountId: String?,
        seenMessageIds: inout Set<String>,
        state: inout DualScanState
    ) {
        guard let fileData = readMappedData(file) else { return }

        forEachJSONLLine(in: fileData, matchingAll: Self.assistantUsageNeedles) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            let msg = (obj["message"] as? [String: Any]) ?? obj
            guard (msg["role"] as? String) == "assistant",
                  let usage = msg["usage"] as? [String: Any] else {
                return
            }

            let rawMsgId = (obj["message_id"] as? String)
                ?? (msg["id"] as? String)
                ?? (obj["id"] as? String)
            if let rawMsgId, !rawMsgId.isEmpty {
                guard seenMessageIds.insert(rawMsgId).inserted else { return }
            }

            let tsAny = msg["timestamp"] ?? obj["timestamp"]
            let timestamp: Date? = {
                let numeric = double(tsAny)
                if numeric > 0 {
                    return Date(timeIntervalSince1970: numeric > 1_000_000_000_000 ? numeric / 1000.0 : numeric)
                }
                return parseISO(tsAny)
            }()
            guard let timestamp, state.allTimeInterval.contains(timestamp) else { return }

            // Pi / MiniMax Code runtime 格式中 input 已不含 cacheRead；output 内部包含 reasoning
            let input = int(usage["input"] ?? usage["input_tokens"])
            let rawOutput = int(usage["output"] ?? usage["output_tokens"])
            let cacheRead = int(usage["cacheRead"] ?? usage["cache_read_input_tokens"] ?? usage["cache_read"])
            let cacheWrite = int(usage["cacheWrite"] ?? usage["cache_creation_input_tokens"] ?? usage["cache_write"])
            let reasoning = int(usage["reasoning"] ?? usage["reasoning_tokens"])
            let nonReasoningOutput = reasoning <= rawOutput ? max(0, rawOutput - reasoning) : rawOutput

            let model = ((msg["model"] as? String) ?? "minimax-m2.7").trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = ((msg["provider"] as? String) ?? "minimax").trimmingCharacters(in: .whitespacesAndNewlines)
            let costObj = usage["cost"] as? [String: Any]
            let rawCost = double(costObj?["total"] ?? usage["cost"])
            let cost = rawCost > 0 ? rawCost : PriceResolver.estimate(
                model: model,
                provider: provider,
                input: input,
                output: nonReasoningOutput,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning
            )

            state.record(
                timestamp: timestamp,
                client: "mcode",
                provider: provider,
                model: model,
                explicitProvider: .minimax,
                accountId: accountId,
                input: input,
                output: nonReasoningOutput,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                cost: cost
            )
        }
    }

    // MARK: - 4. OpenCode & Claude Routed Scanner (MiniMax / MiMo / Kimi 跨客户端调用)

    private func scanOpenCode(state: inout DualScanState) {
        var dirs: [URL] = [homeDirectory.appendingPathComponent(".local/share/opencode")]
        for acct in state.accounts where acct.provider == .minimax {
            if let custom = acct.customLogPath, !custom.isEmpty {
                dirs.append(URL(fileURLWithPath: expandTilde(custom)))
            }
        }

        var scannedDBs = Set<String>()
        let startMs = Int64(state.allTimeInterval.start.timeIntervalSince1970 * 1000)

        for dir in dirs {
            let dbFiles: [URL]
            if dir.pathExtension == "db" {
                dbFiles = [dir]
            } else {
                dbFiles = recentFiles(under: dir, cutoff: nil) { url in
                    let name = url.lastPathComponent
                    return name == "opencode.db" || (name.hasPrefix("opencode-") && name.hasSuffix(".db"))
                }
            }

            for dbURL in dbFiles {
                let canonical = dbURL.standardizedFileURL.path
                guard scannedDBs.insert(canonical).inserted,
                      fileManager.fileExists(atPath: canonical),
                      let db = try? Connection(canonical, readonly: true) else {
                    continue
                }

                let existingTables = sqliteTableNames(in: db)
                var seenMessageIds = Set<String>()

                // 1) 新版 OpenCode session_message 表
                if existingTables.contains("session_message") {
                    let sql = "SELECT id, time_created, data FROM session_message WHERE type = 'assistant' AND time_created >= ?"
                    if let stmt = try? db.prepare(sql, startMs) {
                        for row in stmt {
                            if let msgId = row[0] as? String { seenMessageIds.insert(msgId) }
                            guard let createdMs = row[1] as? Int64,
                                  let dataStr = row[2] as? String else { continue }
                            parseOpenCodeAssistantMessageJSON(dataStr, createdMs: createdMs, state: &state)
                        }
                    }
                }

                // 2) 旧版 OpenCode message 表（严格排除已在 session_message 统计过的迁移记录！）
                if existingTables.contains("message") {
                    let sql = "SELECT id, time_created, data FROM message WHERE time_created >= ?"
                    if let stmt = try? db.prepare(sql, startMs) {
                        for row in stmt {
                            if let msgId = row[0] as? String, seenMessageIds.contains(msgId) {
                                continue
                            }
                            guard let createdMs = row[1] as? Int64,
                                  let dataStr = row[2] as? String,
                                  dataStr.contains("\"assistant\"") else { continue }
                            parseOpenCodeAssistantMessageJSON(dataStr, createdMs: createdMs, state: &state)
                        }
                    }
                }

                // 3) 仅当无消息表时回退 session 表
                if !existingTables.contains("session_message") && !existingTables.contains("message") && existingTables.contains("session") {
                    let sql = "SELECT model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_updated FROM session WHERE time_updated >= ?"
                    if let stmt = try? db.prepare(sql, startMs) {
                        for row in stmt {
                            let modelRaw = row[0] as? String
                            let modelObj = decodeJSONObject(modelRaw)
                            let modelId = (modelObj?["id"] as? String) ?? modelRaw ?? "unknown"
                            let providerId = (modelObj?["providerID"] as? String) ?? "opencode"
                            guard let tracked = TrackedProvider.classify(client: "opencode", provider: providerId, model: modelId) else {
                                continue
                            }
                            let updatedMs = (row[7] as? Int64) ?? 0
                            let timestamp = Date(timeIntervalSince1970: Double(updatedMs) / 1000.0)
                            guard state.allTimeInterval.contains(timestamp) else { continue }

                            let input = Int((row[1] as? Int64) ?? 0)
                            let output = Int((row[2] as? Int64) ?? 0)
                            let cacheRead = Int((row[3] as? Int64) ?? 0)
                            let cacheWrite = Int((row[4] as? Int64) ?? 0)
                            let reasoning = Int((row[5] as? Int64) ?? 0)
                            let rawCost = (row[6] as? Double) ?? 0
                            let cost = rawCost > 0 ? rawCost : PriceResolver.estimate(
                                model: modelId,
                                provider: providerId,
                                input: input,
                                output: output,
                                cacheRead: cacheRead,
                                cacheWrite: cacheWrite,
                                reasoning: reasoning
                            )

                            state.record(
                                timestamp: timestamp,
                                client: "opencode",
                                provider: providerId,
                                model: modelId,
                                explicitProvider: tracked,
                                accountId: state.primaryAccountId(for: tracked),
                                input: input,
                                output: output,
                                cacheRead: cacheRead,
                                cacheWrite: cacheWrite,
                                reasoning: reasoning,
                                cost: cost
                            )
                        }
                    }
                }
            }
        }
    }

    private func parseOpenCodeAssistantMessageJSON(
        _ dataStr: String,
        createdMs: Int64,
        state: inout DualScanState
    ) {
        guard let jsonData = dataStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }
        if let role = obj["role"] as? String, role != "assistant" {
            return
        }

        let modelDict = obj["model"] as? [String: Any]
        let modelId = (modelDict?["id"] as? String)
            ?? (obj["modelID"] as? String)
            ?? "unknown"
        let providerId = (modelDict?["providerID"] as? String)
            ?? (obj["providerID"] as? String)
            ?? "opencode"

        guard let tracked = TrackedProvider.classify(client: "opencode", provider: providerId, model: modelId),
              let tokens = obj["tokens"] as? [String: Any] else {
            return
        }

        let timestamp = Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
        guard state.allTimeInterval.contains(timestamp) else { return }

        let cache = tokens["cache"] as? [String: Any]
        let input = int(tokens["input"])
        let output = int(tokens["output"])
        let reasoning = int(tokens["reasoning"])
        let cacheRead = int(cache?["read"])
        let cacheWrite = int(cache?["write"])

        let rawCost = double(obj["cost"])
        let cost = rawCost > 0 ? rawCost : PriceResolver.estimate(
            model: modelId,
            provider: providerId,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning
        )

        state.record(
            timestamp: timestamp,
            client: "opencode",
            provider: providerId,
            model: modelId,
            explicitProvider: tracked,
            accountId: state.primaryAccountId(for: tracked),
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            cost: cost
        )
    }

    private func scanClaudeRoutedModels(state: inout DualScanState) {
        let roots = [
            homeDirectory.appendingPathComponent(".claude/projects"),
            homeDirectory.appendingPathComponent(".config/claude/projects"),
        ]
        let cutoff = state.allTimeInterval.start.addingTimeInterval(-86_400)
        var scanned = Set<String>()

        for root in roots where fileManager.fileExists(atPath: root.path) {
            for file in recentFiles(under: root, cutoff: cutoff, where: { $0.pathExtension == "jsonl" }) {
                let canonical = file.standardizedFileURL.path
                guard scanned.insert(canonical).inserted,
                      let fileData = readMappedData(file) else { continue }

                forEachJSONLLine(in: fileData, matchingAll: Self.assistantUsageNeedles) { lineData in
                    guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let msg = obj["message"] as? [String: Any],
                          let model = msg["model"] as? String,
                          let tracked = TrackedProvider.classify(client: "claude", provider: "", model: model),
                          let timestamp = parseISO(obj["timestamp"]),
                          state.allTimeInterval.contains(timestamp),
                          let usage = msg["usage"] as? [String: Any] else {
                        return
                    }

                    let input = int(usage["input_tokens"])
                    let output = int(usage["output_tokens"])
                    let cacheRead = int(usage["cache_read_input_tokens"])
                    let cacheCreation = usage["cache_creation"] as? [String: Any]
                    let cacheWrite = int(usage["cache_creation_input_tokens"])
                        + int(cacheCreation?["ephemeral_1h_input_tokens"])
                        + int(cacheCreation?["ephemeral_5m_input_tokens"])

                    let cost = PriceResolver.estimate(
                        model: model,
                        provider: tracked.rawValue,
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        reasoning: 0
                    )

                    state.record(
                        timestamp: timestamp,
                        client: "claude",
                        provider: tracked.rawValue,
                        model: model,
                        explicitProvider: tracked,
                        accountId: state.primaryAccountId(for: tracked),
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        reasoning: 0,
                        cost: cost
                    )
                }
            }
        }
    }

    // MARK: - 5. Google Antigravity Scanner (conversations/*.db Protobuf + transcript.jsonl 回退)

    private func scanAntigravity(
        state: inout DualScanState,
        dynamicModels: [Int: String]
    ) {
        var roots: [(url: URL, ownerAccountId: String?)] = []
        for acct in state.accounts where acct.provider == .antigravity {
            if let custom = acct.customLogPath, !custom.isEmpty {
                roots.append((URL(fileURLWithPath: expandTilde(custom)), acct.id))
            }
        }
        if let geminiCliHome = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !geminiCliHome.isEmpty {
            roots.append((URL(fileURLWithPath: expandTilde(geminiCliHome)).appendingPathComponent("antigravity-cli"), nil))
        }
        let geminiDir = homeDirectory.appendingPathComponent(".gemini")
        roots.append((geminiDir.appendingPathComponent("antigravity"), nil))
        roots.append((geminiDir.appendingPathComponent("antigravity-ide"), nil))
        roots.append((geminiDir.appendingPathComponent("antigravity-cli"), nil))
        if let geminiEntries = try? fileManager.contentsOfDirectory(at: geminiDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for entry in geminiEntries where entry.lastPathComponent.hasPrefix("antigravity") {
                roots.append((entry, nil))
            }
        }

        var seenConversationIds = Set<String>()
        var scannedRoots = Set<String>()
        let cutoff = state.allTimeInterval.start.addingTimeInterval(-86_400)

        for (root, ownerId) in roots {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard scannedRoots.insert(canonicalRoot).inserted,
                  fileManager.fileExists(atPath: canonicalRoot) else {
                continue
            }

            let resolvedAccount = ownerId ?? state.primaryAccountId(for: .antigravity)

            // 1) 优先扫描 conversations/<conv_id>.db（具备完整每步模型 ID + 思维链 Token 拆分）
            let convsDir = root.appendingPathComponent("conversations")
            if fileManager.fileExists(atPath: convsDir.path) {
                for dbFile in recentFiles(under: convsDir, cutoff: cutoff, where: { $0.pathExtension == "db" }) {
                    let convId = dbFile.deletingPathExtension().lastPathComponent
                    guard seenConversationIds.insert(convId).inserted else { continue }
                    parseAntigravityConversationDB(
                        dbFile,
                        accountId: resolvedAccount,
                        dynamicModels: dynamicModels,
                        state: &state
                    )
                }
            }

            // 2) 对缺少 .db 的会话回退扫描 brain/<conv_id>/.system_generated/logs/transcript.jsonl
            let brainDir = root.appendingPathComponent("brain")
            if let convDirs = try? fileManager.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for convDir in convDirs {
                    let convId = convDir.lastPathComponent
                    guard !seenConversationIds.contains(convId) else { continue }
                    let transcript = convDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                    guard fileManager.fileExists(atPath: transcript.path) else { continue }
                    if let mod = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate),
                       mod < cutoff {
                        continue
                    }
                    seenConversationIds.insert(convId)
                    parseAntigravityTranscript(transcript, accountId: resolvedAccount, state: &state)
                }
            }
        }
    }

    private func parseAntigravityConversationDB(
        _ dbFile: URL,
        accountId: String?,
        dynamicModels: [Int: String],
        state: inout DualScanState
    ) {
        guard let db = try? Connection(dbFile.path, readonly: true) else { return }

        // 从 gen_metadata 提取离线后端模型名兜底
        var fallbackModelName: String? = nil
        if let genStmt = try? db.prepare("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 3") {
            for row in genStmt {
                if let blob = row[0] as? SQLite.Blob {
                    let data = Data(blob.bytes)
                    if let extracted = AntigravityProtoDecoder.extractGenMetadataModel(data), !extracted.isEmpty {
                        fallbackModelName = extracted
                        break
                    }
                }
            }
        }

        guard let stepStmt = try? db.prepare("SELECT metadata FROM steps WHERE step_type = 15") else {
            return
        }

        for row in stepStmt {
            guard let blob = row[0] as? SQLite.Blob else { continue }
            let data = Data(blob.bytes)
            guard let stepUsage = AntigravityProtoDecoder.decodeStepMetadata(data),
                  let timestamp = stepUsage.timestamp,
                  state.allTimeInterval.contains(timestamp) else {
                continue
            }

            let modelName = resolveAntigravityModelName(
                enumId: stepUsage.modelEnumId,
                dynamicModels: dynamicModels,
                fallback: fallbackModelName
            )
            // 注意：totalOutputTokens 已包含 thinkingTokens，拆分避免重复相加
            let reasoning = stepUsage.thinkingTokens
            let nonReasoningOutput = max(0, stepUsage.totalOutputTokens - reasoning)

            let cost = PriceResolver.estimate(
                model: modelName,
                provider: "antigravity",
                input: stepUsage.inputTokens,
                output: nonReasoningOutput,
                cacheRead: stepUsage.cacheReadTokens,
                cacheWrite: stepUsage.cacheCreationTokens,
                reasoning: reasoning
            )

            state.record(
                timestamp: timestamp,
                client: "antigravity",
                provider: "antigravity",
                model: modelName,
                explicitProvider: .antigravity,
                accountId: accountId,
                input: stepUsage.inputTokens,
                output: nonReasoningOutput,
                cacheRead: stepUsage.cacheReadTokens,
                cacheWrite: stepUsage.cacheCreationTokens,
                reasoning: reasoning,
                cost: cost
            )
        }
    }

    private func parseAntigravityTranscript(
        _ file: URL,
        accountId: String?,
        state: inout DualScanState
    ) {
        guard let fileData = readMappedData(file) else { return }
        forEachJSONLLine(in: fileData, matchingAny: Self.antigravityTranscriptNeedles) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "PLANNER_RESPONSE",
                  let timestamp = parseISO(obj["created_at"]),
                  state.allTimeInterval.contains(timestamp) else {
                return
            }

            let input = int(obj["input_tokens"])
            let output = int(obj["output_tokens"])
            let cacheRead = int(obj["cache_read_tokens"])
            let model = "antigravity-agent"
            let cost = PriceResolver.estimate(
                model: model,
                provider: "google",
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: 0,
                reasoning: 0
            )

            state.record(
                timestamp: timestamp,
                client: "antigravity",
                provider: "antigravity",
                model: model,
                explicitProvider: .antigravity,
                accountId: accountId,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: 0,
                reasoning: 0,
                cost: cost
            )
        }
    }

    private func resolveAntigravityModelName(
        enumId: Int,
        dynamicModels: [Int: String],
        fallback: String?
    ) -> String {
        if let dyn = dynamicModels[enumId] { return dyn }
        switch enumId {
        case 1400: return "claude-opus-5.5-low"
        case 1401: return "claude-opus-5.5-medium"
        case 1402: return "claude-opus-5.5-high"
        case 1403: return "claude-sonnet-5.5-low"
        case 1404: return "claude-sonnet-5.5-medium"
        case 1405: return "claude-sonnet-5.5-high"
        case 1417: return "gemini-4-argon-high"
        case 1418: return "gemini-4-argon-medium"
        case 1419: return "gemini-4-argon-low"
        case 1318: return "gemini-3.8-flash-high"
        case 1319: return "gemini-3.8-flash-medium"
        case 1320: return "gemini-3.8-flash-low"
        case 1018: return "gemini-3-flash"
        default:
            if let fallback, !fallback.isEmpty { return fallback }
            return enumId > 0 ? "antigravity-m\(enumId)" : "antigravity"
        }
    }

    // MARK: - Filesystem & SQLite Utilities

    private var homeDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func recentFiles(
        under root: URL,
        cutoff: Date?,
        where predicate: (URL) -> Bool
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard predicate(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            if let cutoff, let mod = values.contentModificationDate, mod < cutoff {
                continue
            }
            result.append(url)
        }
        return result
    }

    private func readUTF8(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readMappedData(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// 基于 C `memchr` + `memmem` 的零拷贝字节级 JSONL 行扫描器：
    /// 直接在内存页上以 >5 GB/s 定位换行并匹配关键字，避免将数百 MB 日志转为 Swift `String` 遍历 Unicode 字素簇。
    private func forEachJSONLLine(
        in data: Data,
        matchingAny anyNeedles: [[UInt8]] = [],
        matchingAll allNeedles: [[UInt8]] = [],
        body: (Data) -> Void
    ) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let total = rawBuf.count
            var offset = 0

            while offset < total {
                let linePtr = base.advanced(by: offset)
                let remaining = total - offset
                let nlRaw = memchr(linePtr, 0x0A, remaining)
                let rawLen: Int
                let nextOffset: Int
                if let nlRaw {
                    rawLen = UnsafeRawPointer(linePtr).distance(to: UnsafeRawPointer(nlRaw))
                    nextOffset = offset + rawLen + 1
                } else {
                    rawLen = remaining
                    nextOffset = total
                }
                offset = nextOffset

                var lineLen = rawLen
                if lineLen > 0 && linePtr[lineLen - 1] == 0x0D {
                    lineLen -= 1
                }
                guard lineLen > 2 else { continue }

                if !allNeedles.isEmpty {
                    var allMatched = true
                    for needle in allNeedles {
                        let matched = needle.withUnsafeBufferPointer { nBuf -> Bool in
                            guard let nBase = nBuf.baseAddress, nBuf.count <= lineLen else { return false }
                            return memmem(linePtr, lineLen, nBase, nBuf.count) != nil
                        }
                        if !matched {
                            allMatched = false
                            break
                        }
                    }
                    guard allMatched else { continue }
                }

                if !anyNeedles.isEmpty {
                    var anyMatched = false
                    for needle in anyNeedles {
                        let matched = needle.withUnsafeBufferPointer { nBuf -> Bool in
                            guard let nBase = nBuf.baseAddress, nBuf.count <= lineLen else { return false }
                            return memmem(linePtr, lineLen, nBase, nBuf.count) != nil
                        }
                        if matched {
                            anyMatched = true
                            break
                        }
                    }
                    guard anyMatched else { continue }
                }

                let lineData = Data(bytes: linePtr, count: lineLen)
                body(lineData)
            }
        }
    }

    private func sqliteTableNames(in db: Connection) -> Set<String> {
        var names = Set<String>()
        if let stmt = try? db.prepare("SELECT name FROM sqlite_master WHERE type='table'") {
            for row in stmt {
                if let name = row[0] as? String { names.insert(name) }
            }
        }
        return names
    }

    private static func localDayInterval(for date: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}

// MARK: - DualScanState

private struct DualScanState {
    let allTimeInterval: DateInterval
    let todayInterval: DateInterval
    let accounts: [ProviderAccountConfig]

    var allTimeAccumulator = UsageAccumulator()
    var todayAccumulator = UsageAccumulator()

    var perAccountAllTime: [String: UsageTotals] = [:]
    var perAccountToday: [String: UsageTotals] = [:]
    var perProviderAllTime: [TrackedProvider: UsageTotals] = [:]
    var perProviderToday: [TrackedProvider: UsageTotals] = [:]
    var offlineCodexSnapshots: [String: OfflineCodexRateLimit] = [:]

    func primaryAccountId(for provider: TrackedProvider) -> String? {
        accounts.first { $0.provider == provider && $0.isEnabled }?.id
    }

    func matchCodexAccount(chatgptAccountId: String?, fallbackAccountId: String?) -> String? {
        if let chatgptAccountId, !chatgptAccountId.isEmpty,
           let matched = accounts.first(where: { $0.provider == .codex && $0.externalAccountId == chatgptAccountId }) {
            return matched.id
        }
        return fallbackAccountId ?? primaryAccountId(for: .codex)
    }

    mutating func record(
        timestamp: Date,
        client: String,
        provider: String,
        model: String,
        explicitProvider: TrackedProvider?,
        accountId: String?,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int,
        cost: Double
    ) {
        let total = input + output + cacheRead + cacheWrite + reasoning
        guard total > 0 else { return }

        guard let tracked = explicitProvider ?? TrackedProvider.classify(client: client, provider: provider, model: model) else {
            return
        }

        let effectiveAccountId: String? = {
            if let accountId,
               let acct = accounts.first(where: { $0.id == accountId }),
               acct.provider == tracked {
                return accountId
            }
            return primaryAccountId(for: tracked)
        }()

        let isToday = todayInterval.contains(timestamp)

        allTimeAccumulator.add(
            client: client,
            provider: tracked.rawValue,
            model: model,
            accountId: effectiveAccountId,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            messageCount: 1,
            cost: cost
        )
        perProviderAllTime[tracked, default: UsageTotals()].add(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            cost: cost
        )
        if let effectiveAccountId {
            perAccountAllTime[effectiveAccountId, default: UsageTotals()].add(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                cost: cost
            )
        }

        if isToday {
            todayAccumulator.add(
                client: client,
                provider: tracked.rawValue,
                model: model,
                accountId: effectiveAccountId,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                messageCount: 1,
                cost: cost
            )
            perProviderToday[tracked, default: UsageTotals()].add(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                cost: cost
            )
            if let effectiveAccountId {
                perAccountToday[effectiveAccountId, default: UsageTotals()].add(
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning,
                    cost: cost
                )
            }
        }
    }
}

// MARK: - UsageAccumulator

private struct UsageKey: Hashable {
    let client: String
    let provider: String
    let model: String
    let accountId: String?
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

    mutating func add(
        client: String,
        provider: String,
        model: String,
        accountId: String?,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int,
        messageCount: Int,
        cost: Double
    ) {
        guard input + output + cacheRead + cacheWrite + reasoning > 0 else { return }
        let key = UsageKey(client: client, provider: provider, model: model, accountId: accountId)
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
                cost: bucket.cost,
                accountId: key.accountId
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

// MARK: - Lightweight Protobuf Wire Decoder for Antigravity SQLite Metadata

private enum AntigravityProtoDecoder {
    struct StepMetadataUsage {
        var timestamp: Date?
        var modelEnumId: Int = 0
        var inputTokens: Int = 0
        var totalOutputTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0
        var thinkingTokens: Int = 0
    }

    static func decodeStepMetadata(_ data: Data) -> StepMetadataUsage? {
        var result = StepMetadataUsage()
        var foundUsage = false

        parseFields(data) { fieldNum, wireType, payload in
            if fieldNum == 1 && wireType == 2, let sub = payload.bytes {
                // google.protobuf.Timestamp { 1: seconds }
                parseFields(sub) { tsField, tsWire, tsVal in
                    if tsField == 1 && tsWire == 0, tsVal.varint > 0 {
                        result.timestamp = Date(timeIntervalSince1970: Double(tsVal.varint))
                    }
                }
            } else if fieldNum == 9 && wireType == 2, let sub = payload.bytes {
                // ModelUsageInfo
                foundUsage = true
                parseFields(sub) { uField, uWire, uVal in
                    guard uWire == 0 else { return }
                    let v = Int(truncatingIfNeeded: uVal.varint)
                    switch uField {
                    case 1: result.modelEnumId = v
                    case 2: result.inputTokens = v
                    case 3: result.totalOutputTokens = v
                    case 4: result.cacheCreationTokens = v
                    case 5: result.cacheReadTokens = v
                    case 9: result.thinkingTokens = v
                    default: break
                    }
                }
            }
        }

        return foundUsage ? result : nil
    }

    static func extractGenMetadataModel(_ data: Data) -> String? {
        var modelString: String?
        parseFields(data) { fieldNum, wireType, payload in
            guard fieldNum == 1 && wireType == 2, let inner = payload.bytes else { return }
            parseFields(inner) { subField, subWire, subVal in
                if subField == 19 && subWire == 2, let strData = subVal.bytes,
                   let str = String(data: strData, encoding: .utf8), !str.isEmpty {
                    modelString = str
                }
            }
        }
        return modelString
    }

    private struct WireValue {
        var varint: UInt64 = 0
        var bytes: Data? = nil
    }

    private static func parseFields(_ data: Data, onField: (Int, Int, WireValue) -> Void) {
        let bytes = [UInt8](data)
        var idx = 0
        let count = bytes.count

        while idx < count {
            guard let tag = readVarint(bytes, &idx) else { return }
            let fieldNum = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNum > 0 else { return }

            switch wireType {
            case 0: // Varint
                guard let v = readVarint(bytes, &idx) else { return }
                onField(fieldNum, 0, WireValue(varint: v))
            case 1: // 64-bit
                guard idx + 8 <= count else { return }
                idx += 8
            case 2: // Length-delimited
                guard let lenU64 = readVarint(bytes, &idx) else { return }
                let len = Int(lenU64)
                guard len >= 0, idx + len <= count else { return }
                let sub = Data(bytes[idx..<(idx + len)])
                idx += len
                onField(fieldNum, 2, WireValue(bytes: sub))
            case 5: // 32-bit
                guard idx + 4 <= count else { return }
                idx += 4
            default:
                return
            }
        }
    }

    @inline(__always)
    private static func readVarint(_ bytes: [UInt8], _ idx: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while idx < bytes.count && shift < 64 {
            let b = bytes[idx]
            idx += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }
}

// MARK: - PriceResolver (修正匹配顺序 + 覆盖最新 5 大平台模型)

enum PriceResolver {
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
        let p = price(for: model, provider: provider)
        let outputLike = output + reasoning
        return (
            Double(input) * p.input
            + Double(outputLike) * p.output
            + Double(cacheRead) * p.cacheRead
            + Double(cacheWrite) * p.cacheWrite
        ) / 1_000_000.0
    }

    private static func price(for model: String, provider: String) -> Price {
        let m = model.lowercased()
        let p = provider.lowercased()

        // 1. OpenAI / Codex 系列（注意 gpt-4.1 / gpt-4o 必须在 gpt-4 之前！）
        if m.contains("gpt-6") || m.contains("gpt6") {
            return Price(input: 2.0, output: 12.0, cacheRead: 0.2, cacheWrite: 2.0)
        }
        if m.contains("gpt-5.5") || m.contains("gpt5.5") {
            return Price(input: 1.5, output: 12.0, cacheRead: 0.15, cacheWrite: 1.5)
        }
        if m.contains("gpt-5") || m.contains("gpt5") || m.contains("codex") {
            return Price(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25)
        }
        if m.contains("gpt-4.1-nano") {
            return Price(input: 0.1, output: 0.4, cacheRead: 0.025, cacheWrite: 0.1)
        }
        if m.contains("gpt-4.1-mini") || m.contains("gpt-4o-mini") || m.contains("o4-mini") || m.contains("o3-mini") {
            return Price(input: 0.4, output: 1.6, cacheRead: 0.1, cacheWrite: 0.4)
        }
        if m.contains("gpt-4.1") {
            return Price(input: 2.0, output: 8.0, cacheRead: 0.5, cacheWrite: 2.0)
        }
        if m.contains("gpt-4o") {
            return Price(input: 2.5, output: 10.0, cacheRead: 1.25, cacheWrite: 2.5)
        }
        if m.hasPrefix("o3") || m.hasPrefix("o1") {
            return Price(input: 2.0, output: 8.0, cacheRead: 0.5, cacheWrite: 2.0)
        }

        // 2. Xiaomi MiMo 系列
        if m.contains("mimo-v2.6-pro") || m.contains("mimo-v2.5-pro") {
            return Price(input: 0.8, output: 3.0, cacheRead: 0.16, cacheWrite: 0.8)
        }
        if m.contains("mimo-v2.6-flash") {
            return Price(input: 0.2, output: 0.8, cacheRead: 0.04, cacheWrite: 0.2)
        }
        if m.contains("mimo") || p.contains("xiaomi") || p.contains("mimo") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }

        // 3. Moonshot Kimi Code 系列
        if m.contains("k3.1-pro") || m.contains("k3") || m.contains("k2.7") {
            return Price(input: 1.0, output: 4.0, cacheRead: 0.2, cacheWrite: 1.0)
        }
        if m.contains("k2.6") || m.contains("k2p6") {
            return Price(input: 0.95, output: 4.0, cacheRead: 0.16, cacheWrite: 0.95)
        }
        if m.contains("kimi") || m.contains("k2.5") || p.contains("moonshot") || p.contains("kimi") {
            return Price(input: 0.6, output: 2.0, cacheRead: 0.15, cacheWrite: 0.6)
        }

        // 4. MiniMax 系列
        if m.contains("minimax-m3") {
            return Price(input: 0.5, output: 2.0, cacheRead: 0.1, cacheWrite: 0.5)
        }
        if m.contains("minimax-m2.7") {
            return Price(input: 0.4, output: 1.6, cacheRead: 0.08, cacheWrite: 0.4)
        }
        if m.contains("minimax") || p.contains("minimax") {
            return Price(input: 0.4, output: 1.6, cacheRead: 0.08, cacheWrite: 0.4)
        }

        // 5. Antigravity 内部模型（Gemini 4 / 3.8 / Claude 5.5 / GPT-OSS）
        if m.contains("opus") {
            return Price(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 6.25)
        }
        if m.contains("sonnet") {
            return Price(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75)
        }
        if m.contains("flash") {
            return Price(input: 0.3, output: 2.5, cacheRead: 0.075, cacheWrite: 0.3)
        }
        if m.contains("gemini") || m.contains("argon") || p.contains("antigravity") {
            return Price(input: 1.25, output: 10.0, cacheRead: 0.3, cacheWrite: 1.25)
        }

        return Price(input: 0.5, output: 2.0, cacheRead: 0.1, cacheWrite: 0.5)
    }
}

// MARK: - Primitive Parsers

private func decodeJSONObject(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] { return object }
    guard let string = value as? String,
          let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func int(_ value: Any?) -> Int {
    if let v = value as? Int { return v }
    if let v = value as? Double { return Int(v) }
    if let v = value as? NSNumber { return v.intValue }
    if let v = value as? String { return Int(v) ?? 0 }
    return 0
}

private func double(_ value: Any?) -> Double {
    if let v = value as? Double { return v }
    if let v = value as? Int { return Double(v) }
    if let v = value as? NSNumber { return v.doubleValue }
    if let v = value as? String { return Double(v) ?? 0 }
    return 0
}

private func unixSecondsDate(_ value: Any?) -> Date? {
    let seconds = double(value)
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func parseISO(_ value: Any?) -> Date? {
    guard let raw = value as? String else { return nil }
    return FastDateParser.parseISO8601(raw)
}
