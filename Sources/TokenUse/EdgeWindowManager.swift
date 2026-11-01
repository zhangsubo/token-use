import AppKit
import SwiftUI
import Combine

enum DockEdge {
    case left, right, top, bottom

    var screenEdge: NSRectEdge {
        switch self {
        case .left: return .minX
        case .right: return .maxX
        case .top: return .maxY
        case .bottom: return .minY
        }
    }
}

@MainActor
final class TriggerState: ObservableObject {
    static let shared = TriggerState()
    @Published var isHovered = false
    private init() {}
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class EdgeWindowManager: NSObject, ObservableObject {
    static let shared = EdgeWindowManager()

    private var window: NSPanel?
    private var triggerView: NSWindow?
    private var isVisible = false
    private var edge: DockEdge = .right
    private let triggerWidth: CGFloat = 50
    private let triggerHeight: CGFloat = 236
    private let panelWidth: CGFloat = 644
    private let panelHeight: CGFloat = 670
    private let panelEdgeInset: CGFloat = 60
    private let hideDelay: TimeInterval = 0.3

    private var hideTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    /// 当设置弹窗 / 登录窗口打开或用户固定面板时，阻止鼠标移出自动收起
    @Published var isPinned: Bool = false
    var isModalPresenting: Bool = false {
        didSet {
            if isModalPresenting {
                cancelHideTimer()
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private override init() {
        super.init()
    }

    func setup() {
        createTriggerWindow()
        createPanelWindow()
        startMouseMonitoring()
        observeScreenChanges()
    }

    // MARK: - Window Creation

    private func createPanelWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hostingView = NSHostingView(rootView: EdgeContentView(manager: self))
        panel.contentView = hostingView

        self.window = panel
        positionPanelHidden()
    }

    private func createTriggerWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        let triggerRect: NSRect
        switch edge {
        case .right:
            triggerRect = NSRect(
                x: screenFrame.maxX - triggerWidth,
                y: screenFrame.midY - triggerHeight / 2,
                width: triggerWidth,
                height: triggerHeight
            )
        case .left:
            triggerRect = NSRect(
                x: screenFrame.minX,
                y: screenFrame.midY - triggerHeight / 2,
                width: triggerWidth,
                height: triggerHeight
            )
        case .top:
            triggerRect = NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.maxY - triggerWidth,
                width: triggerHeight,
                height: triggerWidth
            )
        case .bottom:
            triggerRect = NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.minY,
                width: triggerHeight,
                height: triggerWidth
            )
        }

        let trigger = NSPanel(
            contentRect: triggerRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        trigger.level = .floating
        trigger.appearance = NSAppearance(named: .darkAqua)
        trigger.backgroundColor = .clear
        trigger.isOpaque = false
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = true
        trigger.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hostingView = NSHostingView(rootView: TriggerIndicator(edge: edge))
        hostingView.frame = trigger.contentView?.bounds ?? triggerRect
        hostingView.autoresizingMask = [.width, .height]
        trigger.contentView = hostingView

        self.triggerView = trigger
        trigger.orderFront(nil)
    }

    // MARK: - Positioning

    private func positionPanelHidden() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame

        var targetRect: NSRect
        switch edge {
        case .right:
            targetRect = NSRect(
                x: frame.maxX,
                y: frame.midY - panelHeight / 2,
                width: panelWidth,
                height: panelHeight
            )
        case .left:
            targetRect = NSRect(
                x: -panelWidth,
                y: frame.midY - panelHeight / 2,
                width: panelWidth,
                height: panelHeight
            )
        case .top:
            targetRect = NSRect(
                x: frame.midX - panelWidth / 2,
                y: frame.maxY,
                width: panelWidth,
                height: panelHeight
            )
        case .bottom:
            targetRect = NSRect(
                x: frame.midX - panelWidth / 2,
                y: -panelHeight,
                width: panelWidth,
                height: panelHeight
            )
        }

        window.setFrame(targetRect, display: true, animate: false)
    }

    private func positionPanelVisible() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame

        var targetRect: NSRect
        switch edge {
        case .right:
            targetRect = NSRect(
                x: max(frame.minX, frame.maxX - panelWidth - panelEdgeInset),
                y: frame.midY - panelHeight / 2,
                width: panelWidth,
                height: panelHeight
            )
        case .left:
            targetRect = NSRect(
                x: min(frame.maxX - panelWidth, frame.minX + panelEdgeInset),
                y: frame.midY - panelHeight / 2,
                width: panelWidth,
                height: panelHeight
            )
        case .top:
            targetRect = NSRect(
                x: frame.midX - panelWidth / 2,
                y: frame.maxY - panelHeight,
                width: panelWidth,
                height: panelHeight
            )
        case .bottom:
            targetRect = NSRect(
                x: frame.midX - panelWidth / 2,
                y: frame.minY,
                width: panelWidth,
                height: panelHeight
            )
        }

        window.setFrame(targetRect, display: true, animate: true)
    }

    // MARK: - Show / Hide

    func showPanel() {
        cancelHideTimer()
        guard !isVisible else { return }
        isVisible = true

        window?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            positionPanelVisible()
        }
    }

    func hidePanel() {
        guard isVisible, !isPinned, !isModalPresenting else { return }

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.performHide()
            }
        }
    }

    func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func performHide() {
        guard isVisible, !isPinned, !isModalPresenting else { return }
        isVisible = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            positionPanelHidden()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.window?.orderOut(nil)
            }
        }
    }

    // MARK: - Screen & Mouse Monitoring

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.repositionTriggerWindow()
                if self.isVisible {
                    self.positionPanelVisible()
                } else {
                    self.positionPanelHidden()
                }
            }
        }
    }

    private func repositionTriggerWindow() {
        guard let triggerView, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let triggerRect: NSRect
        switch edge {
        case .right:
            triggerRect = NSRect(
                x: screenFrame.maxX - triggerWidth,
                y: screenFrame.midY - triggerHeight / 2,
                width: triggerWidth,
                height: triggerHeight
            )
        case .left:
            triggerRect = NSRect(
                x: screenFrame.minX,
                y: screenFrame.midY - triggerHeight / 2,
                width: triggerWidth,
                height: triggerHeight
            )
        case .top:
            triggerRect = NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.maxY - triggerWidth,
                width: triggerHeight,
                height: triggerWidth
            )
        case .bottom:
            triggerRect = NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.minY,
                width: triggerHeight,
                height: triggerWidth
            )
        }
        triggerView.setFrame(triggerRect, display: true)
    }

    private func startMouseMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleMouseMove()
            }
        }

        // Also monitor when mouse is over our own window
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in
                self.handleMouseMove()
            }
            return event
        }
    }

    private func handleMouseMove() {
        let mouseLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame

        let isInTriggerZone = isMouseInTriggerZone(mouseLoc, frame: frame)
        let isInPanel = isMouseInPanel(mouseLoc)

        if isInTriggerZone {
            TriggerState.shared.isHovered = true
            showPanel()
        } else if isInPanel {
            TriggerState.shared.isHovered = false
            showPanel()
        } else {
            TriggerState.shared.isHovered = false
            hidePanel()
        }
    }

    private func isMouseInTriggerZone(_ mouseLoc: NSPoint, frame: NSRect) -> Bool {
        guard let triggerFrame = triggerView?.frame else { return false }
        let margin: CGFloat = 5
        let expanded = triggerFrame.insetBy(dx: -margin, dy: -margin)
        return expanded.contains(mouseLoc)
    }

    private func isMouseInPanel(_ mouseLoc: NSPoint) -> Bool {
        guard let window else { return false }
        let frame = window.frame
        let expanded = frame.insetBy(dx: -10, dy: -10)
        return expanded.contains(mouseLoc)
    }
}

// MARK: - TriggerIndicator (Frosted Edge Dock with Live Provider Quota Rings)

struct TriggerIndicator: View {
    let edge: DockEdge
    @StateObject private var state = TriggerState.shared
    @StateObject private var appState = AppState.shared

    var body: some View {
        ZStack {
            switch edge {
            case .right:
                HStack {
                    Spacer(minLength: 0)
                    TriggerCapsuleWithArrow(
                        isHovered: state.isHovered,
                        isVertical: true,
                        dashboard: appState.dashboard
                    )
                    .padding(.trailing, 2)
                }
            case .left:
                HStack {
                    TriggerCapsuleWithArrow(
                        isHovered: state.isHovered,
                        isVertical: true,
                        dashboard: appState.dashboard
                    )
                    .padding(.leading, 2)
                    Spacer(minLength: 0)
                }
            case .top:
                VStack {
                    TriggerCapsuleWithArrow(
                        isHovered: state.isHovered,
                        isVertical: false,
                        dashboard: appState.dashboard
                    )
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                }
            case .bottom:
                VStack {
                    Spacer(minLength: 0)
                    TriggerCapsuleWithArrow(
                        isHovered: state.isHovered,
                        isVertical: false,
                        dashboard: appState.dashboard
                    )
                    .padding(.bottom, 2)
                }
            }
        }
    }
}

private struct TriggerCapsuleWithArrow: View {
    let isHovered: Bool
    let isVertical: Bool
    let dashboard: MultiAccountDashboard?

    private var todayText: String {
        NumberFormatterUtil.formatCompact(dashboard?.totalTodayTokens ?? 0)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isHovered
                            ? [
                                Color(.sRGB, red: 0.25, green: 0.34, blue: 0.56).opacity(0.92),
                                Color(.sRGB, red: 0.16, green: 0.22, blue: 0.40).opacity(0.94),
                            ]
                            : [
                                Color(.sRGB, red: 0.20, green: 0.26, blue: 0.42).opacity(0.76),
                                Color(.sRGB, red: 0.12, green: 0.16, blue: 0.28).opacity(0.80),
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isHovered ? 0.22 : 0.12),
                                    .white.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .stroke(.white.opacity(isHovered ? 0.42 : 0.18), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: 6, x: 0, y: 2)
                .shadow(
                    color: Color(.sRGB, red: 0.357, green: 0.522, blue: 1.0).opacity(isHovered ? 0.48 : 0.10),
                    radius: isHovered ? 14 : 5
                )

            if isVertical {
                VStack(spacing: 5.5) {
                    VStack(spacing: 0.5) {
                        Text("TODAY")
                            .font(.system(size: 6.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.46))
                        Text(todayText)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 3)

                    Rectangle()
                        .fill(.white.opacity(0.14))
                        .frame(width: 24, height: 0.7)

                    VStack(spacing: 5.5) {
                        ForEach(TrackedProvider.allCases) { provider in
                            let group = dashboard?.providers.first { $0.provider == provider }
                            EdgeDockProviderGauge(provider: provider, group: group)
                        }
                    }

                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.90 : 0.45))
                        .padding(.top, 1)
                }
                .padding(.vertical, 9)
            } else {
                HStack(spacing: 6) {
                    Text(todayText)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    ForEach(TrackedProvider.allCases) { provider in
                        let group = dashboard?.providers.first { $0.provider == provider }
                        EdgeDockProviderGauge(provider: provider, group: group)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(width: isVertical ? 42 : 224, height: isVertical ? 224 : 42)
    }
}

private struct EdgeDockProviderGauge: View {
    let provider: TrackedProvider
    let group: ProviderGroupSnapshot?

    private var remainingPercent: Double? {
        group?.representativeRemainingPercent
    }

    private var hasAnyActivity: Bool {
        guard let group else { return false }
        return !group.accounts.isEmpty || group.allTimeTokens > 0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(hasAnyActivity ? 0.15 : 0.08), lineWidth: 2.1)

            if let rem = remainingPercent {
                if rem <= 0 {
                    Circle()
                        .stroke(Color(.sRGB, red: 1.0, green: 0.36, blue: 0.36).opacity(0.55), lineWidth: 2.1)
                } else {
                    Circle()
                        .trim(from: 0, to: min(1.0, max(0.03, rem / 100.0)))
                        .stroke(
                            ringColor(for: rem),
                            style: StrokeStyle(lineWidth: 2.1, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }

            ProviderBrandIcon(provider: provider, size: 12.5, cornerRadius: 3)
                .opacity(hasAnyActivity ? 0.96 : 0.42)
        }
        .frame(width: 24, height: 24)
    }

    private func ringColor(for remaining: Double) -> Color {
        if remaining <= 15 {
            return Color(.sRGB, red: 1.0, green: 0.40, blue: 0.38)
        }
        if remaining <= 35 {
            return Color(.sRGB, red: 1.0, green: 0.72, blue: 0.28)
        }
        return Color(.sRGB, red: 0.34, green: 0.90, blue: 0.66)
    }
}

// MARK: - EdgeContentView

struct EdgeContentView: View {
    let manager: EdgeWindowManager
    @StateObject private var appState = AppState.shared

    var body: some View {
        TokenDashboardContent(
            appState: appState,
            showsHandle: true,
            refreshAction: { Task { await appState.refresh() } }
        )
        .frame(width: 644, height: 670)
        .onHover { hovering in
            if hovering {
                manager.cancelHideTimer()
            } else {
                manager.hidePanel()
            }
        }
    }
}
