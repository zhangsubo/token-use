import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var customIntervalText: String = ""
    @State private var isCustomInterval: Bool = false
    @State private var previewImage: NSImage?
    @State private var isImportingMascot = false

    private let intervalOptions: [(String, TimeInterval)] = [
        ("5 分钟", 300),
        ("10 分钟", 600),
        ("30 分钟", 1800),
        ("自定义", -1),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("设置")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(.white.opacity(0.12))
                                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(.white.opacity(0.13))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    mascotSection
                    refreshSection
                    updateSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
        }
        .frame(width: 400, height: 480)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        )
        .onAppear {
            setupIntervalState()
        }
    }

    // MARK: - Mascot Section

    private var mascotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("吉祥物图片")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Text("推荐尺寸 286 × 271 px，支持 PNG 格式")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 16) {
                Group {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 8) {
                    Button("上传图片") { openFilePicker() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isImportingMascot)

                    if settings.customMascotPath != nil {
                        Button("恢复默认") {
                            settings.resetMascot()
                            refreshPreviewImage()
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Refresh Interval Section

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据刷新间隔")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(intervalOptions, id: \.1) { option in
                    let isSelected = isCustomInterval
                        ? option.1 == -1
                        : settings.refreshInterval == option.1

                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.4))

                        Text(option.0)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.7))

                        if option.1 == -1 && isCustomInterval {
                            TextField("分钟", text: $customIntervalText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .font(.system(size: 13))
                                .onSubmit { applyCustomInterval() }
                                .onChange(of: customIntervalText) { _, _ in applyCustomInterval() }
                            Text("分钟")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if option.1 == -1 {
                            isCustomInterval = true
                            applyCustomInterval()
                        } else {
                            isCustomInterval = false
                            settings.refreshInterval = option.1
                        }
                        AppState.shared.restartTimer()
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow.opacity(0.7))
                Text("不建议设置过于频繁的刷新间隔，可能影响系统性能。")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Auto Update Section

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动更新")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.7))
                Text("当前版本：v\(currentVersion)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Toggle("启动后自动检查更新", isOn: $settings.enableAutoUpdate)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let last = settings.lastUpdateCheckDate {
                Text("上次检查：\(Self.relativeDate(last))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.checkForUpdates()
            } label: {
                Label("立即检查更新", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Text("新版本将通过 Sparkle 安全下载并自动替换。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Helpers

    /// 当前 .app 的 CFBundleShortVersionString。读不到时回退 "0.0.0"。
    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// 相对时间本地化（"3 分钟前"），避免每次设置页打开时 DateFormatter 重型格式化
    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func setupIntervalState() {
        let current = settings.refreshInterval
        let matched = intervalOptions.first { $0.1 == current && $0.1 != -1 }
        if matched == nil {
            isCustomInterval = true
            customIntervalText = String(Int(current / 60))
        }
        refreshPreviewImage()
    }

    private func applyCustomInterval() {
        guard let minutes = Double(customIntervalText), minutes > 0 else { return }
        settings.refreshInterval = minutes * 60
        AppState.shared.restartTimer()
    }

    private func openFilePicker() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "选择吉祥物图片"
        panel.message = "请选择用于右下角展示的 PNG 或 GIF 图片"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isImportingMascot = true
            let dest = appSupportMascotURL(for: url)

            Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)

                    await MainActor.run {
                        settings.customMascotPath = dest.path
                        refreshPreviewImage()
                        isImportingMascot = false
                    }
                } catch {
                    await MainActor.run {
                        isImportingMascot = false
                    }
                }
            }
        }
    }

    private func appSupportMascotURL(for source: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ext = source.pathExtension.lowercased() == "gif" ? "gif" : "png"
        return appSupport.appendingPathComponent("TokenUse/mascot-custom.\(ext)")
    }

    private func refreshPreviewImage() {
        if let customImage = settings.customMascotImage {
            previewImage = customImage
        } else {
            previewImage = loadDefaultMascot()
        }
    }

    private func loadDefaultMascot() -> NSImage? {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png"),
            Bundle.main.url(forResource: "working-mascot", withExtension: "png", subdirectory: "TokenUse_TokenUse.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TokenUse_TokenUse.bundle/working-mascot.png"),
        ]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}
