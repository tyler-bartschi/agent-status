import Foundation
import Testing
@testable import AgentStatusCore

/// Covers SessionStore's observable state machine, including aggregate priority,
/// exact-event deduplication, per-session callbacks, and revision-safe expiry.
@MainActor
@Suite("Session store")
struct SessionStoreTests {
    @Test func emptyStoreHasNoSessionsOrDisplayState() {
        let store = SessionStore()

        #expect(store.sessions.isEmpty)
        #expect(store.displayState == nil)
    }

    @Test func workingEventCreatesSessionAndWorkingAggregate() {
        let store = SessionStore()

        let changed = store.process(
            event("one", host: .codexDesktop, name: "Implement feature", activity: .working)
        )

        #expect(changed)
        #expect(
            store.sessions == [
                AgentSession(
                    sessionID: "one",
                    host: .codexDesktop,
                    name: "Implement feature",
                    status: .working,
                    revision: 1
                )
            ]
        )
        #expect(store.displayState == AggregateDisplayState(status: .working, count: 1))
    }

    @Test func displayPriorityIsFinishedThenWaitingThenWorking() {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("working", activity: .working))
        store.process(event("waiting", activity: .waiting))
        #expect(store.displayState == AggregateDisplayState(status: .waiting, count: 1))

        store.process(event("finished", activity: .finished))
        #expect(store.displayState == AggregateDisplayState(status: .finished, count: 1))

        store.process(event("finished", activity: .idle))
        #expect(store.displayState == AggregateDisplayState(status: .waiting, count: 1))

        store.process(event("waiting", activity: .working))
        #expect(store.displayState == AggregateDisplayState(status: .working, count: 2))
    }

    @Test func displayedCountIncludesOnlySessionsAtPrioritizedStatus() {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("working-1", activity: .working))
        store.process(event("working-2", activity: .working))
        store.process(event("waiting-1", activity: .waiting))
        store.process(event("waiting-2", activity: .waiting))
        store.process(event("finished", activity: .finished))

        #expect(store.displayState == AggregateDisplayState(status: .finished, count: 1))

        store.process(event("finished", activity: .idle))
        #expect(store.displayState == AggregateDisplayState(status: .waiting, count: 2))
    }

    @Test func sessionsListRetainsEveryStatusAndSortsBySessionID() {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("z-working", activity: .working))
        store.process(event("a-finished", activity: .finished))
        store.process(event("m-waiting", activity: .waiting))

        #expect(store.sessions.map(\.sessionID) == ["a-finished", "m-waiting", "z-working"])
        #expect(store.sessions.map(\.status) == [.finished, .waiting, .working])
    }

    @Test func waitingAndFinishedCallbacksArePerSessionWhenAggregateDoesNotChange() {
        let sleeper = ManualSleeper()
        var transitions: [SessionTransition] = []
        let store = makeStore(sleeper: sleeper) { transitions.append($0) }

        store.process(event("waiting-1", host: .claudeCLI, name: "First", activity: .waiting))
        store.process(event("waiting-2", host: .codexCLI, name: "Second", activity: .waiting))
        store.process(event("finished-1", host: .claudeDesktop, activity: .finished))
        store.process(event("finished-2", host: .codexDesktop, activity: .ended))

        #expect(transitions.map(\.sessionID) == [
            "waiting-1", "waiting-2", "finished-1", "finished-2"
        ])
        #expect(transitions.map(\.status) == [.waiting, .waiting, .finished, .finished])
        #expect(
            transitions[0] == SessionTransition(
                sessionID: "waiting-1",
                host: .claudeCLI,
                name: "First",
                previousStatus: nil,
                status: .waiting
            )
        )
    }

    @Test func workingTransitionsNeverInvokeSoundCallback() {
        var transitions: [SessionTransition] = []
        let store = SessionStore { transitions.append($0) }

        store.process(event("one", activity: .working))
        store.process(event("one", host: .claudeCLI, activity: .working))
        store.process(event("one", activity: .idle))

        #expect(transitions.isEmpty)
    }

    @Test func exactDuplicateEventIsIgnored() {
        let store = SessionStore()
        var transitions: [SessionTransition] = []
        store.onTransition = { transitions.append($0) }
        let waiting = event("one", host: .codexCLI, name: "Approval", activity: .waiting)

        #expect(store.process(waiting))
        let firstSession = store.session(id: "one")
        #expect(!store.process(waiting))

        #expect(store.session(id: "one") == firstSession)
        #expect(transitions.count == 1)
    }

    @Test func sameStatusWithChangedMetadataUpdatesSessionWithoutCallback() {
        var transitions: [SessionTransition] = []
        let store = SessionStore { transitions.append($0) }
        store.process(event("one", host: .codexCLI, name: "Old", activity: .waiting))

        let changed = store.process(
            event("one", host: .claudeDesktop, name: "New", activity: .waiting)
        )

        #expect(changed)
        #expect(store.session(id: "one")?.host == .claudeDesktop)
        #expect(store.session(id: "one")?.name == "New")
        #expect(store.session(id: "one")?.status == .waiting)
        #expect(store.session(id: "one")?.revision == 2)
        #expect(transitions.count == 1)
    }

    @Test func waitingPersistsWithoutAnExpiryJob() async {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("one", activity: .waiting))
        await settleTasks()

        #expect(sleeper.pendingCount == 0)
        #expect(store.session(id: "one")?.status == .waiting)
    }

    @Test func finishedAndEndedExpireAfterConfiguredThreeSeconds() async {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("finished", activity: .finished))
        store.process(event("ended", activity: .ended))
        await sleeper.waitForPendingCount(2)

        #expect(sleeper.requestedDurations == [.seconds(3), .seconds(3)])
        #expect(store.sessions.count == 2)

        sleeper.resumeAll()
        await settleTasks()

        #expect(store.sessions.isEmpty)
        #expect(store.displayState == nil)
    }

    @Test func newEventPreventsStaleFinishedExpiryFromRemovingSession() async {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("one", activity: .finished))
        await sleeper.waitForPendingCount(1)
        store.process(event("one", name: "Continued", activity: .working))

        sleeper.resumeAll()
        await settleTasks()

        #expect(store.session(id: "one")?.status == .working)
        #expect(store.session(id: "one")?.name == "Continued")
        #expect(store.displayState == AggregateDisplayState(status: .working, count: 1))
    }

    @Test func newFinishedEventDefeatsOlderFinishedExpiry() async {
        let sleeper = ManualSleeper()
        let store = makeStore(sleeper: sleeper)

        store.process(event("one", name: "First", activity: .finished))
        await sleeper.waitForPendingCount(1)
        store.process(event("one", name: "Second", activity: .ended))
        await sleeper.waitForPendingCount(2)

        sleeper.resume(at: 0)
        await settleTasks()
        #expect(store.session(id: "one")?.name == "Second")

        sleeper.resume(at: 1)
        await settleTasks()
        #expect(store.session(id: "one") == nil)
    }

    @Test func idleImmediatelyRemovesSessionWithoutCompletionCallback() {
        var transitions: [SessionTransition] = []
        let store = SessionStore { transitions.append($0) }
        store.process(event("one", activity: .working))

        let changed = store.process(event("one", activity: .idle))

        #expect(changed)
        #expect(store.sessions.isEmpty)
        #expect(store.displayState == nil)
        #expect(transitions.isEmpty)
    }

    @Test func idleForUnknownSessionReportsNoObservableChange() {
        let store = SessionStore()

        #expect(!store.process(event("missing", activity: .idle)))
        #expect(store.sessions.isEmpty)
        #expect(store.displayState == nil)
    }

    private func makeStore(
        sleeper: ManualSleeper,
        onTransition: SessionStore.TransitionHandler? = nil
    ) -> SessionStore {
        SessionStore(
            finishedDuration: .seconds(3),
            sleep: { duration in try await sleeper.sleep(for: duration) },
            onTransition: onTransition
        )
    }

    private func event(
        _ id: String,
        host: HostApplication = .codexDesktop,
        name: String? = nil,
        activity: SessionEvent.Activity
    ) -> SessionEvent {
        SessionEvent(sessionID: id, host: host, name: name, activity: activity)
    }

    private func settleTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private final class ManualSleeper: @unchecked Sendable {
    private struct Request {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
        var resumed = false
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    var pendingCount: Int {
        lock.withLock { requests.filter { !$0.resumed }.count }
    }

    var requestedDurations: [Duration] {
        lock.withLock { requests.map(\.duration) }
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requests.append(Request(duration: duration, continuation: continuation))
            }
        }
    }

    func waitForPendingCount(_ expectedCount: Int) async {
        for _ in 0..<1_000 {
            if lock.withLock({ requests.count >= expectedCount }) {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expectedCount) sleep request(s)")
    }

    func resume(at index: Int) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard requests.indices.contains(index), !requests[index].resumed else {
                return nil
            }
            requests[index].resumed = true
            return requests[index].continuation
        }
        continuation?.resume()
    }

    func resumeAll() {
        let continuations: [CheckedContinuation<Void, Error>] = lock.withLock {
            requests.indices.compactMap { index in
                guard !requests[index].resumed else { return nil }
                requests[index].resumed = true
                return requests[index].continuation
            }
        }
        continuations.forEach { $0.resume() }
    }
}
