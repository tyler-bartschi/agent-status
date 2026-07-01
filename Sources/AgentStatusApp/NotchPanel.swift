import AppKit
import AgentStatusCore
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ConstrainedHitTestView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}

@MainActor
final class NotchPanelController {
    private let store: SessionStore
    private let panel: NotchPanel
    private let container = ConstrainedHitTestView()
    private let model = NotchPresentationModel()
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var visibilityRevision: UInt64 = 0
    private var isFadingOut = false

    private let compactHeight: CGFloat = 34
    private let expandedWidth: CGFloat = 420

    init(store: SessionStore) {
        self.store = store
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.contentView = container

        let root = NotchRootView(store: store, model: model)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func start() {
        store.$sessions
            .combineLatest(model.$isExpanded)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, expanded in
                self?.updatePanel(sessions: sessions, expanded: expanded)
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePanel(sessions: self.store.sessions, expanded: self.model.isExpanded)
            }
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshForActiveSpace()
            }
        }

        installDismissMonitors()
        updatePanel(sessions: store.sessions, expanded: false)
    }

    func stop() {
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        activeSpaceObserver = nil
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        panel.orderOut(nil)
    }

    private func updatePanel(sessions: [AgentSession], expanded: Bool) {
        guard !sessions.isEmpty else {
            if model.isExpanded {
                model.isExpanded = false
                return
            }
            fadeOutPanel()
            return
        }

        guard let screen = builtInScreen() else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }

        visibilityRevision &+= 1
        isFadingOut = false
        panel.alphaValue = 1
        let wasVisible = panel.isVisible
        let notch = notchMetrics(on: screen)
        let isExpanded = expanded && !sessions.isEmpty
        let width = isExpanded ? expandedWidth : notch.width + 108
        let listHeight = min(CGFloat(sessions.count) * 38 + 18, 260)
        let height = compactHeight + (isExpanded ? listHeight : 0)
        let frame = NSRect(
            x: notch.centerX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )

        model.notchWidth = notch.width
        if panel.isVisible,
           panel.frame != frame,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.ignoresMouseEvents = false
        if !wasVisible {
            panel.orderFrontRegardless()
        }
    }

    private func fadeOutPanel() {
        panel.ignoresMouseEvents = true
        guard panel.isVisible else {
            panel.alphaValue = 1
            return
        }
        guard !isFadingOut else { return }

        visibilityRevision &+= 1
        let revision = visibilityRevision
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFadingOut = false
                if self.visibilityRevision == revision {
                    self.panel.orderOut(nil)
                }
                self.panel.alphaValue = 1
            }
        }
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchMetrics(on screen: NSScreen) -> (centerX: CGFloat, width: CGFloat) {
        if
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea,
            right.minX > left.maxX
        {
            return ((left.maxX + right.minX) / 2, right.minX - left.maxX)
        }

        // Non-notched and older displays use a stable top-center affordance.
        return (screen.frame.midX, 140)
    }

    private func installDismissMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.collapseExpandedPanel()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self, event.window !== self.panel {
                self.collapseExpandedPanel()
            }
            return event
        }
    }

    private func collapseExpandedPanel() {
        guard model.isExpanded else { return }
        model.isExpanded = false
    }

    private func refreshForActiveSpace() {
        guard !store.sessions.isEmpty else { return }
        updatePanel(sessions: store.sessions, expanded: model.isExpanded)
        panel.orderFrontRegardless()

        // Fullscreen Space transitions can finish after the workspace
        // notification. Reassert once after the transition settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.store.sessions.isEmpty else { return }
            self.panel.orderFrontRegardless()
        }
    }
}

@MainActor
private final class NotchPresentationModel: ObservableObject {
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 140
}

private struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: NotchPresentationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard !store.sessions.isEmpty else { return }
                model.isExpanded.toggle()
            } label: {
                HStack(spacing: 0) {
                    Group {
                        if let displayState = store.displayState {
                            AnimatedStatusIndicator(status: displayState.status)
                                .frame(width: 14, height: 14)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Color.black
                        .frame(width: model.notchWidth)

                    Group {
                        if let displayState = store.displayState {
                            Text(displayState.count.formatted())
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 34)
                .background(Color.black)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isExpanded ? "Collapse active sessions" : "Show active sessions")
            .accessibilityValue(accessibilityStatus)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sessions) { session in
                        SessionRow(
                            session: session,
                            onForget: {
                                store.forgetSession(id: session.id)
                            }
                        )
                        if session.id != store.sessions.last?.id {
                            Divider().overlay(Color.white.opacity(0.12))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .frame(height: model.isExpanded ? sessionListHeight : 0)
            .background(Color.black)
            .opacity(model.isExpanded ? 1 : 0)
            .allowsHitTesting(model.isExpanded)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: model.isExpanded
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .clipShape(BottomRoundedRectangle(radius: model.isExpanded ? 14 : 10))
    }

    private var accessibilityStatus: String {
        guard let state = store.displayState else { return "No active sessions" }
        return "\(state.count) \(state.status.displayName.lowercased())"
    }

    private var sessionListHeight: CGFloat {
        min(CGFloat(store.sessions.count) * 38 + 18, 260)
    }
}

private struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, min(rect.width / 2, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(session.host.displayName)
                .fontWeight(.semibold)
            if let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty
            {
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: onForget) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Forget this session")
            .accessibilityLabel("Forget \(session.name ?? session.host.displayName) session")
            HStack(spacing: 6) {
                AnimatedStatusIndicator(status: session.status)
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
                Text(session.status.displayName)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .frame(height: 37)
    }
}

private extension SessionStatus {
    var displayName: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting"
        case .finished: "Finished"
        }
    }
}
