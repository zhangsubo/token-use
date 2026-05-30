import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let cost: String
    var isLarge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title — spec: 21px regular, white 0.74
            Text(title)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))

            // Main number — spec: 45px semibold rounded, white
            Text(value)
                .font(.system(size: isLarge ? 45 : 38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            // Cost pill — spec: "$" 18pt + cost 20pt semibold, #D8F0D7 bg, #4D5E4A text
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(cost)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(Color(.sRGB, red: 0.302, green: 0.369, blue: 0.290)) // #4D5E4A
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(.sRGB, red: 0.847, green: 0.941, blue: 0.843)) // #D8F0D7
            )

            Spacer(minLength: 0)
        }
        // spec: top 27, leading 40, trailing 20, bottom 16
        .padding(.top, 27)
        .padding(.leading, 40)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .frame(width: 268, height: isLarge ? 180 : 179, alignment: .topLeading)
        // spec: bg white 0.08→0.03, stroke white 0.15, shadow
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.08),
                            .white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color(.sRGB, red: 0.094, green: 0.118, blue: 0.212).opacity(0.22), radius: 30, x: 0, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }
}
