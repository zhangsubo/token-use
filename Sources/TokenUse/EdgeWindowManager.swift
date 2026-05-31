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

@MainActor
final class EdgeWindowManager: NSObject {
    static let shared = EdgeWindowManager()

    private var window: NSWindow?
    private var triggerView: NSWindow?
    private var isVisible = false
    private var edge: DockEdge = .right
    private let triggerWidth: CGFloat = 43
    private let triggerHeight: CGFloat = 157
    private let panelWidth: CGFloat = 644
    private let panelHeight: CGFloat = 718
    private let panelEdgeInset: CGFloat = 78
    private let hideDelay: TimeInterval = 0.3

    private var hideTimer: Timer?
    private var mouseMonitor: Any?

    private override init() {
        super.init()
    }

    func setup() {
        createTriggerWindow()
        createPanelWindow()
        startMouseMonitoring()
    }

    // MARK: - Window Creation

    private func createPanelWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
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
        guard isVisible else { return }

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
        guard isVisible else { return }
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

    // MARK: - Mouse Monitoring

    private func startMouseMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleMouseMove()
            }
        }

        // Also monitor when mouse is over our own window
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
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

// MARK: - TriggerIndicator

struct TriggerIndicator: View {
    let edge: DockEdge
    @StateObject private var state = TriggerState.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                switch edge {
                case .right:
                    HStack {
                        Spacer()
                        TriggerCapsuleWithArrow(isHovered: state.isHovered, isVertical: true)
                            .padding(.trailing, 1)
                    }
                case .left:
                    HStack {
                        TriggerCapsuleWithArrow(isHovered: state.isHovered, isVertical: true)
                            .padding(.leading, 1)
                        Spacer()
                    }
                case .top:
                    VStack {
                        TriggerCapsuleWithArrow(isHovered: state.isHovered, isVertical: false)
                            .padding(.top, 1)
                        Spacer()
                    }
                case .bottom:
                    VStack {
                        Spacer()
                        TriggerCapsuleWithArrow(isHovered: state.isHovered, isVertical: false)
                            .padding(.bottom, 1)
                    }
                }
            }
        }
    }
}

private struct TriggerCapsuleWithArrow: View {
    let isHovered: Bool
    let isVertical: Bool

    var body: some View {
        ZStack {
            // Spec: #5E86FF main, highlight rgba(255,255,255,.55)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: isHovered
                            ? [
                                Color(.sRGB, red: 0.369, green: 0.525, blue: 1.0),    // #5E86FF
                                Color(.sRGB, red: 0.28, green: 0.44, blue: 0.95)
                            ]
                            : [
                                Color(.sRGB, red: 0.369, green: 0.525, blue: 1.0),    // #5E86FF
                                Color(.sRGB, red: 0.28, green: 0.44, blue: 0.95)
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: isVertical ? 43 : 157, height: isVertical ? 157 : 43)
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isHovered ? 0.55 : 0.30),
                                    .white.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: isVertical ? 38 : 152, height: isVertical ? 152 : 38)
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(isHovered ? 0.50 : 0.25), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 1)
                // Outer glow — spec: 0 0 22px rgba(91,133,255,.82)
                .shadow(
                    color: Color(.sRGB, red: 0.357, green: 0.522, blue: 1.0).opacity(isHovered ? 0.82 : 0.35),
                    radius: isHovered ? 22 : 10
                )

            // Arrow — spec: white, ~31px
            Image(systemName: isVertical ? "chevron.left" : "chevron.down")
                .font(.system(size: isVertical ? 31 : 28, weight: .bold))
                .foregroundStyle(.white)
        }
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
        .frame(width: 644, height: 718)
        .onHover { hovering in
            if hovering {
                manager.cancelHideTimer()
            } else {
                manager.hidePanel()
            }
        }
    }
}
