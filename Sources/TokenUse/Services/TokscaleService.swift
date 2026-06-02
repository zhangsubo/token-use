import Foundation

enum TokscaleError: Error, LocalizedError {
    case notInstalled
    case installFailed(String)
    case fetchFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Tokscale 未安装"
        case .installFailed(let msg):
            return "安装失败: \(msg)"
        case .fetchFailed(let msg):
            return "获取数据失败: \(msg)"
        case .decodeFailed(let msg):
            return "解析数据失败: \(msg)"
        }
    }
}

actor TokscaleService {
    static let shared = TokscaleService()

    private var resolvedPath: String?

    private var possiblePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/tokscale",
            "/usr/local/bin/tokscale",
            "\(home)/.npm-global/bin/tokscale",
            "/usr/bin/tokscale",
            "/bin/tokscale",
        ]
    }

    func checkInstallation() -> Bool {
        // Direct path checks (GUI apps don't inherit shell PATH)
        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                resolvedPath = path
                return true
            }
        }

        // Fallback: try `which` via user's default shell
        if let path = whichViaShell() {
            resolvedPath = path
            return true
        }

        resolvedPath = nil
        return false
    }

    private func whichViaShell() -> String? {
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        for shell in shells {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "which tokscale"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    func installTokscale() async throws {
        guard !checkInstallation() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npm", "install", "-g", "tokscale", "--no-spinner"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    Task { await self.checkInstallation() } // Refresh resolved path
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "未知错误"
                    continuation.resume(throwing: TokscaleError.installFailed(msg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TokscaleError.installFailed(error.localizedDescription))
            }
        }
    }

    func fetchModels(todayOnly: Bool = false, since: String? = nil) async throws -> TokscaleReport {
        if resolvedPath == nil {
            _ = checkInstallation()
        }
        guard let tokscalePath = resolvedPath else {
            throw TokscaleError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tokscalePath)
        
        // GUI 应用不继承 shell 环境变量，tokscale 需要 HOME/PATH/NODE_PATH 才能正确读取数据
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:\(home)/.npm-global/bin"
        }
        if env["NODE_PATH"] == nil {
            env["NODE_PATH"] = "/usr/local/lib/node_modules:/opt/homebrew/lib/node_modules:\(home)/.npm-global/lib/node_modules"
        }
        process.environment = env
        
        var args = ["models", "--json", "--no-spinner"]
        // 二选一：--today 是首选；若已指定 --since YYYY-MM-DD 则用 since 走日期窗口
        // Why: tokscale 2.x --today 在少数边界（跨时区/会话数据缺失）下会返回 0，
        // --since 当天日期作为兜底能保证"今日"始终有窗口
        if todayOnly {
            args.append("--today")
        } else if let since {
            args.append("--since")
            args.append(since)
        }
        process.arguments = args

        // stderr 必须独立 Pipe 捕获——原先走 FileHandle.nullDevice 时
        // 任何 CLI 警告/错误都被吞掉，AppState 的 try? 进一步把异常变 nil，
        // 导致"今日 token 永远 = 0"且无任何线索
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                // 必须先读 stdout + stderr 再 resume，否则 Pipe buffer 内的数据可能被截断
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrMsg = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutMsg = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if proc.terminationStatus == 0 {
                    do {
                        let report = try JSONDecoder().decode(TokscaleReport.self, from: stdoutData)
                        continuation.resume(returning: report)
                    } catch {
                        // 把 stderr 拼进错误，便于排查 tokscale 输出格式变化
                        let detail = stderrMsg.map { " [stderr: \($0)]" } ?? ""
                        continuation.resume(throwing: TokscaleError.decodeFailed("\(error.localizedDescription)\(detail)"))
                    }
                } else {
                    // 非 0 退出：优先展示 stderr（CLI 错误通常写这里）
                    let msg = stderrMsg ?? stdoutMsg ?? "tokscale 退出码 \(proc.terminationStatus)"
                    continuation.resume(throwing: TokscaleError.fetchFailed(msg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TokscaleError.fetchFailed(error.localizedDescription))
            }
        }
    }
}
