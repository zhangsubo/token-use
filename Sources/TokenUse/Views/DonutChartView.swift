import SwiftUI
import Charts

struct DonutChartView: View {
    let segments: [ChartSegment]
    let totalTokens: Int

    private var colorMap: [String: Color] {
        [
            "chartBlue": Color(.sRGB, red: 0.310, green: 0.525, blue: 0.969),    // #4F86F7
            "chartGreen": Color(.sRGB, red: 0.608, green: 0.796, blue: 0.471),   // #9BCB78
            "chartOrange": Color(.sRGB, red: 1.0, green: 0.596, blue: 0.282),    // #FF9848
            "chartPurple": Color(.sRGB, red: 0.604, green: 0.416, blue: 0.941),  // #9A6AF0
            "chartPink": Color(.sRGB, red: 1.0, green: 0.30, blue: 0.50),
            "chartGray": Color(.sRGB, red: 0.725, green: 0.757, blue: 0.839)     // #B9C1D6
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                // Background circle — spec: 274×274
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.10),
                                .white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 274, height: 274)
                    .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )

                // Donut — spec: outer 137px, inner 83px → ratio 0.606, angularInset 2.5, cornerRadius 4
                Chart(segments) { segment in
                    SectorMark(
                        angle: .value("Tokens", segment.value),
                        innerRadius: .ratio(0.606),
                        angularInset: 2.5
                    )
                    .foregroundStyle(colorMap[segment.colorName] ?? .gray)
                    .cornerRadius(4)
                }
                .chartBackground { _ in
                    Color.clear
                }
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)

                // Center text — spec: 40px bold + 20px regular
                VStack(spacing: 2) {
                    Text(NumberFormatterUtil.format(totalTokens))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Total Tokens")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .frame(width: 160)
            }

            // Legend — spec: 296pt width, 15×15 dots, 17pt text, 38pt row height
            VStack(alignment: .leading, spacing: 2) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorMap[segment.colorName] ?? .gray)
                            .frame(width: 15, height: 15)

                        Text(segment.name)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.86))

                        Spacer(minLength: 8)

                        Text(NumberFormatterUtil.format(segment.value))
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))

                        Text(percentage(of: segment.value))
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(width: 58, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                }
            }
            .frame(width: 296)
        }
        .padding(.vertical, 2)
    }

    private func percentage(of value: Int) -> String {
        guard totalTokens > 0 else { return "0%" }
        let pct = Double(value) / Double(totalTokens) * 100
        if pct < 1 {
            return String(format: "%.1f%%", pct)
        }
        return String(format: "%.0f%%", pct)
    }
}
