import Foundation

actor ReportManager {
    static let shared = ReportManager()

    private var reportsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications/token-use/report", isDirectory: true)
    }

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
