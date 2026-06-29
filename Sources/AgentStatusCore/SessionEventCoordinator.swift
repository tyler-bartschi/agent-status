import Foundation

/// Orders provider events before they enter the session state machine.
///
/// Providers can emit an idle/input Notification or question-like Stop shortly
/// before a terminal completion event. Debouncing those ambiguous Waiting
/// events avoids a transient state and sound while still surfacing genuine
/// input requests after a short delay.
@MainActor
public final class SessionEventCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let store: SessionStore
    private let notificationDelay: Duration
    private let sleep: Sleep
    private var pendingNotifications: [String: Task<Void, Never>] = [:]

    public init(
        store: SessionStore,
        notificationDelay: Duration = .milliseconds(1_250),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.store = store
        self.notificationDelay = notificationDelay
        self.sleep = sleep
    }

    public func receive(_ event: SessionEvent) {
        let key = event.sessionID
        pendingNotifications[key]?.cancel()
        pendingNotifications[key] = nil

        guard shouldDebounce(event) else {
            store.process(event)
            return
        }
        guard store.session(matching: event)?.status != .finished else {
            return
        }

        let delay = notificationDelay
        let sleep = sleep
        pendingNotifications[key] = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self?.store.session(matching: event)?.status != .finished else {
                self?.pendingNotifications[key] = nil
                return
            }

            self?.pendingNotifications[key] = nil
            self?.store.process(event)
        }
    }

    public func cancelPendingEvents() {
        for task in pendingNotifications.values {
            task.cancel()
        }
        pendingNotifications.removeAll()
    }

    private func shouldDebounce(_ event: SessionEvent) -> Bool {
        guard event.activity == .waiting, let sourceEvent = event.sourceEvent else {
            return false
        }
        let normalizedEvent = sourceEvent
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return ["notification", "stop", "stopfailure"].contains(normalizedEvent)
    }
}
