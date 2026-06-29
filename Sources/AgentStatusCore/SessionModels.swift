import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case working
    case waiting
    case finished

    /// Larger values take precedence in the compact aggregate display.
    public var displayPriority: Int {
        switch self {
        case .working: 0
        case .waiting: 1
        case .finished: 2
        }
    }
}

/// A normalized event produced by any host-specific integration.
public struct SessionEvent: Codable, Equatable, Hashable, Sendable {
    public enum Activity: String, Codable, CaseIterable, Hashable, Sendable {
        case working
        case waiting
        case finished
        /// The host is inactive without having completed a task.
        case idle
        /// The host completed a task or ended its turn.
        case ended
    }

    public let sessionID: String
    public let host: HostApplication
    public let name: String?
    public let activity: Activity

    public init(
        sessionID: String,
        host: HostApplication,
        name: String? = nil,
        activity: Activity
    ) {
        self.sessionID = sessionID
        self.host = host
        self.name = name
        self.activity = activity
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { sessionID }

    public let sessionID: String
    public var host: HostApplication
    public var name: String?
    public var status: SessionStatus

    /// Monotonically increases for this session ID. Expiry jobs use it to
    /// recognize that a newer event superseded their work.
    public internal(set) var revision: UInt64

    public init(
        sessionID: String,
        host: HostApplication,
        name: String? = nil,
        status: SessionStatus,
        revision: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.host = host
        self.name = name
        self.status = status
        self.revision = revision
    }
}

/// The single state rendered around the notch. `nil` means there is no
/// indicator to render.
public struct AggregateDisplayState: Codable, Equatable, Hashable, Sendable {
    public let status: SessionStatus
    public let count: Int

    public init(status: SessionStatus, count: Int) {
        precondition(count > 0, "An aggregate display state must contain a session")
        self.status = status
        self.count = count
    }
}

public struct SessionTransition: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let host: HostApplication
    public let name: String?
    public let previousStatus: SessionStatus?
    public let status: SessionStatus

    public init(
        sessionID: String,
        host: HostApplication,
        name: String?,
        previousStatus: SessionStatus?,
        status: SessionStatus
    ) {
        self.sessionID = sessionID
        self.host = host
        self.name = name
        self.previousStatus = previousStatus
        self.status = status
    }
}
