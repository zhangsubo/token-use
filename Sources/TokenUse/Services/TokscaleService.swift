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

    func fetchModels(todayOnly: Bool = false) async throws -> TokscaleReport {
        if resolvedPath == nil {
            _ = checkInstallation()
        }
        guard let tokscalePath = resolvedPath else {
            throw TokscaleError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tokscalePath)
        var args = ["models", "--json", "--no-spinner"]
        if todayOnly {
            args.append("--today")
        }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    do {
                        let report = try JSONDecoder().decode(TokscaleReport.self, from: data)
                        continuation.resume(returning: report)
                    } catch {
                        continuation.resume(throwing: TokscaleError.decodeFailed(error.localizedDescription))
                    }
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "未知错误"
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
