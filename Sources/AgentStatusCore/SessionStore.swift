import Combine
import Foundation

/// Owns normalized session state. All mutation occurs on the main actor so UI
/// consumers can observe it without additional synchronization.
@MainActor
public final class SessionStore: ObservableObject {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias TransitionHandler = @MainActor (SessionTransition) -> Void
    public typealias Now = () -> Date

    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var displayState: AggregateDisplayState?

    public var onTransition: TransitionHandler?

    private let finishedDuration: Duration
    private let sleep: Sleep
    private let now: Now
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var lastEvents: [String: SessionEvent] = [:]
    private var revisions: [String: UInt64] = [:]
    private var aliases: [String: String] = [:]
    private var turnSessions: [TurnIdentity: String] = [:]
    private var lastActivityDates: [String: Date] = [:]
    private var processIDs: [String: Int32] = [:]

    public init(
        finishedDuration: Duration = .seconds(3),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping Now = Date.init,
        onTransition: TransitionHandler? = nil
    ) {
        self.finishedDuration = finishedDuration
        self.sleep = sleep
        self.now = now
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
        let sessionID = canonicalSessionID(for: event)

        guard lastEvents[sessionID] != event else {
            return false
        }

        lastEvents[sessionID] = event
        lastActivityDates[sessionID] = now()
        if let processID = event.processID {
            processIDs[sessionID] = processID
        }
        expiryTasks[sessionID]?.cancel()
        expiryTasks[sessionID] = nil

        let previousSession = sessions.first { $0.sessionID == sessionID }
        let previousStatus = previousSession?.status
        let revision = nextRevision(for: sessionID)

        guard event.activity != .idle else {
            let changed = removeSession(id: sessionID)
            lastActivityDates[sessionID] = nil
            processIDs[sessionID] = nil
            publishAggregate()
            return changed
        }

        let status = status(for: event.activity)
        let session = AgentSession(
            sessionID: sessionID,
            host: event.host,
            name: event.name ?? previousSession?.name,
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

    public func session(matching event: SessionEvent) -> AgentSession? {
        session(id: canonicalSessionID(for: event))
    }

    /// Removes a session from the display and clears its deduplication state.
    /// A later provider event can therefore make the session appear again.
    @discardableResult
    public func forgetSession(id: String) -> Bool {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
        lastEvents[id] = nil
        lastActivityDates[id] = nil
        processIDs[id] = nil
        aliases = aliases.filter { $0.value != id }
        turnSessions = turnSessions.filter { $0.value != id }

        let changed = removeSession(id: id)
        publishAggregate()
        return changed
    }

    /// Removes stale Working sessions. CLI sessions are removed as soon as
    /// their provider process exits. Desktop sessions (and CLI sessions with
    /// no process metadata) are removed after the inactivity timeout.
    @discardableResult
    public func pruneStaleWorkingSessions(
        inactiveFor timeout: TimeInterval,
        isProcessAlive: (Int32) -> Bool
    ) -> [String] {
        precondition(timeout > 0)
        let cutoff = now().addingTimeInterval(-timeout)
        let staleIDs = sessions.compactMap { session -> String? in
            guard session.status == .working else { return nil }

            if session.host == .codexCLI || session.host == .claudeCLI,
               let processID = processIDs[session.sessionID]
            {
                return isProcessAlive(processID) ? nil : session.sessionID
            }

            guard let lastActivity = lastActivityDates[session.sessionID] else {
                return session.sessionID
            }
            return lastActivity <= cutoff ? session.sessionID : nil
        }

        for id in staleIDs {
            forgetSession(id: id)
        }
        return staleIDs
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

    private func canonicalSessionID(for event: SessionEvent) -> String {
        let aliasKey = "\(event.host.rawValue):\(event.sessionID)"
        let existingAlias = aliases[aliasKey]

        if let turnID = event.turnID {
            let identity = TurnIdentity(host: event.host, turnID: turnID)
            if let existing = turnSessions[identity] {
                aliases[aliasKey] = existing
                return existing
            }
            let canonicalID = existingAlias ?? event.sessionID
            turnSessions[identity] = canonicalID
            aliases[aliasKey] = canonicalID
            return canonicalID
        }

        if let existingAlias {
            return existingAlias
        }

        aliases[aliasKey] = event.sessionID
        return event.sessionID
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
        lastActivityDates[id] = nil
        processIDs[id] = nil
        publishAggregate()
    }
}

private struct TurnIdentity: Hashable {
    let host: HostApplication
    let turnID: String
}
