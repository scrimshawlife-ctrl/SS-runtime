import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ExtractionCountdownTests {
    private func extractCenter(_ sim: Simulation) -> VecI {
        sim.state.arena.extraction.center
    }

    private func outsideExtraction(_ sim: Simulation) -> VecI {
        let region = sim.state.arena.extraction
        return VecI(x: region.center.x, y: region.center.y + region.halfSize.y + 64)
    }

    @Test func extractionT703ALockedRegionDoesNotCountDown() throws {
        var sim = try Simulation.make(seed: 1)
        let countdown = sim.state.arena.extraction.countdownTicks
        sim.testing_setPlayerPosition(extractCenter(sim))
        var countdownEvents = 0
        for tick in 1...10 {
            let result = sim.step(command: .neutral(tick: UInt64(tick)))
            countdownEvents += result.events.filter { $0.type == .extractionCountdownChanged }.count
        }
        #expect(!sim.state.extraction.armed)
        #expect(sim.state.extraction.remaining == countdown)
        #expect(countdownEvents == 0)
    }

    @Test func extractionT703AArmsWhenCombatGraphComplete() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        let result = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.extraction.armed)
        #expect(result.events.contains(where: { $0.type == .extractionArmed }))
    }

    @Test func extractionAR008LeaveResetsAndReenterResumes() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let countdown = sim.state.arena.extraction.countdownTicks
        sim.testing_setPlayerPosition(extractCenter(sim))
        for tick in 2...300 {
            _ = sim.step(command: .neutral(tick: UInt64(tick)))
        }
        #expect(sim.state.extraction.remaining == 1)
        sim.testing_setPlayerPosition(outsideExtraction(sim))
        let reset = sim.step(command: .neutral(tick: 301))
        #expect(sim.state.extraction.remaining == countdown)
        let resetEvent = reset.events.first(where: { $0.type == .extractionReset })
        #expect(resetEvent != nil)
        if case .integer(let previous)? = resetEvent?.payload["previousRemainingTicks"] {
            #expect(previous == 1)
        } else {
            Issue.record("expected previousRemainingTicks payload")
        }
        sim.testing_setPlayerPosition(extractCenter(sim))
        _ = sim.step(command: .neutral(tick: 302))
        #expect(sim.state.extraction.remaining == countdown - 1)
    }

    @Test func extractionUI006LeaveAtOneTickResetsDisplayedSeconds() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armExtraction()
        let countdown = sim.state.arena.extraction.countdownTicks
        sim.testing_setPlayerPosition(extractCenter(sim))
        sim.testing_setExtractionRemaining(1)
        sim.testing_setExtractionWasInside(true)
        sim.testing_setPlayerPosition(outsideExtraction(sim))
        let result = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.extraction.remaining == countdown)
        #expect(HUDLayout.extractionSeconds(sim.state.extraction.remaining) == 5)
        #expect(result.events.contains(where: { $0.type == .extractionReset }))
    }

    @Test func extractionAR009LethalDamageBeatsExtractionSuccess() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armExtraction()
        sim.testing_setPlayerPosition(extractCenter(sim))
        sim.testing_setExtractionRemaining(1)
        // D-090: a 10-damage bolt removes 5 Integrity, so 5 is lethal.
        sim.testing_setPlayerIntegrity(5)
        sim.testing_injectHostileBolt(damage: 10)
        let result = sim.step(command: .neutral(tick: 1))
        #expect(result.outcome == .failure)
        #expect(result.events.contains(where: { $0.type == .runSucceeded }) == false)
    }

    @Test func extractionT703AArmedOutsideRegionDoesNotTick() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armExtraction()
        let countdown = sim.state.arena.extraction.countdownTicks
        sim.testing_setPlayerPosition(outsideExtraction(sim))
        for tick in 1...5 {
            _ = sim.step(command: .neutral(tick: UInt64(tick)))
        }
        #expect(sim.state.extraction.remaining == countdown)
    }
}
