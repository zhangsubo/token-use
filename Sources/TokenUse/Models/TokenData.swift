import Foundation

struct TokscaleEntry: Codable, Sendable {
    let client: String
    let mergedClients: [String]?
    let model: String
    let provider: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int
    let messageCount: Int
    let cost: Double

    var totalTokens: Int {
        input + output + cacheRead + cacheWrite + reasoning
    }
}

struct TokscaleReport: Codable, Sendable {
    let groupBy: String
    let entries: [TokscaleEntry]
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheWrite: Int
    let totalReasoning: Int?
    let totalMessages: Int
    let totalCost: Double

    var totalTokens: Int {
        totalInput + totalOutput + totalCacheRead + totalCacheWrite + (totalReasoning ?? 0)
    }
}

struct ChartSegment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let value: Int
    let colorName: String
}

struct TokenStats: Sendable {
    let allTime: TokscaleReport
    let today: TokscaleReport
    let updatedAt: Date

    var topSegments: [ChartSegment] {
        // Aggregate by model name
        var aggregated: [String: Int] = [:]
        for entry in allTime.entries {
            aggregated[entry.model, default: 0] += entry.totalTokens
        }

        let sorted = aggregated.sorted { $0.value > $1.value }
        let top5 = Array(sorted.prefix(5))
        let others = Array(sorted.dropFirst(5))

        let colors = ["chartBlue", "chartGreen", "chartOrange", "chartPurple", "chartPink"]
        var segments: [ChartSegment] = []

        for (index, item) in top5.enumerated() {
            segments.append(ChartSegment(
                name: item.key,
                value: item.value,
                colorName: colors[index]
            ))
        }

        let othersTokens = others.reduce(0) { $0 + $1.value }
        if othersTokens > 0 {
            segments.append(ChartSegment(
                name: "Others",
                value: othersTokens,
                colorName: "chartGray"
            ))
        }

        return segments
    }
}

// MARK: - Number Formatting

enum NumberFormatterUtil {
    static func format(_ num: Int) -> String {
        let absNum = abs(num)
        if absNum >= 1_000_000_000 {
            let billions = Double(num) / 1_000_000_000.0
            if billions >= 100 {
                return String(format: "%.0f B", billions)
            } else if billions >= 10 {
                return String(format: "%.1f B", billions)
            } else {
                return String(format: "%.2f B", billions)
            }
        } else if absNum >= 1_000_000 {
            let millions = Double(num) / 1_000_000.0
            if millions >= 100 {
                return String(format: "%.0f M", millions)
            } else if millions >= 10 {
                return String(format: "%.1f M", millions)
            } else {
                return String(format: "%.2f M", millions)
            }
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
        }
    }

    static func formatCurrency(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
