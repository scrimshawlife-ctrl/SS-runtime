import Foundation
import Testing
@testable import SurveillanceCore

/// D-101 quiet approach (exposure.md § Quiet approach, EX-013 to EX-016;
/// run-shell.md RS-024). The court restore it pays is in `CourtClimaxTests`
/// (BO-022 to BO-024).
@Suite(.serialized)
struct QuietApproachTests {
    /// A fresh run stepped once with Exposure set to `exposure` first.
    private static func stepped(exposure: Int) throws -> Simulation {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(exposure)
        _ = sim.step(command: .neutral(tick: 1))
        return sim
    }

    /// M-A and M-B complete, Exposure at `exposure`, the Player in M-C's
    /// trigger, stepped once: M-C activates on that tick.
    private static func activateMobC(exposure: Int) throws -> (Simulation, TickResult) {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeEncounter("M-A")
        sim.testing_completeEncounter("M-B")
        sim.testing_setExposure(exposure)
        let trigger = try #require(sim.state.arena.encounterTriggers.first { $0.encounterId == "M-C" })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        let result = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.encounters["M-C"]?.activated == true)
        return (sim, result)
    }

    @Test func aFreshRunStartsQuiet() throws {
        let sim = try Simulation.make(seed: 1)
        #expect(sim.state.exposure.quietApproach)
    }

    @Test func observedKeepsTheQuietApproach() throws {
        let sim = try Self.stepped(exposure: 449)
        #expect(sim.state.exposure.detectionState == .observed)
        #expect(sim.state.exposure.quietApproach)
    }

    @Test func ex013TrackedBeforeMobCClearsIt() throws {
        let sim = try Self.stepped(exposure: 450)
        #expect(sim.state.exposure.detectionState == .tracked)
        #expect(!sim.state.exposure.quietApproach)
    }

    @Test func ex014ItStaysLostAfterRecovery() throws {
        var sim = try Self.stepped(exposure: 700)
        #expect(!sim.state.exposure.quietApproach)
        sim.testing_setExposure(0)
        _ = sim.step(command: .neutral(tick: 2))
        #expect(sim.state.exposure.detectionState == .hidden)
        #expect(!sim.state.exposure.quietApproach)
    }

    @Test func ex015TheForcedLockdownAtMobCNeverCostsIt() throws {
        let (sim, result) = try Self.activateMobC(exposure: 300)
        #expect(result.events.contains { $0.type == .lockdownEntered })
        #expect(sim.state.exposure.detectionState == .lockdown)
        #expect(sim.state.exposure.quietApproach)
    }

    /// From the activation tick on the check no longer runs, even when the
    /// state was already `tracked` coming into that tick's resolution.
    @Test func trackedOnTheActivationTickItselfDoesNotCostIt() throws {
        let (sim, _) = try Self.activateMobC(exposure: 600)
        #expect(sim.state.exposure.quietApproach)
    }

    @Test func ex016TrackedTheTickBeforeMobCClearsIt() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeEncounter("M-A")
        sim.testing_completeEncounter("M-B")
        sim.testing_setExposure(450)
        _ = sim.step(command: .neutral(tick: 1))
        #expect(!sim.state.exposure.quietApproach)
        let trigger = try #require(sim.state.arena.encounterTriggers.first { $0.encounterId == "M-C" })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        _ = sim.step(command: .neutral(tick: 2))
        #expect(sim.state.encounters["M-C"]?.activated == true)
        #expect(!sim.state.exposure.quietApproach)
    }

    @Test func theLatchIsInTheDigest() throws {
        var quiet = try Simulation.make(seed: 1)
        var lost = try Simulation.make(seed: 1)
        lost.testing_setQuietApproach(false)
        #expect(quiet.state.digest() != lost.state.digest())
        quiet.testing_setQuietApproach(false)
        #expect(quiet.state.digest() == lost.state.digest())
    }

    // MARK: - RS-024 GHOST is the latch

    @Test func rs024GhostIsExactlyTheLatch() {
        for quiet in [true, false] {
            var state = MedalTests.success
            state.exposure.quietApproach = quiet
            #expect(MedalTracker().medals(for: state).contains(.ghost) == quiet, "quiet \(quiet)")
        }
    }

    /// The defect D-101 fixes: on M-C's activation tick the forced Lockdown
    /// publishes `detectionStateChanged` (phase 14) before M-C's
    /// `waveStarted` (phase 15). Fed those real events, a quiet run must
    /// still earn `GHOST`.
    @Test func theForcedLockdownEventsAtMobCDoNotCostGhost() throws {
        let (sim, result) = try Self.activateMobC(exposure: 300)
        let types = result.events.map(\.type)
        let lockdown = try #require(types.firstIndex(of: .detectionStateChanged))
        let wave = try #require(types.firstIndex(of: .waveStarted))
        #expect(lockdown < wave, "the ordering that broke the event-based GHOST")
        var tracker = MedalTracker()
        tracker.ingest(result.events)
        var state = MedalTests.success
        state.exposure.quietApproach = sim.state.exposure.quietApproach
        #expect(tracker.medals(for: state).contains(.ghost))
    }
}
