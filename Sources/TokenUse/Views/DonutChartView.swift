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
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.13),
                                .white.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 266, height: 266)
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.20), lineWidth: 0.8)
                    )

                Circle()
                    .fill(.black.opacity(0.055))
                    .frame(width: 158, height: 158)
                    .blur(radius: 1)

                Chart(segments) { segment in
                    SectorMark(
                        angle: .value("Tokens", segment.value),
                        innerRadius: .ratio(0.64),
                        angularInset: 2.8
                    )
                    .foregroundStyle(colorMap[segment.colorName] ?? .gray)
                    .cornerRadius(5)
                }
                .chartBackground { _ in
                    Color.clear
                }
                .frame(width: 242, height: 242)
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

                VStack(spacing: 3) {
                    Text(NumberFormatterUtil.format(totalTokens))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Total Tokens")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .frame(width: 130)
            }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorMap[segment.colorName] ?? .gray)
                            .frame(width: 11, height: 11)
                            .overlay(
                                Circle()
                                    .stroke(.white.opacity(0.35), lineWidth: 0.5)
                            )

                        Text(segment.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.82))

                        Spacer(minLength: 8)

                        Text(NumberFormatterUtil.format(segment.value))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))

                        Text(percentage(of: segment.value))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                            .frame(width: 46, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.035))
                    )
                }
            }
            .frame(width: 286)
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
