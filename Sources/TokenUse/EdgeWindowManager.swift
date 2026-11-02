import AppKit
import SwiftUI
import Combine

enum DockEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case left = "left"
    case right = "right"
    case top = "top"
    case bottom = "bottom"

    var id: String { rawValue }

    static let horizontalEdges: [DockEdge] = [.left, .right]

    var displayName: String {
        switch self {
        case .left: return "贴靠左侧"
        case .right: return "贴靠右侧"
        case .top: return "顶部"
        case .bottom: return "底部"
        }
    }

    var iconName: String {
        switch self {
        case .left: return "sidebar.left"
        case .right: return "sidebar.right"
        case .top: return "menubar.rectangle"
        case .bottom: return "dock.rectangle"
        }
    }

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
    @Published var isDragging = false
    @Published var activeEdge: DockEdge = .right
    private init() {}
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 支持鼠标直接按住拖动与右键快捷定位的边缘侧边栏悬浮窗（不抢占当前前台应用焦点）
@MainActor
private final class DraggableTriggerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var dragStartMouse: NSPoint = .zero
    private var dragGrabOffset: NSPoint = .zero
    private var isTrackingLeftPress: Bool = false
    private var didExceedDragThreshold: Bool = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let mouse = NSEvent.mouseLocation
            dragStartMouse = mouse
            dragGrabOffset = NSPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
            isTrackingLeftPress = true
            didExceedDragThreshold = false
            EdgeWindowManager.shared.prepareDockPress()
            return

        case .leftMouseDragged:
            guard isTrackingLeftPress else {
                super.sendEvent(event)
                return
            }
            let mouse = NSEvent.mouseLocation
            if !didExceedDragThreshold {
                let dist = hypot(mouse.x - dragStartMouse.x, mouse.y - dragStartMouse.y)
                guard dist >= 3.0 else { return }
                didExceedDragThreshold = true
                NSCursor.closedHand.push()
                EdgeWindowManager.shared.beginDockDrag()
            }
            EdgeWindowManager.shared.updateDockDrag(mouseLocation: mouse, grabOffset: dragGrabOffset)
            return

        case .leftMouseUp:
            guard isTrackingLeftPress else {
                super.sendEvent(event)
                return
            }
            isTrackingLeftPress = false
            if didExceedDragThreshold {
                didExceedDragThreshold = false
                NSCursor.pop()
                EdgeWindowManager.shared.endDockDrag(mouseLocation: NSEvent.mouseLocation)
            } else {
                EdgeWindowManager.shared.handleDockClick()
            }
            return

        case .rightMouseDown:
            if let view = contentView {
                let menu = EdgeWindowManager.shared.buildDockContextMenu()
                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
final class EdgeWindowManager: NSObject, ObservableObject {
    static let shared = EdgeWindowManager()

    private var window: NSPanel?
    private var triggerView: NSWindow?
    private var isVisible = false
    private var edge: DockEdge = .right
    private let triggerWidth: CGFloat = 50
    private let triggerHeight: CGFloat = 244
    private let verticalMargin: CGFloat = 8
    private let magneticSnapDistance: CGFloat = 96
    private let panelWidth: CGFloat = 644
    private let panelHeight: CGFloat = 670
    private let panelEdgeInset: CGFloat = 60
    private let showDelay: TimeInterval = 0.10
    private let hideDelay: TimeInterval = 0.3

    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    private var isPressingDock = false
    private var isDraggingDock = false
    private var isUpdatingSettingsFromDrag = false
    private var suppressHoverOpenUntil: Date = .distantPast

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
        let initialEdge = SettingsManager.shared.dockEdge
        self.edge = initialEdge
        TriggerState.shared.activeEdge = initialEdge

        createTriggerWindow()
        createPanelWindow()
        startMouseMonitoring()
        observeScreenChanges()
        observeSettingsChanges()
    }

    // MARK: - Screen Resolution Helpers

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func targetScreen() -> NSScreen? {
        if let savedID = SettingsManager.shared.dockScreenID,
           let matched = NSScreen.screens.first(where: { Self.displayID(for: $0) == savedID }) {
            return matched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func computedTriggerRect(on screen: NSScreen, edge: DockEdge, verticalRatio: Double) -> NSRect {
        let screenFrame = screen.visibleFrame
        let clampedRatio = min(1.0, max(0.0, verticalRatio))
        let minY = screenFrame.minY + verticalMargin
        let maxY = max(minY, screenFrame.maxY - triggerHeight - verticalMargin)
        let y = minY + CGFloat(1.0 - clampedRatio) * (maxY - minY)

        switch edge {
        case .right:
            return NSRect(
                x: screenFrame.maxX - triggerWidth,
                y: y,
                width: triggerWidth,
                height: triggerHeight
            )
        case .left:
            return NSRect(
                x: screenFrame.minX,
                y: y,
                width: triggerWidth,
                height: triggerHeight
            )
        case .top:
            return NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.maxY - triggerWidth,
                width: triggerHeight,
                height: triggerWidth
            )
        case .bottom:
            return NSRect(
                x: screenFrame.midX - triggerHeight / 2,
                y: screenFrame.minY,
                width: triggerHeight,
                height: triggerWidth
            )
        }
    }

    /// 让滑出主面板垂直方向跟随侧边栏中心高度（并严格钳制在屏幕可视安全边界内，确保鼠标水平移入主面板永不落空）
    private func alignedPanelY(in screenFrame: NSRect, triggerRect: NSRect) -> CGFloat {
        let idealY = triggerRect.midY - panelHeight / 2
        let minY = screenFrame.minY + 10
        let maxY = max(minY, screenFrame.maxY - panelHeight - 10)
        return min(max(idealY, minY), maxY)
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
        guard let screen = targetScreen() else { return }
        let triggerRect = computedTriggerRect(
            on: screen,
            edge: edge,
            verticalRatio: SettingsManager.shared.dockVerticalRatio
        )

        let trigger = DraggableTriggerPanel(
            contentRect: triggerRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        trigger.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        trigger.appearance = NSAppearance(named: .darkAqua)
        trigger.backgroundColor = .clear
        trigger.isOpaque = false
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = false
        trigger.isMovable = false
        trigger.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hostingView = NSHostingView(rootView: TriggerIndicator())
        hostingView.frame = trigger.contentView?.bounds ?? triggerRect
        hostingView.autoresizingMask = [.width, .height]
        trigger.contentView = hostingView

        self.triggerView = trigger
        trigger.orderFront(nil)
    }

    // MARK: - Positioning

    private func positionPanelHidden() {
        guard let window, let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        let tRect = triggerView?.frame ?? computedTriggerRect(
            on: screen,
            edge: edge,
            verticalRatio: SettingsManager.shared.dockVerticalRatio
        )
        let panelY = alignedPanelY(in: frame, triggerRect: tRect)

        let targetRect: NSRect
        switch edge {
        case .right:
            targetRect = NSRect(
                x: frame.maxX,
                y: panelY,
                width: panelWidth,
                height: panelHeight
            )
        case .left:
            targetRect = NSRect(
                x: frame.minX - panelWidth,
                y: panelY,
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
                y: frame.minY - panelHeight,
                width: panelWidth,
                height: panelHeight
            )
        }

        window.setFrame(targetRect, display: true, animate: false)
    }

    private func positionPanelVisible(animated: Bool = true) {
        guard let window, let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        let tRect = triggerView?.frame ?? computedTriggerRect(
            on: screen,
            edge: edge,
            verticalRatio: SettingsManager.shared.dockVerticalRatio
        )
        let panelY = alignedPanelY(in: frame, triggerRect: tRect)

        let targetRect: NSRect
        switch edge {
        case .right:
            targetRect = NSRect(
                x: max(frame.minX, frame.maxX - panelWidth - panelEdgeInset),
                y: panelY,
                width: panelWidth,
                height: panelHeight
            )
        case .left:
            targetRect = NSRect(
                x: min(frame.maxX - panelWidth, frame.minX + panelEdgeInset),
                y: panelY,
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

        window.setFrame(targetRect, display: true, animate: animated)
    }

    // MARK: - Drag & Context Menu Handling

    fileprivate func prepareDockPress() {
        isPressingDock = true
        cancelShowTimer()
        cancelHideTimer()
    }

    fileprivate func beginDockDrag() {
        isDraggingDock = true
        TriggerState.shared.isDragging = true
        TriggerState.shared.isHovered = true
        cancelShowTimer()
        cancelHideTimer()

        if isVisible && !isModalPresenting && !isPinned {
            isVisible = false
            positionPanelHidden()
            window?.orderOut(nil)
        }
    }

    fileprivate func updateDockDrag(mouseLocation: NSPoint, grabOffset: NSPoint) {
        guard let triggerView,
              let screen = screenContaining(point: mouseLocation) ?? targetScreen() else {
            return
        }
        let vf = screen.visibleFrame
        let minY = vf.minY + verticalMargin
        let maxY = max(minY, vf.maxY - triggerHeight - verticalMargin)
        let clampedY = min(max(mouseLocation.y - grabOffset.y, minY), maxY)

        let liveEdge: DockEdge = (mouseLocation.x < vf.midX) ? .left : .right
        if TriggerState.shared.activeEdge != liveEdge {
            TriggerState.shared.activeEdge = liveEdge
        }

        let targetX: CGFloat
        if mouseLocation.x - vf.minX <= magneticSnapDistance {
            targetX = vf.minX
        } else if vf.maxX - mouseLocation.x <= magneticSnapDistance {
            targetX = vf.maxX - triggerWidth
        } else {
            let rawX = mouseLocation.x - grabOffset.x
            targetX = min(max(rawX, vf.minX), vf.maxX - triggerWidth)
        }

        triggerView.setFrameOrigin(NSPoint(x: targetX, y: clampedY))
        if isVisible {
            edge = liveEdge
            positionPanelVisible(animated: false)
        }
    }

    fileprivate func endDockDrag(mouseLocation: NSPoint) {
        isPressingDock = false
        isDraggingDock = false
        TriggerState.shared.isDragging = false
        suppressHoverOpenUntil = Date().addingTimeInterval(0.28)

        guard let triggerView,
              let screen = screenContaining(point: mouseLocation) ?? targetScreen() else {
            return
        }

        let vf = screen.visibleFrame
        let finalEdge: DockEdge = (mouseLocation.x < vf.midX) ? .left : .right
        let minY = vf.minY + verticalMargin
        let maxY = max(minY, vf.maxY - triggerHeight - verticalMargin)
        let clampedY = min(max(triggerView.frame.origin.y, minY), maxY)
        let travel = maxY - minY
        let finalRatio: Double = travel > 0
            ? min(1.0, max(0.0, 1.0 - Double((clampedY - minY) / travel)))
            : 0.5

        edge = finalEdge
        TriggerState.shared.activeEdge = finalEdge

        isUpdatingSettingsFromDrag = true
        let settings = SettingsManager.shared
        settings.dockScreenID = Self.displayID(for: screen)
        settings.dockEdge = finalEdge
        settings.dockVerticalRatio = finalRatio
        isUpdatingSettingsFromDrag = false

        let snappedRect = computedTriggerRect(on: screen, edge: finalEdge, verticalRatio: finalRatio)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            triggerView.animator().setFrame(snappedRect, display: true)
        }

        if isVisible {
            positionPanelVisible(animated: true)
        } else {
            positionPanelHidden()
        }
    }

    fileprivate func handleDockClick() {
        isPressingDock = false
        if isVisible && !isPinned && !isModalPresenting {
            performHide()
        } else {
            showPanel()
        }
    }

    fileprivate func buildDockContextMenu() -> NSMenu {
        let menu = NSMenu(title: "侧边栏位置")
        let settings = SettingsManager.shared

        let leftItem = NSMenuItem(title: "贴靠屏幕左侧", action: #selector(selectDockLeft), keyEquivalent: "")
        leftItem.target = self
        leftItem.state = (settings.dockEdge == .left) ? .on : .off
        menu.addItem(leftItem)

        let rightItem = NSMenuItem(title: "贴靠屏幕右侧", action: #selector(selectDockRight), keyEquivalent: "")
        rightItem.target = self
        rightItem.state = (settings.dockEdge == .right) ? .on : .off
        menu.addItem(rightItem)

        menu.addItem(.separator())

        let presets: [(String, Double)] = [
            ("移至顶部", 0.05),
            ("移至偏上", 0.25),
            ("垂直居中", 0.50),
            ("移至偏下", 0.75),
            ("移至底部", 0.95),
        ]
        for (title, ratio) in presets {
            let item = NSMenuItem(title: title, action: #selector(selectVerticalPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: ratio)
            if abs(settings.dockVerticalRatio - ratio) < 0.06 {
                item.state = .on
            }
            menu.addItem(item)
        }

        if !settings.isDefaultDockPosition {
            menu.addItem(.separator())
            let resetItem = NSMenuItem(title: "恢复默认位置（右侧居中）", action: #selector(resetDockToDefault), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
        }

        return menu
    }

    @objc private func selectDockLeft() {
        SettingsManager.shared.dockEdge = .left
    }

    @objc private func selectDockRight() {
        SettingsManager.shared.dockEdge = .right
    }

    @objc private func selectVerticalPreset(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        SettingsManager.shared.dockVerticalRatio = num.doubleValue
    }

    @objc private func resetDockToDefault() {
        SettingsManager.shared.resetDockPosition()
    }

    // MARK: - Show / Hide

    private func scheduleShowPanel() {
        cancelHideTimer()
        guard !isVisible, !isPressingDock, !isDraggingDock else { return }
        guard Date() >= suppressHoverOpenUntil else { return }
        guard showTimer == nil else { return }

        showTimer = Timer.scheduledTimer(withTimeInterval: showDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showTimer = nil
                guard !self.isPressingDock, !self.isDraggingDock else { return }
                self.showPanel()
            }
        }
    }

    private func cancelShowTimer() {
        showTimer?.invalidate()
        showTimer = nil
    }

    func showPanel() {
        cancelShowTimer()
        cancelHideTimer()
        guard !isDraggingDock else { return }
        guard !isVisible else { return }
        positionPanelHidden()
        isVisible = true

        window?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            positionPanelVisible(animated: true)
        }
    }

    func hidePanel() {
        cancelShowTimer()
        guard isVisible, !isPinned, !isModalPresenting, !isDraggingDock else { return }

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
        guard isVisible, !isPinned, !isModalPresenting, !isDraggingDock else { return }
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

    // MARK: - Screen, Settings & Mouse Monitoring

    private func observeSettingsChanges() {
        let settings = SettingsManager.shared

        settings.$dockEdge
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newEdge in
                guard let self, !self.isUpdatingSettingsFromDrag, !self.isDraggingDock else { return }
                self.edge = newEdge
                TriggerState.shared.activeEdge = newEdge
                self.repositionTriggerWindow(animated: true)
                if self.isVisible {
                    self.positionPanelVisible(animated: true)
                } else {
                    self.positionPanelHidden()
                }
            }
            .store(in: &cancellables)

        settings.$dockVerticalRatio
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isUpdatingSettingsFromDrag, !self.isDraggingDock else { return }
                self.repositionTriggerWindow(animated: false)
                if self.isVisible {
                    self.positionPanelVisible(animated: false)
                } else {
                    self.positionPanelHidden()
                }
            }
            .store(in: &cancellables)

        settings.$dockScreenID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isUpdatingSettingsFromDrag, !self.isDraggingDock else { return }
                self.repositionTriggerWindow(animated: true)
                if self.isVisible {
                    self.positionPanelVisible(animated: true)
                } else {
                    self.positionPanelHidden()
                }
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.repositionTriggerWindow(animated: false)
                if self.isVisible {
                    self.positionPanelVisible(animated: false)
                } else {
                    self.positionPanelHidden()
                }
            }
        }
    }

    private func repositionTriggerWindow(animated: Bool = false) {
        guard let triggerView, let screen = targetScreen() else { return }
        let triggerRect = computedTriggerRect(
            on: screen,
            edge: edge,
            verticalRatio: SettingsManager.shared.dockVerticalRatio
        )
        triggerView.setFrame(triggerRect, display: true, animate: animated)
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
        guard !isDraggingDock, !isPressingDock else { return }
        let mouseLoc = NSEvent.mouseLocation
        guard let screen = targetScreen() else { return }
        let frame = screen.visibleFrame

        let isInTriggerZone = isMouseInTriggerZone(mouseLoc, frame: frame)
        let isInPanel = isVisible && isMouseInPanel(mouseLoc)

        if isInTriggerZone {
            TriggerState.shared.isHovered = true
            scheduleShowPanel()
        } else if isInPanel {
            TriggerState.shared.isHovered = false
            cancelHideTimer()
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
        let expanded = frame.insetBy(dx: -12, dy: -10)
        return expanded.contains(mouseLoc)
    }
}

// MARK: - TriggerIndicator (Frosted Edge Dock with Live Provider Quota Rings)

struct TriggerIndicator: View {
    @StateObject private var state = TriggerState.shared
    @StateObject private var appState = AppState.shared

    var body: some View {
        ZStack {
            switch state.activeEdge {
            case .right:
                HStack {
                    Spacer(minLength: 0)
                    TriggerCapsuleWithArrow(
                        edge: .right,
                        isHovered: state.isHovered || state.isDragging,
                        isDragging: state.isDragging,
                        isVertical: true,
                        dashboard: appState.dashboard
                    )
                    .padding(.trailing, 2)
                }
            case .left:
                HStack {
                    TriggerCapsuleWithArrow(
                        edge: .left,
                        isHovered: state.isHovered || state.isDragging,
                        isDragging: state.isDragging,
                        isVertical: true,
                        dashboard: appState.dashboard
                    )
                    .padding(.leading, 2)
                    Spacer(minLength: 0)
                }
            case .top:
                VStack {
                    TriggerCapsuleWithArrow(
                        edge: .top,
                        isHovered: state.isHovered || state.isDragging,
                        isDragging: state.isDragging,
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
                        edge: .bottom,
                        isHovered: state.isHovered || state.isDragging,
                        isDragging: state.isDragging,
                        isVertical: false,
                        dashboard: appState.dashboard
                    )
                    .padding(.bottom, 2)
                }
            }
        }
        .help("按住可自由拖动到屏幕左/右侧或上下任意高度 · 右键可快捷定位")
    }
}

private struct TriggerCapsuleWithArrow: View {
    let edge: DockEdge
    let isHovered: Bool
    let isDragging: Bool
    let isVertical: Bool
    let dashboard: MultiAccountDashboard?
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared

    private var todayText: String {
        NumberFormatterUtil.formatCompact(dashboard?.totalTodayTokens ?? 0)
    }

    private var chevronIconName: String {
        edge == .left ? "chevron.right" : "chevron.left"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isHovered
                            ? [
                                Color(.sRGB, red: 0.25, green: 0.34, blue: 0.56).opacity(0.94),
                                Color(.sRGB, red: 0.16, green: 0.22, blue: 0.40).opacity(0.96),
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
                        .stroke(
                            isDragging
                                ? Color.cyan.opacity(0.75)
                                : .white.opacity(isHovered ? 0.42 : 0.18),
                            lineWidth: isDragging ? 1.1 : 0.7
                        )
                )
                .shadow(color: .black.opacity(isHovered ? 0.30 : 0.16), radius: isDragging ? 10 : 6, x: 0, y: 2)
                .shadow(
                    color: Color(.sRGB, red: 0.357, green: 0.522, blue: 1.0).opacity(isHovered ? 0.48 : 0.10),
                    radius: isHovered ? 14 : 5
                )

            if isVertical {
                VStack(spacing: 5) {
                    // 顶部微缩抓手指示条（提示支持按住拖动）
                    Capsule()
                        .fill(.white.opacity(isHovered ? 0.52 : 0.22))
                        .frame(width: 14, height: 2.5)
                        .padding(.bottom, 1)

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
                        ForEach(settings.providerOrder) { provider in
                            let group = dashboard?.providers.first { $0.provider == provider }
                            EdgeDockProviderGauge(
                                provider: provider,
                                group: group,
                                isActiveSession: activityMonitor.activeProviders.contains(provider)
                            )
                        }
                    }

                    Image(systemName: chevronIconName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.90 : 0.45))
                        .padding(.top, 1)
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 6) {
                    Text(todayText)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    ForEach(settings.providerOrder) { provider in
                        let group = dashboard?.providers.first { $0.provider == provider }
                        EdgeDockProviderGauge(
                            provider: provider,
                            group: group,
                            isActiveSession: activityMonitor.activeProviders.contains(provider)
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(width: isVertical ? 42 : 232, height: isVertical ? 232 : 42)
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isDragging)
    }
}

private struct EdgeDockProviderGauge: View {
    let provider: TrackedProvider
    let group: ProviderGroupSnapshot?
    let isActiveSession: Bool

    private var remainingPercent: Double? {
        group?.representativeRemainingPercent
    }

    private var hasAnyActivity: Bool {
        if isActiveSession { return true }
        guard let group else { return false }
        return !group.accounts.isEmpty || group.allTimeTokens > 0
    }

    private var activeRingColor: Color {
        if let rem = remainingPercent {
            return ringColor(for: rem)
        }
        return provider.accentColor
    }

    var body: some View {
        ZStack {
            if isActiveSession {
                Circle()
                    .stroke(activeRingColor.opacity(0.26), lineWidth: 2.1)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let period = 1.15
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    let angle = phase * 360.0

                    Circle()
                        .trim(from: 0.0, to: 0.72)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: activeRingColor.opacity(0.04), location: 0.0),
                                    .init(color: activeRingColor.opacity(0.88), location: 0.54),
                                    .init(color: .white.opacity(0.96), location: 0.71),
                                    .init(color: .clear, location: 0.73),
                                ]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.35, lineCap: .round)
                        )
                        .rotationEffect(.degrees(angle - 90.0))
                        .shadow(color: activeRingColor.opacity(0.55), radius: 3.0)
                }
            } else {
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
            }

            ProviderBrandIcon(provider: provider, size: 12.5, cornerRadius: 3)
                .opacity(hasAnyActivity ? 0.98 : 0.42)
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
