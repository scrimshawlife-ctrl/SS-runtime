import Testing
@testable import SurveillanceCore

/// The renderer can only draw what the projection exposes. combat-001 and
/// bosses.md make projectiles, mines, boss Integrity, and telegraphs
/// authoritative, so each must reach `PresentationSnapshot` exactly.
@Suite(.serialized)
struct CombatVisibilityTests {
    @Test func projectilesReachThePresentationSnapshot() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        let bossPosition = sim.state.enemies.first(where: { $0.archetype == .algorithmicModerate })!.position
        sim.testing_injectPulseHitting(position: bossPosition)

        let snapshot = PresentationSnapshot(sim.state)
        let live = sim.state.projectiles.filter(\.alive)

        #expect(!live.isEmpty)
        #expect(snapshot.projectiles.count == live.count)
        #expect(snapshot.projectiles.allSatisfy { $0.radius > 0 })
        // combat-001: the Player's Civic Pulse is not hostile.
        #expect(snapshot.projectiles.contains { !$0.hostile })
    }

    @Test func hostileProjectilesAreDistinguishedFromPlayerFire() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_injectBossBolt()

        let snapshot = PresentationSnapshot(sim.state)
        let hostile = snapshot.projectiles.filter(\.hostile)

        #expect(hostile.count == 1)
        #expect(hostile.first?.role == "bossBolt")
    }

    @Test func projectileOrderIsStableByEntityID() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_injectBossBolt()
        sim.testing_injectBossBolt()
        sim.testing_injectHostileBolt()

        let ids = PresentationSnapshot(sim.state).projectiles.map(\.id.raw)

        #expect(ids == ids.sorted())
    }

    @Test func bossIntegrityProjectsForTheHUDBar() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)

        let snapshot = PresentationSnapshot(sim.state)
        let boss = try #require(snapshot.boss)

        #expect(boss.integrity == 800)
        #expect(boss.maxIntegrity == sim.state.content.bossHP)
        #expect(boss.phase == .publicSafety)
    }

    @Test func bossHUDIsAbsentBeforeAndAfterTheBoss() throws {
        var sim = try Simulation.make(seed: 1)
        #expect(PresentationSnapshot(sim.state).boss == nil)

        sim.testing_installBoss(integrity: 10)
        #expect(PresentationSnapshot(sim.state).boss != nil)

        sim.testing_defeatBoss()
        #expect(PresentationSnapshot(sim.state).boss == nil)
    }

    /// bosses.md §Safety Rationale: 45 ticks, 70-degree cone, range 260.
    @Test func safetyRationaleTelegraphMatchesTheContract() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_beginBossTelegraph(.safetyRationale, remaining: 45)

        let telegraphs = PresentationSnapshot(sim.state).telegraphs
        let cone = try #require(telegraphs.first { $0.kind == .cone })

        #expect(telegraphs.count == 1)
        #expect(cone.halfAngleMilli == 35_000)
        #expect(cone.rangeUnits == 260)
        #expect(cone.totalTicks == 45)
        #expect(cone.remainingTicks == 45)
        #expect(!cone.locked)
        #expect(cone.progressPermille == 0)
    }

    /// The cone tracks the Player until the heading locks on the final tick.
    @Test func safetyRationaleLocksOnTheFinalTelegraphTick() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_beginBossTelegraph(.safetyRationale, remaining: 1)

        let cone = try #require(PresentationSnapshot(sim.state).telegraphs.first)

        #expect(cone.locked)
        #expect(cone.progressPermille == 978)
    }

    /// bosses.md §Narrow Tailoring: three projectiles at −12°, 0°, +12°.
    @Test func narrowTailoringProjectsThreeLanes() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_beginBossTelegraph(.narrowTailoring, remaining: 30)

        let lanes = PresentationSnapshot(sim.state).telegraphs

        #expect(lanes.count == 3)
        #expect(lanes.allSatisfy { $0.kind == .lane })
        #expect(lanes.allSatisfy { $0.widthUnits == 14 })
        #expect(lanes.allSatisfy { $0.totalTicks == 30 })
        // speed 420 for 72 ticks at 60 Hz.
        #expect(lanes.allSatisfy { $0.rangeUnits == 504 })

        let headings = lanes.map(\.headingMilli)
        #expect(MilliDeg.absDelta(headings[0], headings[1]) == 12_000)
        #expect(MilliDeg.absDelta(headings[1], headings[2]) == 12_000)
    }

    /// bosses.md §Independent Review: six lanes minus the safe gap = five.
    @Test func independentReviewProjectsFiveLanesLeavingTheSafeGap() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_beginBossTelegraph(.independentReview, remaining: 60)

        let lanes = PresentationSnapshot(sim.state).telegraphs

        #expect(lanes.count == 5)
        #expect(lanes.allSatisfy { $0.kind == .lane })
        // speed 360 for 90 ticks at 60 Hz.
        #expect(lanes.allSatisfy { $0.rangeUnits == 540 })

        let boss = sim.state.enemies.first(where: { $0.archetype == .algorithmicModerate })!
        let toPlayer = TelegraphProjection.headingToPlayer(
            from: boss.position,
            player: sim.state.player.position
        )
        // The omitted lane is the one nearest the Player: the safe gap.
        let omitted = Set((0..<6).map { MilliDeg.normalize($0 * 60_000) })
            .subtracting(lanes.map(\.headingMilli))
        let nearest = try #require(omitted.first)
        for lane in lanes {
            #expect(MilliDeg.absDelta(lane.headingMilli, toPlayer) >= MilliDeg.absDelta(nearest, toPlayer))
        }
    }

    /// bosses.md §Temporary Order telegraphs at the emitter that will activate.
    @Test func temporaryOrderTelegraphsThePendingEmitter() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)
        sim.testing_beginBossTelegraph(.temporaryOrder, remaining: 48)

        let telegraph = try #require(PresentationSnapshot(sim.state).telegraphs.first)
        let pending = try #require(sim.state.arena.captainCameraEmitters.first)

        #expect(telegraph.kind == .emitterField)
        #expect(telegraph.x == pending.x)
        #expect(telegraph.y == pending.y)
        #expect(telegraph.rangeUnits == pending.rangeUnits)
        #expect(telegraph.halfAngleMilli == pending.fieldAngleMilliDegrees / 2)
        #expect(telegraph.totalTicks == 48)
    }

    @Test func noTelegraphProjectsWhileTheBossIsRecovering() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_installBoss(integrity: 800)

        #expect(PresentationSnapshot(sim.state).telegraphs.isEmpty)
    }

    @Test func projectileReachUsesTheAuthoritativeTickRate() {
        #expect(TelegraphProjection.projectileReach(speed: 420, lifetimeTicks: 72) == 504)
        #expect(TelegraphProjection.projectileReach(speed: 360, lifetimeTicks: 90) == 540)
        #expect(TelegraphProjection.projectileReach(speed: 288, lifetimeTicks: 30) == 144)
    }

    @Test func minesProjectWithTheirArmingState() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_insertMine(at: VecI(x: 400, y: 400), armRemaining: 12)

        let projected = try #require(PresentationSnapshot(sim.state).mines.first)

        #expect(!projected.armed)
        #expect(projected.armRemaining == 12)
        #expect(projected.radius == 40)
    }
}

/// The objective node is projected so a caller can reason about progress
/// without parsing display copy.
@Suite(.serialized)
struct ObjectiveProjectionTests {
    @Test func snapshotExposesTheAuthoritativeObjectiveNode() throws {
        var sim = try Simulation.make(seed: 1)
        #expect(PresentationSnapshot(sim.state).objectiveNode == .mobA)

        sim.testing_completeMobAndEliteGraph()
        #expect(PresentationSnapshot(sim.state).objectiveNode == .algorithmicModerate)

        sim.testing_completeCombatGraph()
        #expect(PresentationSnapshot(sim.state).objectiveNode == .extraction)
    }

    /// The node and the copy the HUD draws never disagree.
    @Test func nodeAndCopyAgree() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        let snapshot = PresentationSnapshot(sim.state)
        #expect(snapshot.combatObjectiveCopy == "ALGORITHMIC MODERATE")
        #expect(snapshot.objectiveNode == .algorithmicModerate)
    }
}
