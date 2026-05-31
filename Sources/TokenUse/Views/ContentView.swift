import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState.shared

    var body: some View {
        TokenDashboardContent(appState: appState, showsHandle: false)
            .frame(width: 644, height: 670)
    }
}

struct TokenDashboardContent: View {
    @ObservedObject var appState: AppState
    @State private var showSettings = false
    let showsHandle: Bool
    var refreshAction: (() -> Void)?

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.43, green: 0.50, blue: 0.66).opacity(0.38),
                            Color(.sRGB, red: 0.25, green: 0.31, blue: 0.47).opacity(0.46)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.24),
                            .white.opacity(0.07),
                            .black.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.10), .black.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(0.5)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
                .padding(8)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showsHandle {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: 32, height: 3)
                        .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
                        .padding(.top, 8)
                }

                HStack(spacing: 12) {
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
                            .frame(width: 42, height: 42)
                            .overlay(
                                Circle()
                                    .stroke(.white.opacity(0.32), lineWidth: 0.8)
                            )
                            .shadow(color: Color(.sRGB, red: 0.078, green: 0.176, blue: 0.392).opacity(0.28), radius: 8, x: 0, y: 4)

                        Image(systemName: "bolt.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("TokenUse")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(appState.isLoading ? "Refreshing usage" : "Model usage")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.66))
                    }

                    Spacer()

                    HStack(spacing: 7) {
                        HeaderActionButton(
                            systemName: "arrow.clockwise",
                            help: "Refresh now",
                            isDisabled: appState.isLoading
                        ) {
                            if let refreshAction {
                                refreshAction()
                            } else {
                                Task { await appState.refresh() }
                            }
                        }

                        HeaderActionButton(systemName: "gearshape", help: "Settings") {
                            showSettings = true
                        }
                        .sheet(isPresented: $showSettings) {
                            SettingsView()
                        }

                        HeaderActionButton(systemName: "xmark", help: "Quit TokenUse", role: .close) {
                            NSApp.terminate(nil)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, showsHandle ? 8 : 25)
                .padding(.bottom, 14)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.16), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 590, height: 1)
                    .padding(.bottom, 14)

                if let stats = appState.stats {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            // Left: Donut + Legend + Updated timestamp
                            VStack(alignment: .leading, spacing: 12) {
                                DonutChartView(
                                    segments: stats.topSegments,
                                    totalTokens: stats.allTime.totalTokens
                                )

                                FooterStatusView(updatedText: formattedTime(stats.updatedAt))
                            }
                            .padding(.leading, 26)
                            .padding(.top, 6)

                            VStack(spacing: 8) {
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

                                Spacer(minLength: 0)

                                WorkingMascotView()
                                    .frame(width: 228, height: 212)
                                    .opacity(0.96)
                                    .allowsHitTesting(false)
                            }
                            .frame(width: 268)
                            .frame(height: 540, alignment: .top)
                            .position(x: geo.size.width - 148, y: 276)
                        }
                    }
                } else if let error = appState.errorMessage {
                    EmptyStateCard {
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
                    EmptyStateCard {
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

private enum HeaderButtonRole {
    case normal
    case close
}

private struct HeaderActionButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    var role: HeaderButtonRole = .normal
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isHovered ? 0.22 : 0.13),
                                    .white.opacity(isHovered ? 0.10 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(isHovered ? 0.34 : 0.20), lineWidth: 0.7)
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: isHovered ? 8 : 5, x: 0, y: 3)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isDisabled {
            return .white.opacity(0.28)
        }
        if role == .close && isHovered {
            return Color(.sRGB, red: 1.0, green: 0.58, blue: 0.56).opacity(0.92)
        }
        return .white.opacity(isHovered ? 0.90 : 0.66)
    }
}

private struct FooterStatusView: View {
    let updatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .medium))
                Text(updatedText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.76))
            .lineLimit(1)

            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                (Text("* 数据均来源于").font(.system(size: 11, weight: .regular)) +
                 Text("tokscale").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.7)) +
                 Text("。使用 LiteLLM 的定价数据获取实时定价计算，支持分级定价模型和缓存代币折扣。").font(.system(size: 11, weight: .regular)))
                    .onTapGesture {
                        if let url = URL(string: "https://github.com/junhoyeo/tokscale") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.white.opacity(0.42))
            }
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 0.7)
                )
        )
        .frame(width: 320, alignment: .leading)
    }
}

private struct EmptyStateCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - WorkingMascotView

private struct WorkingMascotView: View {
    @State private var mascotURL: URL?
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Group {
            if let url = mascotURL {
                AnimatedImageView(url: url)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                    .id(url.path)
            } else {
                Color.clear
                    .frame(width: 286, height: 271)
                    .onAppear { loadMascot() }
            }
        }
        .onChange(of: settings.customMascotPath) { _, _ in loadMascot() }
    }

    private func loadMascot() {
        // Try custom image first
        if let path = settings.customMascotPath, FileManager.default.fileExists(atPath: path) {
            mascotURL = URL(fileURLWithPath: path)
            return
        }
        // Fall back to bundle default
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png", subdirectory: "TokenUse_TokenUse.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TokenUse_TokenUse.bundle/working-mascot.png"),
        ]
        for case let url? in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                mascotURL = url
                return
            }
        }
    }
}

// MARK: - AnimatedImageView (NSImageView wrapper for GIF animation)

private let mascotTargetSize = CGSize(width: 286, height: 271)

private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> GIFImageView {
        let view = GIFImageView()
        view.targetSize = mascotTargetSize
        view.imageURL = url
        return view
    }

    func updateNSView(_ nsView: GIFImageView, context: Context) {
        nsView.imageURL = url
    }
}

/// NSImageView: GIF uses native scaling (preserves animation),
/// PNG redraws into exact targetSize canvas (shortest-edge fit, centered).
private class GIFImageView: NSImageView {
    var targetSize: CGSize = mascotTargetSize
    var imageURL: URL? {
        didSet { reloadImage() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: mascotTargetSize))
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func reloadImage() {
        guard let url = imageURL, let data = try? Data(contentsOf: url) else {
            image = nil
            return
        }
        let isGIF = url.pathExtension.lowercased() == "gif"
        if isGIF {
            // GIF: native scaling preserves animation frames
            let img = NSImage(data: data)
            img?.matchesOnMultipleResolution = false
            imageScaling = .scaleProportionallyUpOrDown
            image = img
        } else {
            // PNG: redraw into exact targetSize canvas
            guard let original = NSImage(data: data) else { image = nil; return }
            let origSize = original.size
            guard origSize.width > 0, origSize.height > 0 else { image = original; return }
            let scaleX = targetSize.width / origSize.width
            let scaleY = targetSize.height / origSize.height
            let scale = min(scaleX, scaleY)
            let scaledW = origSize.width * scale
            let scaledH = origSize.height * scale
            let compositor = NSImage(size: targetSize, flipped: false) { rect in
                let drawRect = NSRect(
                    x: (rect.width - scaledW) / 2,
                    y: (rect.height - scaledH) / 2,
                    width: scaledW,
                    height: scaledH
                )
                original.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            compositor.matchesOnMultipleResolution = false
            imageScaling = .scaleNone
            image = compositor
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
