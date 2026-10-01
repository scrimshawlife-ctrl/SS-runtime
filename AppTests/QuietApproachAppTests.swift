import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-101 on the real session (UI-009): the session projects the tag from the
/// authoritative latch every tick.
@Suite(.serialized)
@MainActor
struct QuietApproachAppTests {
    @Test func theSessionShowsTheTagWhileTheLatchHolds() {
        let session = GameSession(seed: 1)
        session.step()
        #expect(session.simulation.state.exposure.quietApproach)
        #expect(session.quietFrame.tagVisible)
        #expect(session.quietFrame.caption == nil)
    }
}
