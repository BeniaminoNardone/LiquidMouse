import CoreGraphics
import Testing
@testable import LiquidMouse

@Suite struct ButtonProbeStateTests {
    private let a = ButtonProbeState.Target(location: CGPoint(x: 10, y: 20), application: 1)
    private let b = ButtonProbeState.Target(location: CGPoint(x: 40, y: 20), application: 1)

    @Test func delayedAnswersCannotFollowThePointerOrSurviveARoundTrip() throws {
        var state = ButtonProbeState()
        state.observe(a)
        let request = try #require(state.request(now: 0))
        state.didRequest(request, now: 0)
        state.observe(b)
        do { let accepted = state.accept(true, for: request); #expect(!accepted) }
        state.observe(a)
        do { let accepted = state.accept(true, for: request); #expect(!accepted) }
        #expect(!state.overClickable)
    }

    @Test func stationaryContentIsRecheckedWithoutFloodingTheOtherApp() throws {
        var state = ButtonProbeState()
        state.observe(a)
        let first = try #require(state.request(now: 0))
        state.didRequest(first, now: 0)
        do { let accepted = state.accept(true, for: first); #expect(accepted) }
        #expect(state.request(now: 0.49) == nil)
        let next = try #require(state.request(now: 0.5))
        state.didRequest(next, now: 0.5)
        do { let accepted = state.accept(false, for: next); #expect(accepted) }
        #expect(!state.overClickable)
    }

    @Test func movementIsThrottledAndSkippedRequestsAreRetried() throws {
        var state = ButtonProbeState()
        state.observe(a)
        state.didRequest(try #require(state.request(now: 0)), now: 0)
        state.observe(b)
        #expect(state.request(now: 0.02) == nil)
        #expect(state.request(now: 0.04) != nil)
        // Transport busy: no didRequest. The final position is still eligible on the next frame.
        #expect(state.request(now: 0.05) != nil)
    }

    @Test func switchingAppsAndLosingEligibilityClearTheOldAnswer() throws {
        var state = ButtonProbeState()
        state.observe(a)
        let request = try #require(state.request(now: 0))
        do { let accepted = state.accept(true, for: request); #expect(accepted) }
        state.observe(.init(location: a.location, application: 2))
        #expect(!state.overClickable)
        do { let accepted = state.accept(true, for: request); #expect(!accepted) }
        let other = try #require(state.request(now: 1))
        do { let accepted = state.accept(true, for: other); #expect(accepted) }
        state.observe(nil) // Permission revoked, own window, disabled engine or a non-arrow cursor.
        #expect(!state.overClickable)
        do { let accepted = state.accept(true, for: other); #expect(!accepted) }
        #expect(state.request(now: 2) == nil)
    }

    @Test func invalidationAndTimeoutDoNotLeaveAButtonStuck() throws {
        var state = ButtonProbeState()
        state.observe(a)
        let request = try #require(state.request(now: 0))
        do { let accepted = state.accept(true, for: request); #expect(accepted) }
        do { let accepted = state.accept(nil, for: request); #expect(accepted) }
        #expect(!state.overClickable)
        state.invalidate()
        state.observe(a)
        do { let accepted = state.accept(true, for: request); #expect(!accepted) }
        #expect(state.request(now: 0.01) != nil)
    }
}
