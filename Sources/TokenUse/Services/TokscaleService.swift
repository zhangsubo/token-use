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

    /// 找到可用的登录 shell，用于代理执行 CLI 命令。
    /// Why: GUI 应用 Process() 不继承 shell 环境，通过登录 shell 执行可获取完整用户环境。
    private func findLoginShell() -> String {
        let shells = ["/bin/zsh", "/bin/bash"]
        for shell in shells {
            if FileManager.default.isExecutableFile(atPath: shell) {
                return shell
            }
        }
        return "/bin/zsh" // 最后兜底，macOS 一定有
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

        // GUI 应用不继承 shell 环境变量，通过登录 shell 执行以获取完整用户环境
        // Why: 直接 Process() 跑 tokscale（Node.js CLI）缺少 HOME/PATH/NODE_PATH 等变量
        // 登录 shell 会加载 .zprofile/.zshrc，继承全部用户环境，比手动修补 env 更可靠
        let shell = findLoginShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)

        var cmd = "'\(tokscalePath)' models --json --no-spinner"
        if todayOnly {
            cmd += " --today"
        } else if let since {
            cmd += " --since \(since)"
        }
        process.arguments = ["-l", "-c", cmd]

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
