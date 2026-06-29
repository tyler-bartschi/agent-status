import Combine
import Foundation

/// Owns normalized session state. All mutation occurs on the main actor so UI
/// consumers can observe it without additional synchronization.
@MainActor
public final class SessionStore: ObservableObject {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TransitionHandler = @MainActor (SessionTransition) -> Void

    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var displayState: AggregateDisplayState?

    public var onTransition: TransitionHandler?

    private let finishedDuration: Duration
    private let sleep: Sleep
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var lastEvents: [String: SessionEvent] = [:]
    private var revisions: [String: UInt64] = [:]

    public init(
        finishedDuration: Duration = .seconds(3),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        onTransition: TransitionHandler? = nil
    ) {
        self.finishedDuration = finishedDuration
        self.sleep = sleep
        self.onTransition = onTransition
    }

    /// Applies an event and returns whether observable session state changed.
    ///
    /// Repeating the exact last normalized event for a session is ignored.
    /// An `ended` event is treated as completion and therefore remains visible
    /// as Finished for the configured duration; `idle` removes the session
    /// immediately without a completion transition.
    @discardableResult
    public func process(_ event: SessionEvent) -> Bool {
        guard lastEvents[event.sessionID] != event else {
            return false
        }

        lastEvents[event.sessionID] = event
        expiryTasks[event.sessionID]?.cancel()
        expiryTasks[event.sessionID] = nil

        let previousSession = sessions.first { $0.sessionID == event.sessionID }
        let previousStatus = previousSession?.status
        let revision = nextRevision(for: event.sessionID)

        guard event.activity != .idle else {
            let changed = removeSession(id: event.sessionID)
            publishAggregate()
            return changed
        }

        let status = status(for: event.activity)
        let session = AgentSession(
            sessionID: event.sessionID,
            host: event.host,
            name: event.name,
            status: status,
            revision: revision
        )
        upsert(session)
        publishAggregate()

        if status != previousStatus, status == .waiting || status == .finished {
            onTransition?(
                SessionTransition(
                    sessionID: session.sessionID,
                    host: session.host,
                    name: session.name,
                    previousStatus: previousStatus,
                    status: status
                )
            )
        }

        if status == .finished {
            scheduleExpiry(for: session.sessionID, revision: revision)
        }

        return session != previousSession
    }

    public func session(id: String) -> AgentSession? {
        sessions.first { $0.sessionID == id }
    }

    private func status(for activity: SessionEvent.Activity) -> SessionStatus {
        switch activity {
        case .working:
            .working
        case .waiting:
            .waiting
        case .finished, .ended:
            .finished
        case .idle:
            // `process` handles idle before asking for a displayable status.
            preconditionFailure("Idle has no active session status")
        }
    }

    private func nextRevision(for sessionID: String) -> UInt64 {
        let next = (revisions[sessionID] ?? 0) &+ 1
        revisions[sessionID] = next
        return next
    }

    private func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.sessionID == session.sessionID }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.sessionID.localizedStandardCompare($1.sessionID) == .orderedAscending }
    }

    @discardableResult
    private func removeSession(id: String) -> Bool {
        let originalCount = sessions.count
        sessions.removeAll { $0.sessionID == id }
        return sessions.count != originalCount
    }

    private func publishAggregate() {
        guard let displayedStatus = sessions
            .map(\.status)
            .max(by: { $0.displayPriority < $1.displayPriority })
        else {
            displayState = nil
            return
        }

        displayState = AggregateDisplayState(
            status: displayedStatus,
            count: sessions.lazy.filter { $0.status == displayedStatus }.count
        )
    }

    private func scheduleExpiry(for sessionID: String, revision: UInt64) {
        let sleep = sleep
        let duration = finishedDuration

        expiryTasks[sessionID] = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.expireFinishedSession(id: sessionID, revision: revision)
        }
    }

    private func expireFinishedSession(id: String, revision: UInt64) {
        guard
            let session = session(id: id),
            session.status == .finished,
            session.revision == revision
        else {
            return
        }

        expiryTasks[id] = nil
        removeSession(id: id)
        publishAggregate()
    }
}
