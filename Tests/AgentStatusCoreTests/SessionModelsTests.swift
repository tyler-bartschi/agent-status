import Foundation
import Testing
@testable import AgentStatusCore

@Suite("Session models")
struct SessionModelsTests {
    @Test func statusPrioritiesMatchDisplayOrder() {
        #expect(SessionStatus.working.displayPriority < SessionStatus.waiting.displayPriority)
        #expect(SessionStatus.waiting.displayPriority < SessionStatus.finished.displayPriority)
    }

    @Test func hostDisplayNamesCoverEverySupportedSurface() {
        #expect(HostApplication.codexDesktop.displayName == "Codex")
        #expect(HostApplication.codexCLI.displayName == "Codex CLI")
        #expect(HostApplication.claudeDesktop.displayName == "Claude")
        #expect(HostApplication.claudeCLI.displayName == "Claude CLI")
    }

    @Test func sessionEventCodableRoundTripIncludesAllActivitiesAndOptionalNames() throws {
        var events = SessionEvent.Activity.allCases.enumerated().map { index, activity in
            SessionEvent(
                sessionID: "session-\(index)",
                host: HostApplication.allCases[index % HostApplication.allCases.count],
                name: index.isMultiple(of: 2) ? "Named session" : nil,
                activity: activity
            )
        }
        events.append(
            SessionEvent(
                sessionID: "metadata",
                host: .codexDesktop,
                name: "Named",
                activity: .working,
                turnID: "turn-1",
                workingDirectory: "/tmp/project",
                processID: 42,
                sourceEvent: "UserPromptSubmit"
            )
        )

        #expect(try roundTrip(events) == events)
    }

    @Test func agentSessionCodableRoundTripPreservesRevisionAndMetadata() throws {
        let session = AgentSession(
            sessionID: "abc",
            host: .claudeDesktop,
            name: "Review implementation",
            status: .waiting,
            revision: UInt64.max
        )

        #expect(try roundTrip(session) == session)
    }

    @Test func aggregateDisplayStateCodableRoundTrip() throws {
        let states = SessionStatus.allCases.map {
            AggregateDisplayState(status: $0, count: 42)
        }

        #expect(try roundTrip(states) == states)
    }

    @Test func hostAndStatusEnumsCodableRoundTripAllCases() throws {
        #expect(try roundTrip(HostApplication.allCases) == HostApplication.allCases)
        #expect(try roundTrip(SessionStatus.allCases) == SessionStatus.allCases)
    }

    @Test func eventDecoderRejectsUnknownActivity() {
        let json = """
        {
          "sessionID": "one",
          "host": "codexCLI",
          "activity": "requestingPermission"
        }
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        }
    }

    @Test func eventDecoderRejectsUnknownHost() {
        let json = """
        {
          "sessionID": "one",
          "host": "unknownDesktop",
          "activity": "working"
        }
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        }
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
