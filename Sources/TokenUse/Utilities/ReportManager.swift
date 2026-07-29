import Foundation

actor ReportManager {
    static let shared = ReportManager()

    private var reportsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications/token-use/report", isDirectory: true)
    }

    /// 缓存有效期：1 小时
    private let cacheValidityDuration: TimeInterval = 3600

    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: reportsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func saveReport(_ data: Data) throws -> URL {
        try ensureDirectoryExists()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "report-\(timestamp).json"
        let fileURL = reportsDirectory.appendingPathComponent(filename)

        try data.write(to: fileURL)
        return fileURL
    }

    /// 加载最新的报告
    func loadLatestReport() -> TokscaleReport? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return nil }

        let sorted = jsonFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }

        guard let latest = sorted.first,
              let data = try? Data(contentsOf: latest) else {
            return nil
        }

        return try? JSONDecoder().decode(TokscaleReport.self, from: data)
    }

    /// 检查缓存是否有效（最新报告创建时间在有效期内）
    func isCacheValid() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return false
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return false }

        let sorted = jsonFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }

        guard let latest = sorted.first,
              let creationDate = try? latest.resourceValues(forKeys: [.creationDateKey]).creationDate else {
            return false
        }

        let age = Date().timeIntervalSince(creationDate)
        return age < cacheValidityDuration
    }

    func listReports() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }
    }
}
