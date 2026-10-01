import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct TerminalPrecedenceTests {
    @Test func terminalT704StepAfterFailureReturnsNoEventsAndFreezesTick() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setPlayerIntegrity(0)
        let terminal = sim.step(command: .neutral(tick: 1))
        let tickAtTerminal = sim.state.tick
        #expect(terminal.outcome == .failure)
        for offset in 2...6 {
            let followUp = sim.step(command: .neutral(tick: UInt64(offset)))
            #expect(followUp.events.isEmpty)
            #expect(followUp.outcome == .failure)
            #expect(sim.state.tick == tickAtTerminal)
        }
    }

    @Test func terminalT704StepAfterSuccessReturnsNoEventsAndFreezesTick() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(1)
        let terminal = sim.step(command: .neutral(tick: 2))
        let tickAtTerminal = sim.state.tick
        #expect(terminal.outcome == .success)
        for offset in 3...7 {
            let followUp = sim.step(command: .neutral(tick: UInt64(offset)))
            #expect(followUp.events.isEmpty)
            #expect(followUp.outcome == .success)
            #expect(sim.state.tick == tickAtTerminal)
        }
    }

    @Test func terminalT704ReceiptDigestImmutableAfterTerminal() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_setPlayerIntegrity(0)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        _ = sim.step(command: .neutral(tick: 1))
        let receipt = RunReceipt(sim.state)
        let digest = receipt.finalDigest
        let elapsed = receipt.elapsedTicks
        for offset in 2...5 {
            _ = sim.step(command: .neutral(tick: UInt64(offset)))
        }
        let afterSteps = RunReceipt(sim.state)
        #expect(afterSteps.finalDigest == digest)
        #expect(afterSteps.elapsedTicks == elapsed)
        #expect(afterSteps.outcome == .failure)
        #expect(afterSteps.destructions.count == 1)
    }

    @Test func terminalT704ER005FailedRunRetainsCameraDestruction() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_setPlayerIntegrity(0)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        let receipt = RunReceipt(sim.state)
        #expect(receipt.outcome == .failure)
        #expect(receipt.destructions.count == 1)
        #expect(receipt.camerasDestroyed == 1)
        #expect(receipt.destructions[0].cameraId == sim.state.cameras[0].entityId)
    }

    @Test func terminalT704ER008ReceiptCanonicalRoundTrip() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(1)
        _ = sim.step(command: .neutral(tick: 2))
        let receipt = RunReceipt(sim.state)
        let canonical = receipt.canonical()
        let first = canonical.serialize()
        let second = canonical.serialize()
        #expect(first == second)
        #expect(canonical.sha256Hex() == receipt.canonical().sha256Hex())
    }

    @Test func terminalT704DeathWithBossDefeatRemainsFailure() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 10)
        let bossPosition = sim.state.enemies.first(where: { $0.archetype == .algorithmicModerate })!.position
        // D-090: a 10-damage bolt removes 5 Integrity, so 5 is lethal.
        sim.testing_setPlayerIntegrity(5)
        sim.testing_injectHostileBolt(damage: 10)
        sim.testing_injectPulseHitting(position: bossPosition)
        let result = sim.step(command: .neutral(tick: 1))
        #expect(result.outcome == .failure)
        #expect(sim.state.bossDefeated)
        #expect(result.events.contains(where: { $0.type == .bossDefeated }))
        #expect(result.events.contains(where: { $0.type == .runSucceeded }) == false)
        #expect(sim.state.terminalDigest != nil)
    }

    @Test func terminalT704SealedDigestMatchesRunSucceededPayload() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(1)
        let result = sim.step(command: .neutral(tick: 2))
        let succeeded = result.events.first(where: { $0.type == .runSucceeded })
        #expect(sim.state.terminalDigest == succeeded.flatMap { event in
            if case .string(let digest)? = event.payload["finalDigest"] { return digest }
            return nil
        })
    }
}
