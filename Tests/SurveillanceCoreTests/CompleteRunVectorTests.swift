import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct CompleteRunVectorTests {
    private struct ExpectedVector: Sendable {
        var elapsedTicks: UInt64
        var terminalDigest: String
    }

    private static let expectedVectors: [UpgradeID: ExpectedVector] = [
        .signalJammer: ExpectedVector(
            elapsedTicks: 302,
            terminalDigest: "b33cfc3e44f55b51f76f63487047f96217ea04cf736ea3e95f005d73a2a0f8a0"
        ),
        .ricochetPulse: ExpectedVector(
            elapsedTicks: 302,
            terminalDigest: "978b3231c57702ec2926e446b55d449dbe45adbc94c17aadefa255fe5286190e"
        ),
        .ghostStep: ExpectedVector(
            elapsedTicks: 302,
            terminalDigest: "240c584eef2b4c67744fdaa592bd6c96d9d95a71f8009824d56a027a065425f6"
        )
    ]

    @Test(arguments: UpgradeID.allCases)
    func completeRunT705GoldenVectorSucceedsWithZeroCamerasDestroyed(upgrade: UpgradeID) throws {
        var sim = try Simulation.make(seed: 1)
        let result = sim.testing_completeRunSuccess(upgrade: upgrade)
        let receipt = RunReceipt(sim.state)
        #expect(result.outcome == .success)
        #expect(sim.state.destructions.count == 0)
        #expect(!sim.state.networkBlackout)
        #expect(sim.state.upgrade.selected == upgrade)
        #expect(receipt.upgrade == upgrade)
        #expect(receipt.camerasDestroyed == 0)
        #expect(!receipt.networkBlackout)
        #expect(receipt.extractionArmed)
        #expect(receipt.combatAuthority.complete)
        #expect(receipt.bossDefeated)
        #expect(sim.state.terminalDigest != nil)
        let expected = Self.expectedVectors[upgrade]!
        #expect(sim.state.tick == expected.elapsedTicks)
        #expect(sim.state.terminalDigest == expected.terminalDigest)
        #expect(receipt.finalDigest == expected.terminalDigest)
    }

    @Test(arguments: UpgradeID.allCases)
    func completeRunT706NoCameraDestructionExploit(upgrade: UpgradeID) throws {
        var sim = try Simulation.make(seed: 1)
        testing_preparePostUpgradeCombat(sim: &sim, upgrade: upgrade)
        sim.testing_destroyCameraAtIndex(0)
        _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(0)
        let result = sim.step(command: .neutral(tick: sim.state.tick + 1))
        let receipt = RunReceipt(sim.state)
        #expect(sim.state.destructions.count == 1)
        #expect(receipt.camerasDestroyed == 1)
        #expect(result.outcome != .success || receipt.camerasDestroyed != 0)
    }

    @Test(arguments: UpgradeID.allCases)
    func completeRunT706UpgradeIsolationPreserved(upgrade: UpgradeID) throws {
        var sim = try Simulation.make(seed: 1)
        testing_preparePostUpgradeCombat(sim: &sim, upgrade: upgrade)
        #expect(sim.state.upgrade.selected == upgrade)
        for other in UpgradeID.allCases where other != upgrade {
            #expect(sim.state.upgrade.selected != other)
        }
    }

    @Test func completeRunT706SignalJammerDoesNotBlockForcedLockdown() {
        var state = ExposureState(exposure: 200, detectionState: .observed)
        let result = state.resolveTick(
            survivingContactCount: 1,
            tamperAmounts: [],
            signalJammer: true,
            forceLockdown: true
        )
        #expect(state.lockdownEntered)
        #expect(result.reason == .forcedLockdown)
    }

    @Test func completeRunT706GhostStepDoesNotGrantDamageImmunity() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_selectUpgrade(.ghostStep)
        let dodgeTick = sim.state.tick + 1
        _ = sim.step(
            command: PlayerCommand(
                tick: dodgeTick,
                moveX: PlayerCommand.axisMaximum,
                moveY: 0,
                dodgePressed: true
            )
        )
        let before = sim.state.player.integrity
        sim.testing_injectHostileBolt()
        let hitTick = sim.state.tick + 1
        _ = sim.step(command: .neutral(tick: hitTick))
        // D-090: 50% of the bolt's 10.
        #expect(sim.state.player.integrity == before - 5)
    }

    @Test func completeRunT706RicochetCannotDoubleHitSameTarget() {
        let id = IsolatedKernel.ricochetSkipsDestroyedCamera()
        #expect(id == 9)
    }

    private func testing_preparePostUpgradeCombat(sim: inout Simulation, upgrade: UpgradeID) {
        sim.testing_completeEncounter("M-A")
        sim.testing_selectUpgrade(upgrade)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
    }
}
