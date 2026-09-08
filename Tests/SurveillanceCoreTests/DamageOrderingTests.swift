import Testing
@testable import SurveillanceCore

/// `combat.md` CB-005 through CB-010: the order one tick's hits resolve in, and
/// what a hit is allowed to do once it resolves.
///
/// These had no coverage — not by vector ID and not by behaviour — even though
/// the ordering is what every replay's determinism rests on. A build that breaks
/// a tie differently diverges on the tick it happens and every subsequent tick
/// is wrong, which is what gate B-002 checks across architectures.
@Suite(.serialized)
struct DamageOrderingTests {
    static func hit(
        t: Int64,
        target: Int,
        projectile: Int,
        isWall: Bool = false,
        index: Int = 0
    ) -> DamageHit {
        DamageHit(
            t: t,
            target: EntityID(UInt64(target)),
            projectile: EntityID(UInt64(projectile)),
            isWall: isWall,
            index: index
        )
    }

    /// CB-005: two targets on one sweep — the earliest intersection is hit.
    @Test func combatCB005EarliestIntersectionResolvesFirst() {
        let far = Self.hit(t: 200, target: 7, projectile: 1)
        let near = Self.hit(t: 50, target: 9, projectile: 1)

        #expect(DamageHit.ordered([far, near]) == [near, far])
        // Input order must not matter, or the result depends on pool iteration.
        #expect(DamageHit.ordered([near, far]) == [near, far])
    }

    /// CB-006: equal intersection time — the lower target ID is hit.
    @Test func combatCB006EqualTimePrefersLowerTargetID() {
        let higher = Self.hit(t: 100, target: 12, projectile: 1)
        let lower = Self.hit(t: 100, target: 5, projectile: 1)

        #expect(DamageHit.ordered([higher, lower]) == [lower, higher])
        #expect(DamageHit.ordered([lower, higher]) == [lower, higher])
    }

    /// CB-007: wall and entity tie exactly — the wall consumes the projectile.
    ///
    /// Constructed so the wall would lose every *later* tiebreak: a higher
    /// target ID and a higher projectile ID. That matters. The first version of
    /// this test gave the wall its real target, `EntityID(0)`, which is lower
    /// than every entity ID — so the wall sorted first through the ID
    /// comparison whether or not the rule existed, and deleting the rule did
    /// not fail the test. It passed for the wrong reason.
    ///
    /// What this does and does not prove: `resolveDamage` currently builds every
    /// wall hit with `EntityID(0)`, so the clause is defensive rather than
    /// load-bearing today. It is pinned as a rule so it still holds if wall hits
    /// ever carry a real solid ID — which is precisely when losing it would let
    /// a shot pass through a solid into someone sheltering behind it.
    @Test func combatCB007WallConsumesTheProjectileOnAnExactTie() {
        let wall = Self.hit(t: 100, target: 99, projectile: 9, isWall: true)
        let enemy = Self.hit(t: 100, target: 5, projectile: 1)

        #expect(DamageHit.ordered([enemy, wall]) == [wall, enemy])
        #expect(DamageHit.ordered([wall, enemy]) == [wall, enemy])
    }

    /// The order has to be *total*: no two distinct hits may compare equal, or
    /// `sorted` is free to return either arrangement and two platforms can
    /// disagree without either being wrong.
    @Test func theOrderIsTotalAndNeverDependsOnDiscoveryOrder() {
        let hits = [
            Self.hit(t: 100, target: 5, projectile: 3),
            Self.hit(t: 100, target: 5, projectile: 1),
            Self.hit(t: 100, target: 2, projectile: 9),
            Self.hit(t: 50, target: 8, projectile: 4),
            Self.hit(t: 100, target: 77, projectile: 7, isWall: true)
        ]
        let expected = DamageHit.ordered(hits)

        // Every rotation of the same set must produce the same resolution order.
        for shift in 1..<hits.count {
            let rotated = Array(hits[shift...] + hits[..<shift])
            #expect(DamageHit.ordered(rotated) == expected)
        }

        // No pair compares equal in both directions.
        for a in hits {
            for b in hits where a != b {
                #expect(DamageHit.precedes(a, b) != DamageHit.precedes(b, a))
            }
        }
    }

    /// CB-008: a Camera loses exactly one Integrity, whatever the projectile
    /// carries for enemies.
    @Test func combatCB008CameraLosesOneIntegrityRegardlessOfEnemyDamage() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 3)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        _ = sim.step(command: .neutral(tick: 1))

        // The projectile is worth 10 against an enemy and the Camera still drops
        // by 1 — the two numbers are independent, which is the whole vector.
        #expect(Targeting.enemyDamage == 10)
        #expect(sim.state.cameras[0].integrity == 2)
    }

    /// CB-010: a target killed by an earlier ordered hit cannot be damaged or
    /// retargeted by a later one in the same tick.
    ///
    /// The damage half is not where the risk is. `min(damage, integrity)` already
    /// yields nothing against a corpse, so an earlier version of this test
    /// asserting only `damageDealt` passed with the liveness guard deleted — a
    /// green light over a real regression.
    ///
    /// The retarget half is the dangerous one, because `killEnemy` is **not**
    /// idempotent: it re-emits `entityDied`, increments `defeatsByArchetype`
    /// again, and decrements the encounter's `living` count a second time. A
    /// second resolved hit would therefore inflate the run receipt and could
    /// report an encounter complete while enemies are still standing in it.
    @Test func combatCB010ALaterHitCannotDamageOrRekillADeadTarget() throws {
        var sim = try Simulation.make(seed: 1)
        let spot = VecI(
            x: sim.state.player.position.x.unitsTruncated + 120,
            y: sim.state.player.position.y.unitsTruncated
        )
        // Integrity of exactly one pulse, so the first ordered hit kills it.
        sim.testing_spawnInformant(at: spot, integrity: Targeting.enemyDamage)
        let archetype = ArchetypeID.autonomousInformant.rawValue
        let damageBefore = sim.state.combat.damageDealt
        let defeatsBefore = sim.state.combat.defeatsByArchetype[archetype] ?? 0

        // Two projectiles on the same target in the same tick. CB-006 orders
        // them by projectile ID; the first kills, the second must find a corpse.
        sim.testing_injectPulseHitting(position: spot.asQ8)
        sim.testing_injectPulseHitting(position: spot.asQ8)
        let result = sim.step(command: .neutral(tick: 1))

        #expect(sim.state.combat.damageDealt - damageBefore == Targeting.enemyDamage)

        // Counted once, not twice — this is the assertion the guard actually
        // protects, and the one that fails when it is removed.
        let defeats = (sim.state.combat.defeatsByArchetype[archetype] ?? 0) - defeatsBefore
        #expect(defeats == 1)

        // And exactly one death event reaches the receipt and the replay.
        let deaths = result.events.filter { $0.type == .entityDied }.count
        #expect(deaths == 1)
    }
}
