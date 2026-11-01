import Foundation

actor ReportManager {
    static let shared = ReportManager()

    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("com.tokenuse.app/reports", isDirectory: true)
    }

    /// 兼容旧版本的报告目录（仅作只读回退）
    private var legacyReportsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications/token-use/report", isDirectory: true)
    }

    /// 缓存有效期：1 小时
    private let cacheValidityDuration: TimeInterval = 3600
    /// 最多保留历史报告文件数，防止无限堆积
    private let maxRetainedReports = 5

    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func saveReport(_ data: Data) throws -> URL {
        try ensureDirectoryExists()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "report-\(timestamp).json"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        try data.write(to: fileURL, options: .atomic)
        pruneOldReports()
        return fileURL
    }

    /// 保存结构化快照（如多账号聚合快照）
    func saveSnapshot<T: Encodable>(_ value: T, filename: String) throws {
        try ensureDirectoryExists()
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 读取结构化快照（可选校验最大缓存年龄）
    func loadSnapshot<T: Decodable>(_ type: T.Type, filename: String, maxAge: TimeInterval? = nil) -> T? {
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        if let maxAge {
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            if let modDate, Date().timeIntervalSince(modDate) >= maxAge {
                return nil
            }
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 加载最新的报告（优先新缓存目录，回退旧目录）
    func loadLatestReport() -> TokscaleReport? {
        if let latest = latestReportURL(in: cacheDirectory),
           let data = try? Data(contentsOf: latest),
           let report = try? JSONDecoder().decode(TokscaleReport.self, from: data) {
            return report
        }
        if let legacy = latestReportURL(in: legacyReportsDirectory),
           let data = try? Data(contentsOf: legacy),
           let report = try? JSONDecoder().decode(TokscaleReport.self, from: data) {
            return report
        }
        return nil
    }

    /// 检查缓存是否有效（最新报告修改/创建时间在有效期内）
    func isCacheValid() -> Bool {
        guard let latest = latestReportURL(in: cacheDirectory) ?? latestReportURL(in: legacyReportsDirectory) else {
            return false
        }
        let values = try? latest.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        guard let date = values?.contentModificationDate ?? values?.creationDate else {
            return false
        }
        return Date().timeIntervalSince(date) < cacheValidityDuration
    }

    func listReports() -> [URL] {
        reportFiles(in: cacheDirectory)
    }

    private func reportFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return files.filter { $0.lastPathComponent.hasPrefix("report-") && $0.pathExtension == "json" }
    }

    private func latestReportURL(in directory: URL) -> URL? {
        let sorted = reportFiles(in: directory).sorted { url1, url2 in
            let v1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let v2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let d1 = v1?.contentModificationDate ?? v1?.creationDate ?? .distantPast
            let d2 = v2?.contentModificationDate ?? v2?.creationDate ?? .distantPast
            return d1 > d2
        }
        return sorted.first
    }

    private func pruneOldReports() {
        let sorted = reportFiles(in: cacheDirectory).sorted { url1, url2 in
            let v1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let v2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let d1 = v1?.contentModificationDate ?? v1?.creationDate ?? .distantPast
            let d2 = v2?.contentModificationDate ?? v2?.creationDate ?? .distantPast
            return d1 > d2
        }
        guard sorted.count > maxRetainedReports else { return }
        for oldFile in sorted.dropFirst(maxRetainedReports) {
            try? FileManager.default.removeItem(at: oldFile)
        }
    }
}
