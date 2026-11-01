import Foundation
import SQLite

// MARK: - SessionActivityMonitor
/// 轻量级本机活跃会话实时监听器（每 2.5 秒轮询一次最近会话文件 mtime 与尾部状态，单次开销 < 1ms）
/// 用于驱动侧边悬浮舱圆环旋转动画，并在活跃对话刚结束时触发增量本地统计刷新。

@MainActor
final class SessionActivityMonitor: ObservableObject {
    static let shared = SessionActivityMonitor()

    @Published private(set) var activeProviders: Set<TrackedProvider> = []

    /// 当某个平台的活跃会话刚完成一轮输出时回调（已防抖）
    var onSessionTurnFinished: (() -> Void)?

    private let scanner = SessionActivityScanner()
    private var monitorTask: Task<Void, Never>?
    private var lastTurnFinishedCallbackAt: Date = .distantPast

    private init() {}

    func start(accountsProvider: @escaping @MainActor () -> [ProviderAccountConfig]) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let accounts = accountsProvider()
                let currentActive = await self.scanner.detectActiveProviders(accounts: accounts)
                if Task.isCancelled { break }

                let previousActive = self.activeProviders
                if currentActive != previousActive {
                    self.activeProviders = currentActive

                    // 若有平台从「运行中」变为「空闲」，说明一轮生成刚落盘完成，触发轻量级本地统计更新
                    let finished = previousActive.subtracting(currentActive)
                    if !finished.isEmpty {
                        let now = Date()
                        if now.timeIntervalSince(self.lastTurnFinishedCallbackAt) >= 6.0 {
                            self.lastTurnFinishedCallbackAt = now
                            self.onSessionTurnFinished?()
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}

// MARK: - Background Activity Scanner

private actor SessionActivityScanner {
    private let fileManager = FileManager.default
    private var cachedRecentKimiFiles: [URL] = []
    private var cachedRecentMiniMaxFiles: [URL] = []
    private var cachedRecentClaudeFiles: [URL] = []
    private var lastDirectorySweepAt: Date = .distantPast

    private var homeDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    func detectActiveProviders(accounts: [ProviderAccountConfig]) -> Set<TrackedProvider> {
        let now = Date()
        refreshRecentFileCacheIfNeeded(now: now, accounts: accounts)

        var active = Set<TrackedProvider>()

        if isCodexActive(now: now, accounts: accounts) {
            active.insert(.codex)
        }
        if isAntigravityActive(now: now, accounts: accounts) {
            active.insert(.antigravity)
        }
        if isMiMoActive(now: now, accounts: accounts) {
            active.insert(.mimo)
        }
        if isKimiActive(now: now) {
            active.insert(.kimi)
        }
        if isMiniMaxActive(now: now) {
            active.insert(.minimax)
        }
        for routed in activeCrossClientProviders(now: now, accounts: accounts) {
            active.insert(routed)
        }

        return active
    }

    // MARK: - Periodic Directory Cache (每 15 秒更新一次候选活跃文件列表)

    private func refreshRecentFileCacheIfNeeded(now: Date, accounts: [ProviderAccountConfig]) {
        guard now.timeIntervalSince(lastDirectorySweepAt) >= 15.0 else { return }
        lastDirectorySweepAt = now
        let recentCutoff = now.addingTimeInterval(-7200) // 仅关注最近 2 小时修改过的会话文件

        // 1. Kimi wire.jsonl
        var kimiRoots: [URL] = [
            homeDirectory.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"),
            homeDirectory.appendingPathComponent(".kimi-code/sessions"),
            homeDirectory.appendingPathComponent(".kimi/sessions"),
        ]
        for acct in accounts where acct.provider == .kimi {
            if let custom = acct.customLogPath, !custom.isEmpty {
                let u = URL(fileURLWithPath: expandTilde(custom))
                kimiRoots.append(u.lastPathComponent == "sessions" ? u : u.appendingPathComponent("sessions"))
            }
        }
        cachedRecentKimiFiles = collectRecentFiles(roots: kimiRoots, cutoff: recentCutoff) {
            $0.lastPathComponent == "wire.jsonl"
        }

        // 2. MiniMax mcode messages.jsonl
        var mmRoots: [URL] = [
            homeDirectory.appendingPathComponent(".minimax/v2/sessions"),
            homeDirectory.appendingPathComponent(".mavis/v2/sessions"),
        ]
        for acct in accounts where acct.provider == .minimax {
            if let custom = acct.customLogPath, !custom.isEmpty {
                let u = URL(fileURLWithPath: expandTilde(custom))
                if u.pathExtension != "db" {
                    mmRoots.append(u.lastPathComponent == "sessions" ? u : u.appendingPathComponent("v2/sessions"))
                }
            }
        }
        cachedRecentMiniMaxFiles = collectRecentFiles(roots: mmRoots, cutoff: recentCutoff) {
            $0.lastPathComponent == "messages.jsonl"
        }

        // 3. Claude routed .jsonl
        let claudeRoots: [URL] = [
            homeDirectory.appendingPathComponent(".claude/projects"),
            homeDirectory.appendingPathComponent(".config/claude/projects"),
        ]
        cachedRecentClaudeFiles = collectRecentFiles(roots: claudeRoots, cutoff: recentCutoff) {
            $0.pathExtension == "jsonl"
        }
    }

    // MARK: - 1. Codex Activity

    private func isCodexActive(now: Date, accounts: [ProviderAccountConfig]) -> Bool {
        var homes: [URL] = [
            CodexAccountSwitchService.codexHomeDirectory(),
            homeDirectory.appendingPathComponent(".codex"),
        ]
        for acct in accounts where acct.provider == .codex {
            if let custom = acct.customLogPath, !custom.isEmpty {
                homes.append(URL(fileURLWithPath: expandTilde(custom)))
            }
        }

        let cal = Calendar.current
        let datesToCheck = [now, now.addingTimeInterval(-86_400)]
        var newestFile: URL?
        var newestMtime: Date = .distantPast

        for home in homes {
            let sessionsBase = home.lastPathComponent == "sessions"
                ? home
                : home.appendingPathComponent("sessions")
            for date in datesToCheck {
                let comps = cal.dateComponents([.year, .month, .day], from: date)
                guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
                let dayDir = sessionsBase
                    .appendingPathComponent(String(format: "%04d", y))
                    .appendingPathComponent(String(format: "%02d", m))
                    .appendingPathComponent(String(format: "%02d", d))
                guard let files = try? fileManager.contentsOfDirectory(
                    at: dayDir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                ) else { continue }

                for f in files where f.pathExtension == "jsonl" {
                    if let mod = modificationDate(of: f), mod > newestMtime {
                        newestMtime = mod
                        newestFile = f
                    }
                }
            }
        }

        guard let file = newestFile else { return false }
        let age = now.timeIntervalSince(newestMtime)
        guard age <= 90.0 else { return false }

        guard let tail = readTailUTF8(of: file, maxBytes: 16_384) else {
            return age <= 8.0
        }

        let lastStarted = maxIndex(of: ["\"task_started\"", "\"turn_context\""], in: tail)
        let lastCompleted = maxIndex(of: ["\"task_complete\"", "\"turn_aborted\""], in: tail)

        if let s = lastStarted {
            if let c = lastCompleted {
                return s > c
            }
            return true
        }
        if lastCompleted != nil {
            return false
        }
        return age <= 8.0
    }

    // MARK: - 2. Antigravity Activity

    private func isAntigravityActive(now: Date, accounts: [ProviderAccountConfig]) -> Bool {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini")
        var roots: [URL] = [
            geminiDir.appendingPathComponent("antigravity"),
            geminiDir.appendingPathComponent("antigravity-ide"),
            geminiDir.appendingPathComponent("antigravity-cli"),
        ]
        for acct in accounts where acct.provider == .antigravity {
            if let custom = acct.customLogPath, !custom.isEmpty {
                roots.append(URL(fileURLWithPath: expandTilde(custom)))
            }
        }

        var newestDB: URL?
        var newestAge: TimeInterval = .greatestFiniteMagnitude

        for root in roots {
            let convDir = root.appendingPathComponent("conversations")
            guard let entries = try? fileManager.contentsOfDirectory(
                at: convDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                // 注意：绝不检查 .db-shm（只读打开 SQLite 也会更新 shm 时间戳），仅检查真实写入的 .db 与 .db-wal
                guard name.hasSuffix(".db") || name.hasSuffix(".db-wal") else { continue }
                guard let mod = modificationDate(of: entry) else { continue }
                let age = now.timeIntervalSince(mod)
                if age < newestAge {
                    newestAge = age
                    if name.hasSuffix(".db-wal") {
                        let basePath = String(entry.path.dropLast(4))
                        newestDB = URL(fileURLWithPath: basePath)
                    } else {
                        newestDB = entry
                    }
                }
            }
        }

        guard newestAge <= 75.0 else { return false }
        if newestAge <= 6.0 {
            return true
        }

        // 若在 6s ~ 75s 之间（例如模型深度思考中），检查最新 step 状态是否仍处于未完成态 (status == 1 或 2)
        if let dbURL = newestDB,
           fileManager.fileExists(atPath: dbURL.path),
           let db = try? Connection(dbURL.path, readonly: true),
           let statusVal = try? db.scalar("SELECT status FROM steps ORDER BY idx DESC LIMIT 1") as? Int64 {
            return statusVal == 1 || statusVal == 2
        }

        return false
    }

    // MARK: - 3. MiMo Activity

    private func isMiMoActive(now: Date, accounts: [ProviderAccountConfig]) -> Bool {
        var dirs: [URL] = [
            homeDirectory.appendingPathComponent(".local/share/mimocode"),
            homeDirectory.appendingPathComponent("Library/Application Support/orca/mimocode-hooks/shared/data"),
        ]
        for acct in accounts where acct.provider == .mimo {
            if let custom = acct.customLogPath, !custom.isEmpty {
                dirs.append(URL(fileURLWithPath: expandTilde(custom)))
            }
        }

        for dir in dirs {
            for baseName in ["mimocode.db", "micode.db"] {
                let dbURL = dir.pathExtension == "db" ? dir : dir.appendingPathComponent(baseName)
                let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
                let age = min(
                    modificationDate(of: dbURL).map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude,
                    modificationDate(of: walURL).map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                )
                guard age <= 75.0 else { continue }
                if age <= 6.0 { return true }

                if fileManager.fileExists(atPath: dbURL.path),
                   let db = try? Connection(dbURL.path, readonly: true),
                   let dataStr = try? db.scalar("SELECT data FROM message ORDER BY rowid DESC LIMIT 1") as? String,
                   let data = dataStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let role = obj["role"] as? String
                    if role == "user" { return true }
                    if role == "assistant" {
                        let timeObj = obj["time"] as? [String: Any]
                        if timeObj?["completed"] == nil && obj["error"] == nil {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    // MARK: - 4. Kimi Activity

    private func isKimiActive(now: Date) -> Bool {
        var newestFile: URL?
        var newestAge: TimeInterval = .greatestFiniteMagnitude

        for file in cachedRecentKimiFiles {
            guard let mod = modificationDate(of: file) else { continue }
            let age = now.timeIntervalSince(mod)
            if age < newestAge {
                newestAge = age
                newestFile = file
            }
        }

        guard let file = newestFile, newestAge <= 75.0 else { return false }
        if newestAge <= 6.0 { return true }

        if let tail = readTailUTF8(of: file, maxBytes: 12_288) {
            let lastReq = maxIndex(of: ["\"llm.request\""], in: tail)
            let lastDone = maxIndex(of: ["\"usage.record\"", "\"turn.end\""], in: tail)
            if let r = lastReq {
                if let d = lastDone { return r > d }
                return true
            }
        }
        return false
    }

    // MARK: - 5. MiniMax & Cross-Client Activity

    private func isMiniMaxActive(now: Date) -> Bool {
        for file in cachedRecentMiniMaxFiles {
            guard let mod = modificationDate(of: file) else { continue }
            let age = now.timeIntervalSince(mod)
            guard age <= 75.0 else { continue }
            if age <= 6.0 { return true }
            if let tail = readTailUTF8(of: file, maxBytes: 8_192),
               let lastLine = tail.split(separator: "\n").last,
               lastLine.contains("\"user\"") && !lastLine.contains("\"assistant\"") {
                return true
            }
        }
        return false
    }

    private func activeCrossClientProviders(now: Date, accounts: [ProviderAccountConfig]) -> Set<TrackedProvider> {
        var result = Set<TrackedProvider>()

        // OpenCode SQLite
        let openCodeDir = homeDirectory.appendingPathComponent(".local/share/opencode")
        let dbURL = openCodeDir.appendingPathComponent("opencode.db")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let ocAge = min(
            modificationDate(of: dbURL).map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude,
            modificationDate(of: walURL).map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        )
        if ocAge <= 75.0,
           fileManager.fileExists(atPath: dbURL.path),
           let db = try? Connection(dbURL.path, readonly: true) {
            let dataStr = (try? db.scalar("SELECT data FROM session_message ORDER BY rowid DESC LIMIT 1") as? String)
                ?? (try? db.scalar("SELECT data FROM message ORDER BY rowid DESC LIMIT 1") as? String)
            if let dataStr,
               let data = dataStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let modelDict = obj["model"] as? [String: Any]
                let modelId = (modelDict?["id"] as? String) ?? (obj["modelID"] as? String) ?? ""
                let providerId = (modelDict?["providerID"] as? String) ?? (obj["providerID"] as? String) ?? "opencode"
                if let tracked = TrackedProvider.classify(client: "opencode", provider: providerId, model: modelId) {
                    let timeObj = obj["time"] as? [String: Any]
                    let incomplete = (obj["role"] as? String == "assistant") && (timeObj?["completed"] == nil) && (obj["error"] == nil)
                    if ocAge <= 6.0 || incomplete {
                        result.insert(tracked)
                    }
                }
            }
        }

        // Claude Code routed JSONL
        for file in cachedRecentClaudeFiles {
            guard let mod = modificationDate(of: file) else { continue }
            let age = now.timeIntervalSince(mod)
            guard age <= 10.0,
                  let tail = readTailUTF8(of: file, maxBytes: 12_288) else { continue }
            for line in tail.split(separator: "\n").reversed() {
                guard line.contains("\"model\""),
                      let data = String(line).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let model = msg["model"] as? String,
                      let tracked = TrackedProvider.classify(client: "claude", provider: "", model: model) else {
                    continue
                }
                result.insert(tracked)
                break
            }
        }

        return result
    }

    // MARK: - Helpers

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func modificationDate(of url: URL) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    private func collectRecentFiles(
        roots: [URL],
        cutoff: Date,
        predicate: (URL) -> Bool
    ) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard predicate(url),
                      let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      vals.isRegularFile == true,
                      let mod = vals.contentModificationDate,
                      mod >= cutoff else {
                    continue
                }
                let canonical = url.standardizedFileURL.path
                if seen.insert(canonical).inserted {
                    out.append(url)
                }
            }
        }
        return out
    }

    private func readTailUTF8(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }
        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func maxIndex(of needles: [String], in text: String) -> Int? {
        var best: Int?
        for needle in needles {
            if let range = text.range(of: needle, options: .backwards) {
                let dist = text.distance(from: text.startIndex, to: range.lowerBound)
                if let current = best {
                    if dist > current { best = dist }
                } else {
                    best = dist
                }
            }
        }
        return best
    }
}
