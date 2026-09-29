import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ContractVectorTests {
    @Test func exposureEX006ContactOnSixtiethTickResetsClock() {
        var state = ExposureState(exposure: 300, detectionState: .observed, noContactTicks: 0)
        for _ in 0..<60 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false)
        }
        #expect(state.noContactTicks == 60)
        #expect(state.exposure == 300)
        let result = state.resolveTick(survivingContactCount: 1, tamperAmounts: [], signalJammer: false)
        #expect(result.contactDelta == 2)
        #expect(state.exposure == 302)
        #expect(state.noContactTicks == 0)
    }

    @Test func playerPC004DiagonalIntoVerticalWallSlidesY() {
        let end = IsolatedKernel.slideIntoVerticalWall()
        #expect(end.x.unitsTruncated < 392)
        #expect(end.x.unitsTruncated > 256)
        #expect(end.y.unitsTruncated > 256)
    }

    @Test func combatCB001TenPulsesOverThreeHundredTicks() throws {
        var sim = try Simulation.make(seed: 1)
        let origin = VecI(x: sim.state.player.position.x.unitsTruncated + 48, y: sim.state.player.position.y.unitsTruncated)
        sim.testing_spawnInformant(at: origin, integrity: 10_000, speed: 0)
        var fired = 0
        for tick in 1...300 {
            let result = sim.step(command: .neutral(tick: UInt64(tick)))
            fired += result.events.filter { $0.type == .weaponFired }.count
        }
        #expect(fired == 10)
    }

    @Test func combatCB003PredictiveAimDiffersFromDirect() {
        let from = VecQ8.zero
        let to = VecQ8(unitsX: 120, unitsY: 0)
        let lateral = VecQ8(unitsX: 0, unitsY: 8)
        let speed = Int64(Targeting.projectileSpeedPerTick) * Q8.scale
        let aim = Targeting.aimVelocity(from: from, to: to, targetVelocity: lateral)
        let direct = Targeting.direct(from: from, to: to, speed: speed)
        #expect(aim != direct)
    }

    @Test func combatCB004OverSpeedUsesDirectAim() {
        let from = VecQ8.zero
        let to = VecQ8(unitsX: 120, unitsY: 0)
        let receding = VecQ8(unitsX: 20, unitsY: 0)
        let speed = Int64(Targeting.projectileSpeedPerTick) * Q8.scale
        let aim = Targeting.aimVelocity(from: from, to: to, targetVelocity: receding)
        let direct = Targeting.direct(from: from, to: to, speed: speed)
        #expect(aim == direct)
    }

    @Test func combatCB009CeilingRejectsThirtyThirdShot() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_fillCivicPool(count: 32)
        sim.testing_spawnInformant(
            at: VecI(x: sim.state.player.position.x.unitsTruncated + 48, y: sim.state.player.position.y.unitsTruncated)
        )
        #expect(sim.state.civicPool.liveCount == 32)
        var fired = 0
        for tick in 1...30 {
            let result = sim.step(command: .neutral(tick: UInt64(tick)))
            fired += result.events.filter { $0.type == .weaponFired }.count
        }
        #expect(fired == 0)
        #expect(sim.state.civicPool.liveCount == 32)
    }

    @Test func upgradeUP001PendingFreezesClock() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armUpgradeSelection()
        let tick = sim.state.tick
        let digest = sim.state.digest()
        for _ in 0..<600 {
            _ = sim.step(command: nil)
        }
        #expect(sim.state.tick == tick)
        #expect(sim.state.digest() == digest)
        #expect(sim.state.outcome == .upgradeSelectionPending)
    }

    @Test func upgradeUP002SelectsSignalJammer() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armUpgradeSelection()
        let result = sim.step(
            command: PlayerCommand(tick: 1, moveX: 0, moveY: 0, dodgePressed: false, upgradeChoiceIndex: 0)
        )
        #expect(sim.state.upgrade.selected == .signalJammer)
        #expect(!sim.state.upgrade.pending)
        #expect(result.tick == 1)
    }

    @Test func upgradeUP003InvalidIndexStaysProtected() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_armUpgradeSelection()
        _ = sim.step(
            command: PlayerCommand(tick: 1, moveX: 0, moveY: 0, dodgePressed: false, upgradeChoiceIndex: 9)
        )
        #expect(sim.state.upgrade.pending)
        #expect(sim.state.upgrade.selected == nil)
        #expect(sim.state.tick == 0)
        #expect(sim.state.outcome == .upgradeSelectionPending)
    }

    @Test func upgradeUP005JammerDoesNotReduceTamper() {
        var state = ExposureState(exposure: 200, detectionState: .observed)
        let result = state.resolveTick(survivingContactCount: 0, tamperAmounts: [100], signalJammer: true)
        #expect(result.tamperApplied == 100)
        #expect(state.exposure == 300)
    }

    @Test func upgradeUP006RicochetEqualDistancePrefersLowerID() {
        let ids = IsolatedKernel.ricochetEqualDistanceLowerId()
        #expect(ids.0 == 10)
        #expect(ids.1 == 10)
    }

    @Test func upgradeUP007DestroyedCameraExcludedFromContinuation() {
        let id = IsolatedKernel.ricochetSkipsDestroyedCamera()
        #expect(id == 9)
    }

    @Test func upgradeUP008GhostStepImmunityThroughStartPlus29() {
        #expect(IsolatedKernel.ghostStepImmunityTick() == 129)
    }

    @Test func upgradeUP009GhostStepHostileProjectileStillDamages() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_selectUpgrade(.ghostStep)
        _ = sim.step(
            command: PlayerCommand(tick: 1, moveX: PlayerCommand.axisMaximum, moveY: 0, dodgePressed: true)
        )
        let immuneThrough = sim.state.player.cameraInvisibleUntilTick
        let before = sim.state.player.integrity
        sim.testing_injectHostileBolt()
        _ = sim.step(command: .neutral(tick: 2))
        let after = sim.state.player.integrity
        let stillImmune = sim.state.player.isCameraInvisible(tick: 2)
        #expect(immuneThrough == 30)
        #expect(stillImmune)
        // D-090: 50% of the bolt's 10.
        #expect(after == before - 5)
    }

    @Test func upgradeUP010RestartClearsSelectedUpgrade() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_selectUpgrade(.signalJammer)
        sim.restart()
        let selected = sim.state.upgrade.selected
        let pending = sim.state.upgrade.pending
        let mobAComplete = sim.state.encounters["M-A"]?.completed ?? true
        #expect(selected == nil)
        #expect(!pending)
        #expect(!mobAComplete)
    }

    @Test func bossBO004PhaseTransitionDuringTelegraphCancelsAttack() {
        let result = IsolatedKernel.bossPhaseTransitionDuringTelegraph()
        #expect(result.after == .temporarySafeguard)
        #expect(result.recovery == 44)
        #expect(result.telegraph == 0)
        #expect(result.attack == nil)
        #expect(result.liveBossBolts == 0)
    }

    @Test func bossBO008DefeatRetiresFieldAndProjectiles() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 1)
        sim.testing_injectBossBolt()
        sim.testing_activateBossField(remaining: 60)
        sim.testing_defeatBoss()
        let liveBossBolts = sim.state.projectiles.filter { $0.kind == .bossBolt && $0.alive }.count
        let fieldRemaining = sim.state.bossRuntime?.fieldRemaining ?? -1
        let activeEmitter = sim.state.bossRuntime?.activeEmitter
        let defeated = sim.state.bossDefeated
        #expect(defeated)
        #expect(liveBossBolts == 0)
        #expect(fieldRemaining == 0)
        #expect(activeEmitter == nil)
    }

    @Test func bossBO009SameTickPlayerDeathIsTerminalFailure() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 10)
        let bossPosition = sim.state.enemies.first(where: { $0.archetype == .algorithmicModerate })!.position
        // D-090: a 10-damage bolt removes 5 Integrity, so 5 is lethal.
        sim.testing_setPlayerIntegrity(5)
        sim.testing_injectHostileBolt(damage: 10)
        sim.testing_injectPulseHitting(position: bossPosition)
        let result = sim.step(command: .neutral(tick: 1))
        let outcome = result.outcome
        let defeated = sim.state.bossDefeated
        let bossEvents = result.events.filter { $0.type == .bossDefeated }.count
        #expect(outcome == .failure)
        #expect(defeated)
        #expect(bossEvents == 1)
    }

    @Test func bossBO010ZeroCamerasDestroyedBossDefeatArmsExtraction() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        sim.testing_installBoss(integrity: 10)
        let bossPosition = sim.state.enemies.first(where: { $0.archetype == .algorithmicModerate })!.position
        sim.testing_injectPulseHitting(position: bossPosition)
        let result = sim.step(command: .neutral(tick: 1))
        let destroyed = sim.state.destructions.count
        let defeated = sim.state.bossDefeated
        let armed = sim.state.extraction.armed
        let outcome = result.outcome
        #expect(destroyed == 0)
        #expect(defeated)
        #expect(armed)
        #expect(outcome == .playing)
    }

    @Test func encounterEN001WaveTotals() {
        let content = CombatContent.bundled()
        #expect(content.encounters["M-A"]?.totals == 14)
        #expect(content.encounters["M-B"]?.totals == 17)
        #expect(content.encounters["M-C"]?.totals == 25)
    }

    @Test func cameraCD013ExtractionArmsAtZeroDestroyed() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(1)
        let result = sim.step(command: .neutral(tick: 2))
        let outcome = result.outcome
        let destroyed = sim.state.destructions.count
        let blackout = sim.state.networkBlackout
        let receipt = RunReceipt(sim.state)
        let receiptDestroyed = receipt.camerasDestroyed
        let receiptBlackout = receipt.networkBlackout
        #expect(outcome == .success)
        #expect(destroyed == 0)
        #expect(!blackout)
        #expect(receiptDestroyed == 0)
        #expect(!receiptBlackout)
    }

    @Test func bossBO001DaemonCycleTimingAndQueryDamage() {
        let result = IsolatedKernel.daemonCycle(ticks: 291)
        #expect(result.states[119] == .queryTelegraph)
        #expect(result.states[164] == .dashTelegraph)
        #expect(result.states[200] == .dash)
        #expect(result.states[230] == .recover)
        #expect(result.states[290] == .pursue)
        #expect(result.damage == 14)
        #expect(result.markers.count == 3)
    }

    @Test func bossBO005AndBO006ObservationRounding() {
        #expect(BossSystem.observationAmount(base: 10, numerator: 105, signalJammer: false) == 11)
        #expect(BossSystem.observationAmount(base: 10, numerator: 105, signalJammer: true) == 8)
    }

    @Test func bossBO007IndependentReviewOmitsLowerTiedLane() {
        let lanes = BossSystem.independentReviewLanes(toPlayerMilli: 30_000)
        #expect(lanes.count == 5)
        #expect(!lanes.contains(0))
        #expect(lanes.contains(60_000))
    }

    @Test func arenaAR004PlayerSpawnIsInsideZ01() throws {
        let arena = try ArenaManifest.bundled()
        let spawn = VecI(x: arena.playerSpawn.x, y: arena.playerSpawn.y)
        let z01 = try #require(arena.zones.first { $0.id == "Z-01" })
        #expect(z01.aabb.contains(spawn))
        #expect(!arena.permanentSolids.contains { $0.aabb.contains(spawn) })
        #expect(ArenaReachability.spawnAlleyProtected(arena))
    }
}
