import Testing
@testable import SurveillanceCore

/// `enemies-and-encounters.md` EN-004 through EN-010.
///
/// There was no enemy behaviour test file at all: the five Civic Seam
/// archetypes, the mine budget, the M-C forced Lockdown and the encounter
/// completion rule were all uncovered. Every rule here is already implemented —
/// these pin it, and each one is mutation-checked so it fails when its rule is
/// removed rather than passing on a coincidence.
///
/// EN-004 to EN-006 drive `EnemySystem.step` directly, because it takes the
/// world as parameters and lets a case be set up exactly: a wall in a specific
/// place, a charge with nowhere to go, a mine budget already full. Reaching the
/// same states through a live run would depend on spawn rolls and pathing.
@Suite(.serialized)
struct EnemyBehaviourTests {
    static func enemy(
        _ archetype: ArchetypeID,
        id: UInt64,
        at position: VecI,
        state: EnemyAIState,
        stateTicks: Int = 0,
        velocity: VecQ8 = .zero,
        content: CombatContent
    ) -> EnemyBody {
        let stats = content.standardEnemies[archetype]!
        return EnemyBody(
            id: EntityID(id),
            archetype: archetype,
            position: position.asQ8,
            velocity: velocity,
            integrity: stats.hp,
            radius: stats.radius,
            speedUnitsPerSecond: stats.speed,
            contactDps: stats.contactDps,
            state: state,
            stateTicks: stateTicks,
            spawnTick: 0,
            nextSpecialTick: .max,
            lockPosition: nil,
            encounterId: "test"
        )
    }

    /// Runs one enemy tick and reports what it produced.
    static func step(
        _ enemies: inout [EnemyBody],
        player: PlayerBody,
        solids: [(id: String, box: AABB)],
        content: CombatContent,
        bounds: AABB,
        mines: inout [MineBody]
    ) -> (pulses: [Int], projectiles: [ProjectileBody]) {
        var allocator = EntityAllocator()
        _ = allocator.next()
        var projectiles: [ProjectileBody] = []
        var pulses: [Int] = []
        var damage: [(EntityID, Int)] = []
        EnemySystem.step(
            enemies: &enemies,
            player: player,
            tick: 1,
            content: content,
            bounds: bounds,
            solids: solids,
            allocator: &allocator,
            projectiles: &projectiles,
            mines: &mines,
            exposurePulses: &pulses,
            playerDamage: &damage
        )
        return (pulses, projectiles)
    }

    /// EN-004: a Fog pulse that loses line of sight during its telegraph misses.
    ///
    /// The pulse is resolved against the world as it is when the telegraph ends,
    /// not as it was when the telegraph began — so stepping behind a solid during
    /// those 45 ticks is a real counter, which is the point of the enemy.
    @Test func enemyEN004FogPulseWithoutLineOfSightMisses() throws {
        let sim = try Simulation.make(seed: 1)
        let content = sim.state.content
        let bounds = sim.state.arena.boundsUnits.aabb
        var player = sim.state.player
        player.position = VecI(x: 1200, y: 1200).asQ8
        let cloud = VecI(x: 1000, y: 1200)   // 200 units away, inside the 220 range
        var mines: [MineBody] = []

        // Clear line first, so the miss below is attributable to the wall and
        // not to the range check or a mis-set telegraph.
        var clear = [Self.enemy(.fogAnalyticsCloud, id: 10, at: cloud, state: .telegraph, content: content)]
        let hit = Self.step(&clear, player: player, solids: [], content: content, bounds: bounds, mines: &mines)
        #expect(hit.pulses == [content.standardEnemies[.fogAnalyticsCloud]!.pulse!.exposure])

        // Same tick, same distance, one solid across the line.
        var blocked = [Self.enemy(.fogAnalyticsCloud, id: 10, at: cloud, state: .telegraph, content: content)]
        let wall = [(
            id: "test-wall",
            box: AABB(center: VecI(x: 1100, y: 1200), halfSize: VecI(x: 16, y: 200))
        )]
        let miss = Self.step(&blocked, player: player, solids: wall, content: content, bounds: bounds, mines: &mines)
        #expect(miss.pulses.isEmpty)

        // Either way the cloud spends its pulse and goes on cooldown: a miss
        // costs it the shot rather than letting it retry next tick.
        #expect(blocked[0].state == .cooldown)
    }

    /// EN-005: a charge that hits a solid ends there, and recovers for 45 ticks.
    @Test func enemyEN005CorrelatorChargeIntoASolidEndsAndRecovers() throws {
        let sim = try Simulation.make(seed: 1)
        let content = sim.state.content
        let charge = content.standardEnemies[.cableCarCorrelator]!.charge!
        let bounds = sim.state.arena.boundsUnits.aabb
        var player = sim.state.player
        player.position = VecI(x: 1600, y: 1200).asQ8
        var mines: [MineBody] = []

        // Mid-charge, moving straight at a wall it is already touching, so the
        // slide resolves to no movement at all.
        var enemies = [
            Self.enemy(
                .cableCarCorrelator, id: 10, at: VecI(x: 1000, y: 1200),
                state: .charge, stateTicks: charge.ticks - 1,
                velocity: VecQ8(x: Q8(raw: Steering.speedQ8(charge.speed)), y: Q8(raw: 0)),
                content: content
            )
        ]
        let stats = content.standardEnemies[.cableCarCorrelator]!
        let wall = [(
            id: "test-wall",
            box: AABB(center: VecI(x: 1000 + stats.radius + 20, y: 1200), halfSize: VecI(x: 20, y: 240))
        )]
        _ = Self.step(&enemies, player: player, solids: wall, content: content, bounds: bounds, mines: &mines)

        #expect(enemies[0].state == .recover)
        #expect(enemies[0].stateTicks == charge.recover)
        #expect(charge.recover == 45)
        #expect(enemies[0].velocity == .zero)
    }

    /// EN-006: a Vendor's third mine retires its oldest.
    ///
    /// "Oldest" is the lowest entity ID, which is monotonic from the allocator,
    /// rather than the lowest remaining lifetime — a mine placed later can hold
    /// more life than one placed earlier, so lifetime would retire the wrong one.
    @Test func enemyEN006ThirdVendorMineRetiresTheOldest() throws {
        let sim = try Simulation.make(seed: 1)
        let content = sim.state.content
        let spec = content.standardEnemies[.victorianVendor]!.mine!
        let bounds = sim.state.arena.boundsUnits.aabb
        var player = sim.state.player
        player.position = VecI(x: 1200, y: 1200).asQ8

        let vendor = EntityID(10)
        func mine(id: UInt64, life: Int) -> MineBody {
            MineBody(
                id: EntityID(id), ownerId: vendor,
                position: VecI(x: 900, y: 900).asQ8,
                armRemaining: 0, lifeRemaining: life,
                radius: spec.radius, damage: spec.damage
            )
        }
        // The oldest carries the *most* remaining life, so a lifetime-based
        // retirement would keep it and this test would fail.
        var mines = [mine(id: 100, life: 240), mine(id: 200, life: 30)]
        // A second Vendor's mine must be untouched: the budget is per Vendor.
        mines.append(MineBody(
            id: EntityID(50), ownerId: EntityID(11),
            position: VecI(x: 800, y: 800).asQ8,
            armRemaining: 0, lifeRemaining: 100,
            radius: spec.radius, damage: spec.damage
        ))

        var enemies = [
            Self.enemy(.victorianVendor, id: 10, at: VecI(x: 1000, y: 1200), state: .telegraph, content: content)
        ]
        _ = Self.step(&enemies, player: player, solids: [], content: content, bounds: bounds, mines: &mines)

        #expect(spec.maximum == 2)
        let owned = mines.filter { $0.ownerId == vendor }
        #expect(owned.count == spec.maximum)
        #expect(!owned.contains { $0.id == EntityID(100) })   // the oldest is gone
        #expect(owned.contains { $0.id == EntityID(200) })
        #expect(mines.contains { $0.ownerId == EntityID(11) })
    }

    /// EN-007: entering M-C at Exposure 400 goes straight to 1000 and latches
    /// Lockdown once.
    @Test func enemyEN007ForcedLockdownJumpsToOneThousandAndLatchesOnce() {
        var state = ExposureState(exposure: 400, detectionState: .observed)
        let forced = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false, forceLockdown: true)

        #expect(state.exposure == 1000)
        #expect(state.detectionState == .lockdown)
        #expect(state.lockdownEntered)
        #expect(forced.lockdownEnteredThisTick)
    }

    /// EN-008: entering M-C already locked down emits no second Lockdown.
    @Test func enemyEN008AlreadyLockedDownDoesNotEnterTwice() {
        var state = ExposureState(exposure: 400, detectionState: .observed)
        _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false, forceLockdown: true)

        let again = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false, forceLockdown: true)
        #expect(!again.lockdownEnteredThisTick)
        #expect(state.exposure == 1000)
        #expect(state.lockdownEntered)

        // And recovery never lifts it, forced or not.
        for _ in 0..<120 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false, forceLockdown: false)
        }
        #expect(state.exposure == 1000)
        #expect(state.detectionState == .lockdown)
    }

    /// EN-009: the last living enemy dying does not complete an encounter while
    /// a spawn is still queued.
    ///
    /// Completion is `spawnQueue.isEmpty && living == 0`. Drop either half and a
    /// wave can be "cleared" by killing whatever happens to be on the field
    /// during a spawn interval, with members still to come.
    ///
    /// The enemy is killed through the real damage path rather than by setting
    /// integrity directly, because only `killEnemy` decrements `living` — a
    /// corpse made by hand would leave `living` at 1 and this test would pass
    /// without ever reaching the condition it claims to check.
    @Test func enemyEN009PendingSpawnKeepsTheEncounterOpen() throws {
        var sim = try Simulation.make(seed: 1)
        // Two queued, so one can spawn and die with one still pending.
        sim.testing_activateEncounter("M-A", spawnQueue: [.autonomousInformant, .autonomousInformant])
        _ = sim.step(command: .neutral(tick: 1))

        let spawned = try #require(sim.state.encounters["M-A"])
        #expect(spawned.living == 1)
        #expect(!spawned.spawnQueue.isEmpty)

        let target = try #require(sim.state.enemies.first { $0.encounterId == "M-A" && $0.alive })
        let hp = sim.state.content.standardEnemies[.autonomousInformant]!.hp
        let shots = (hp + Targeting.enemyDamage - 1) / Targeting.enemyDamage
        for _ in 0..<shots {
            sim.testing_injectPulseHitting(position: target.position)
        }
        _ = sim.step(command: .neutral(tick: 2))

        let after = try #require(sim.state.encounters["M-A"])
        // The precondition the vector is about: nothing alive, one still queued.
        #expect(!sim.state.enemies.contains { $0.encounterId == "M-A" && $0.alive })
        #expect(after.living == 0)
        #expect(!after.spawnQueue.isEmpty)

        // And therefore still open. `completed` alone is too weak to assert:
        // removing the queue check does not complete M-A, it *advances* it to
        // wave A2 with a member of A1 still unspawned — which is the same bug
        // wearing a different hat, and only `waveIndex` sees it.
        #expect(after.waveIndex == 0)
        #expect(after.spawnQueue == [.autonomousInformant])
        #expect(!after.completed)
        #expect(sim.state.outcome == .playing)
        #expect(!sim.state.upgrade.pending)
    }

    /// EN-010: a standard enemy death produces no reward entity and no reward
    /// event — no pickup, no drop, no currency.
    @Test func enemyEN010StandardDeathDropsNothing() throws {
        var sim = try Simulation.make(seed: 1)
        let spot = VecI(
            x: sim.state.player.position.x.unitsTruncated + 120,
            y: sim.state.player.position.y.unitsTruncated
        )
        sim.testing_spawnInformant(at: spot, integrity: Targeting.enemyDamage)
        let minesBefore = sim.state.mines.count
        let enemiesBefore = sim.state.enemies.count

        sim.testing_injectPulseHitting(position: spot.asQ8)
        let result = sim.step(command: .neutral(tick: 1))

        #expect(result.events.contains { $0.type == .entityDied })
        // Nothing is created by the death: no mine, no extra body, no projectile
        // spawned from the corpse.
        #expect(sim.state.mines.count == minesBefore)
        #expect(sim.state.enemies.count <= enemiesBefore)

        // Two levels of "no reward". First, the tick itself emits nothing
        // outside the combat vocabulary.
        let allowed: Set<EventType> = [
            .projectileHit, .entityDamaged, .entityDied, .weaponFired,
            .detectionStateChanged, .exposureChanged, .waveStarted,
            .mobEncounterCompleted, .dodgeStarted
        ]
        let unexpected = Set(result.events.map(\.type)).subtracting(allowed)
        #expect(unexpected.isEmpty, "unexpected event types on a death tick: \(unexpected)")

        // Second, and more durably: the authoritative vocabulary has no
        // reward-shaped event to emit in the first place. A whitelist above
        // only guards the tick this test happens to run; this guards the
        // design, and fails the moment someone adds a pickup or a drop.
        let rewardish = ["reward", "pickup", "drop", "loot", "currency", "collect", "score"]
        for type in EventType.allCases {
            let name = type.rawValue.lowercased()
            #expect(
                !rewardish.contains { name.contains($0) },
                "\(type.rawValue) looks like a reward event; enemies-and-encounters.md EN-010 forbids one"
            )
        }
    }
}
