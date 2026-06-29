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
    var interactiveRects: [NSRect] = []

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRects.contains(where: { $0.contains(point) }) else {
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
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

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
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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

        installDismissMonitors()
        updatePanel(sessions: store.sessions, expanded: false)
    }

    func stop() {
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
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
        guard !sessions.isEmpty, let screen = builtInScreen() else {
            if model.isExpanded {
                model.isExpanded = false
            }
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }

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
        container.interactiveRects = [NSRect(origin: .zero, size: frame.size)]
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
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
                self?.collapseIfClickIsOutsidePanel()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.collapseIfClickIsOutsidePanel()
            return event
        }
    }

    private func collapseIfClickIsOutsidePanel() {
        guard model.isExpanded else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        model.isExpanded = false
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
                                .frame(width: 12, height: 12)
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

            if model.isExpanded {
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
                .frame(maxHeight: 260)
                .background(Color.black)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: model.isExpanded ? 12 : 8))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.26),
            value: model.isExpanded
        )
    }

    private var accessibilityStatus: String {
        guard let state = store.displayState else { return "No active sessions" }
        return "\(state.count) \(state.status.displayName.lowercased())"
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
                    .frame(width: 9, height: 9)
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
