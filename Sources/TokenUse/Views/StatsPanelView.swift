import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let cost: String
    var isLarge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))

            Text(value)
                .font(.system(size: isLarge ? 38 : 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(cost)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(Color(.sRGB, red: 0.27, green: 0.38, blue: 0.28))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.sRGB, red: 0.86, green: 0.96, blue: 0.84),
                                Color(.sRGB, red: 0.74, green: 0.89, blue: 0.73)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.55), lineWidth: 0.7)
                    )
            )

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .frame(width: 252, height: isLarge ? 160 : 154, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.13),
                            .white.opacity(0.055),
                            .white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color(.sRGB, red: 0.094, green: 0.118, blue: 0.212).opacity(0.18), radius: 22, x: 0, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
        )
    }
}
