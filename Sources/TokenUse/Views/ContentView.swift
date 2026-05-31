import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState.shared

    var body: some View {
        TokenDashboardContent(appState: appState, showsHandle: false)
            .frame(width: 644, height: 718)
    }
}

struct TokenDashboardContent: View {
    @ObservedObject var appState: AppState
    let showsHandle: Bool
    var refreshAction: (() -> Void)?

    var body: some View {
        ZStack {
            // Layer 1: NSVisualEffectView (.hudWindow)
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Layer 2: rgba(96,118,164,.42) blue-tinted glass fill
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.376, green: 0.463, blue: 0.643).opacity(0.42),
                            Color(.sRGB, red: 0.376, green: 0.463, blue: 0.643).opacity(0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            // Layer 3: white highlight gradient
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.22),
                            .white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            // Layer 4: white .28 stroke border
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle (only for panel)
                if showsHandle {
                    Capsule()
                        .fill(.white.opacity(0.30))
                        .frame(width: 36, height: 4)
                        .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
                        .padding(.top, 8)
                }

                // Header — 47pt bolt icon, 24px title, 34×34 buttons
                HStack(spacing: 12) {
                    // Blue bolt icon — spec: 47×47, gradient #6CA2FF→#356DEB
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(.sRGB, red: 0.424, green: 0.635, blue: 1.0),
                                        Color(.sRGB, red: 0.208, green: 0.427, blue: 0.922)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 47, height: 47)
                            .shadow(color: Color(.sRGB, red: 0.078, green: 0.176, blue: 0.392).opacity(0.35), radius: 6, x: 0, y: 3)

                        Image(systemName: "bolt.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TokenUse")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(appState.isLoading ? "Refreshing usage" : "Model usage")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Spacer()

                    // Buttons — spec: 34×34, glass background
                    HStack(spacing: 8) {
                        // Refresh button
                        Button {
                            if let refreshAction {
                                refreshAction()
                            } else {
                                Task { await appState.refresh() }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(appState.isLoading ? .white.opacity(0.30) : .white.opacity(0.65))
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(0.16),
                                                    .white.opacity(0.06)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(.white.opacity(0.24), lineWidth: 0.7)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Refresh now")
                        .disabled(appState.isLoading)

                        // Close button — spec: xmark, NSApp.terminate(nil)
                        Button {
                            NSApp.terminate(nil)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(0.16),
                                                    .white.opacity(0.06)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(.white.opacity(0.24), lineWidth: 0.7)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Quit TokenUse")
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, showsHandle ? 6 : 25)
                .padding(.bottom, 12)

                // Divider line — spec: 590pt width, rgba(255,255,255,.13)
                Rectangle()
                    .fill(.white.opacity(0.13))
                    .frame(width: 590, height: 1)
                    .padding(.bottom, 8)

                if let stats = appState.stats {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            // Left: Donut + Legend + Updated timestamp
                            VStack(alignment: .leading, spacing: 12) {
                                DonutChartView(
                                    segments: stats.topSegments,
                                    totalTokens: stats.allTime.totalTokens
                                )

                                // Updated timestamp — spec: yyyy-MM-dd HH:mm:ss UTC+8
                                HStack(spacing: 6) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.84))
                                    Text(formattedTime(stats.updatedAt))
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.84))
                                }
                                .lineLimit(1)

                                Text("* 数据均来源于tokscale。使用 LiteLLM 的定价数据获取实时定价计算，支持分级定价模型和缓存代币折扣。")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 320)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 26)
                            .padding(.top, 10)

                            // Right: Stat cards — spec: 268pt width
                            VStack(spacing: 10) {
                                MetricCard(
                                    title: "All Time",
                                    value: NumberFormatterUtil.format(stats.allTime.totalTokens),
                                    cost: NumberFormatterUtil.formatCurrency(stats.allTime.totalCost),
                                    isLarge: true
                                )
                                MetricCard(
                                    title: "Today",
                                    value: NumberFormatterUtil.format(stats.today.totalTokens),
                                    cost: NumberFormatterUtil.formatCurrency(stats.today.totalCost),
                                    isLarge: false
                                )
                            }
                            .frame(width: 268)
                            .position(x: geo.size.width - 160, y: geo.size.height / 2 - 90)

                            // Mascot — spec: 286×271 area, fixed position bottom-right
                            WorkingMascotView()
                                .frame(width: 286, height: 271)
                                .position(x: geo.size.width - 143, y: geo.size.height - 136)
                                .allowsHitTesting(false)
                        }
                    }
                } else if let error = appState.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Button("Retry") {
                            Task { await appState.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .frame(width: 580, height: 500)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text(appState.statusMessage)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: 580, height: 500)
                }
            }
        }
    }

    /// spec: yyyy-MM-dd HH:mm:ss UTC+8
    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}

// MARK: - WorkingMascotView

private struct WorkingMascotView: View {
    @State private var mascotImage: NSImage?

    var body: some View {
        Group {
            if let image = mascotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
            } else {
                Color.clear
                    .frame(width: 88, height: 88)
                    .onAppear { loadMascot() }
            }
        }
    }

    private func loadMascot() {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png", subdirectory: "TokenUse_TokenUse.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TokenUse_TokenUse.bundle/working-mascot.png"),
        ]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) {
                mascotImage = image
                return
            }
        }
    }
}

// MARK: - VisualEffectView

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 28
        view.layer?.cornerCurve = .continuous
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
