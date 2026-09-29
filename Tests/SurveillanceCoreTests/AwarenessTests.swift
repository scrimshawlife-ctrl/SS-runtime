import Foundation
import Testing
@testable import SurveillanceCore

/// D-089 awareness and ambush: `enemies-and-encounters.md` § Awareness,
/// vectors EN-016 to EN-023; `combat.md` CB-011 and CB-012; the
/// `combat-content-003` `awareness` block; and `simulation-order.md` phase 5.
@Suite(.serialized)
struct AwarenessTests {
    /// Far from the Player spawn (160, 192), clear of every solid, and more
    /// than the 160-unit sight range away.
    static let far = VecI(x: 700, y: 300)

    // MARK: - Spawning

    /// EN-016: an M-A enemy that spawns while `hidden` is unaware, holds its
    /// spawn position with zero velocity, and never attacks.
    @Test func encounterEN016HiddenSpawnIsUnawareAndHolds() throws {
        var sim = try Simulation.make(seed: 1)
        enterTrigger("M-A", sim: &sim)
        // Step back out of sight so nothing alerts it; keep the weapon quiet.
        sim.testing_setPlayerPosition(VecI(x: 160, y: 192))
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        let first = try #require(stepUntilSpawn(in: "M-A", sim: &sim))
        #expect(first.awareness == .unaware)
        #expect(first.velocity == .zero)

        var alerts: [AuthoritativeEvent] = []
        for _ in 0..<400 {
            sim.testing_setExposure(0)
            let result = sim.step(command: .neutral(tick: sim.state.tick + 1))
            alerts += result.events.filter { $0.type == .enemyAlerted }
        }
        let held = try #require(sim.state.enemies.first { $0.id == first.id })
        #expect(held.awareness == .unaware)
        #expect(held.position == first.position)
        #expect(held.velocity == .zero)
        #expect(held.state == .pursue, "no telegraph, charge, or attack state")
        #expect(alerts.isEmpty)
        #expect(sim.state.player.integrity == PlayerBody.maxIntegrity)
        #expect(sim.state.mines.isEmpty)
        #expect(!sim.state.projectiles.contains { $0.alive && ($0.kind == .sutroBolt || $0.kind == .bossBolt) })
        #expect(sim.state.enemies.filter { $0.encounterId == "M-A" }.allSatisfy { $0.awareness == .unaware })
    }

    /// EN-017: an M-A enemy that spawns while `tracked` is aware at once, and
    /// no alert is ever published for it.
    @Test func encounterEN017TrackedSpawnIsAware() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(500)
        enterTrigger("M-A", sim: &sim)
        sim.testing_setPlayerPosition(VecI(x: 160, y: 192))
        var alerts: [AuthoritativeEvent] = []
        var spawned: EnemyBody?
        for _ in 0..<200 where spawned == nil {
            sim.testing_setExposure(500)
            let result = sim.step(command: .neutral(tick: sim.state.tick + 1))
            alerts += result.events.filter { $0.type == .enemyAlerted }
            spawned = sim.state.enemies.first { $0.encounterId == "M-A" }
        }
        let enemy = try #require(spawned)
        #expect(enemy.awareness == .aware)
        #expect(alerts.isEmpty)
    }

    /// EN-018: every M-C enemy spawns aware.
    @Test func encounterEN018MobCSpawnsAware() throws {
        var sim = try Simulation.make(seed: 1)
        enterTrigger("M-C", sim: &sim)
        var spawned: [EnemyBody] = []
        for _ in 0..<400 where spawned.count < 3 {
            sim.testing_setPlayerIntegrity(PlayerBody.maxIntegrity)
            _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
            spawned = sim.state.enemies.filter { $0.encounterId == "M-C" }
        }
        #expect(spawned.count >= 3)
        #expect(spawned.allSatisfy { $0.awareness == .aware })
    }

    /// EN-018: a heat reinforcement spawns aware even when the Player has
    /// since dropped back to `hidden`, while the wave's authored members,
    /// spawned in the same state, are unaware.
    @Test func encounterEN018HeatReinforcementSpawnsAwareWhileAuthoredMembersDoNot() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(500)
        enterTrigger("M-A", sim: &sim)
        let runtime = try #require(sim.state.encounters["M-A"])
        #expect(runtime.queuedReinforcements == 1)
        sim.testing_setPlayerPosition(VecI(x: 160, y: 192))
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        var order: [EntityID] = []
        for _ in 0..<600 where (sim.state.encounters["M-A"]?.spawnQueue.isEmpty == false) {
            sim.testing_setExposure(0)
            _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
            for enemy in sim.state.enemies where enemy.encounterId == "M-A" && !order.contains(enemy.id) {
                order.append(enemy.id)
            }
        }
        let authored = HeatReinforcementTests.authored("M-A", wave: 0, content: sim.state.content).count
        #expect(order.count == authored + 1)
        let byId = Dictionary(uniqueKeysWithValues: sim.state.enemies.map { ($0.id, $0) })
        let last = try #require(order.last.flatMap { byId[$0] })
        #expect(last.archetype == .autonomousInformant)
        #expect(last.awareness == .aware)
        #expect(order.dropLast().allSatisfy { byId[$0]?.awareness == .unaware })
        #expect(sim.state.encounters["M-A"]?.queuedReinforcements == 0)
    }

    @Test func spawnRuleCoversEveryCause() {
        let spec = CombatContent.bundled().awareness
        #expect(!spec.spawnsAware(archetype: .fogAnalyticsCloud, encounter: "M-A", state: .hidden, heatReinforcement: false))
        #expect(!spec.spawnsAware(archetype: .fogAnalyticsCloud, encounter: "M-B", state: .observed, heatReinforcement: false))
        for state in [DetectionState.tracked, .hunted, .lockdown] {
            #expect(spec.spawnsAware(archetype: .victorianVendor, encounter: "M-B", state: state, heatReinforcement: false))
        }
        #expect(spec.spawnsAware(archetype: .sutroSignalWitch, encounter: "M-C", state: .hidden, heatReinforcement: false))
        #expect(spec.spawnsAware(archetype: .autonomousInformant, encounter: "M-A", state: .hidden, heatReinforcement: true))
        #expect(spec.spawnsAware(archetype: .improperSearchDaemon, encounter: "elite", state: .hidden, heatReinforcement: false))
        #expect(spec.spawnsAware(archetype: .algorithmicModerate, encounter: "boss", state: .hidden, heatReinforcement: false))
    }

    /// EN-023: the elite and the boss are never unaware.
    @Test func encounterEN023EliteAndBossAreNeverUnaware() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeEncounter("M-A")
        sim.testing_completeEncounter("M-B")
        sim.testing_completeEncounter("M-C")
        let trigger = sim.state.arena.encounterTriggers.first { $0.id == "trigger-elite" }!
        sim.testing_setPlayerPosition(trigger.center)
        _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
        let elite = try #require(sim.state.enemies.first { $0.archetype == .improperSearchDaemon })
        #expect(elite.awareness == .aware)
        #expect(sim.state.exposure.detectionState == .hidden, "precondition: spawned while hidden")

        var bossSim = try Simulation.make(seed: 1)
        bossSim.testing_completeMobAndEliteGraph()
        let bossTrigger = bossSim.state.arena.encounterTriggers.first { $0.id == "trigger-boss" }!
        bossSim.testing_setPlayerPosition(bossTrigger.center)
        _ = bossSim.step(command: .neutral(tick: bossSim.state.tick + 1))
        let boss = try #require(bossSim.state.enemies.first { $0.archetype == .algorithmicModerate })
        #expect(boss.awareness == .aware)
        #expect(bossSim.state.exposure.detectionState == .hidden)
    }

    // MARK: - Becoming alerted

    /// EN-019: within 160 units with a clear line, the enemy is alerted by
    /// sight, and it holds this tick and acts from the next.
    @Test func encounterEN019SightAlertsAndActsNextTick() throws {
        var sim = try Simulation.make(seed: 1)
        let player = VecI(x: 160, y: 192)
        sim.testing_setPlayerPosition(player)
        let spot = VecI(x: player.x + 150, y: player.y)
        let id = sim.testing_spawnStandard(.autonomousInformant, at: spot, awareness: .unaware)

        let result = sim.step(command: .neutral(tick: 1))
        let alerts = result.events.filter { $0.type == .enemyAlerted }
        #expect(alerts.count == 1)
        #expect(alerts.first?.primaryEntityId == id)
        #expect(alerts.first?.payload["cause"] == .string("sight"))
        #expect(alerts.first?.payload["entityId"] == .string(id.decimalString))
        #expect(alerts.first?.ordinal == 290)
        let alerted = try #require(sim.state.enemies.first { $0.id == id })
        #expect(alerted.awareness == .aware)
        #expect(alerted.position == spot.asQ8, "an enemy alerted this tick acts from the next")
        #expect(alerted.velocity == .zero)

        let next = sim.step(command: .neutral(tick: 2))
        #expect(!next.events.contains { $0.type == .enemyAlerted }, "published once")
        let acting = try #require(sim.state.enemies.first { $0.id == id })
        #expect(acting.position.x < spot.asQ8.x, "it pursues the Player")
    }

    /// Sight is inclusive at 160 units and does not reach 161.
    @Test func sightRangeIsInclusive() throws {
        for (offset, expected) in [(160, true), (161, false)] {
            var sim = try Simulation.make(seed: 1)
            let player = VecI(x: 160, y: 192)
            sim.testing_setPlayerPosition(player)
            let id = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: player.x + offset, y: player.y), awareness: .unaware)
            _ = sim.step(command: .neutral(tick: 1))
            #expect(sim.state.enemies.first { $0.id == id }?.awareness == (expected ? .aware : .unaware), "\(offset)")
        }
    }

    /// EN-020: 150 units away with the transit kiosk between them, the enemy
    /// stays unaware.
    @Test func encounterEN020SolidBlocksSight() throws {
        var sim = try Simulation.make(seed: 1)
        // solid-03-transit-kiosk spans x 512...640 at y 704.
        let player = VecI(x: 492, y: 704)
        sim.testing_setPlayerPosition(player)
        let id = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 642, y: 704), awareness: .unaware)
        #expect(!Collision.lineOfFireClear(from: player.asQ8, to: VecI(x: 642, y: 704).asQ8, solids: sim.state.liveSolids))
        for tick in 1...30 {
            let result = sim.step(command: .neutral(tick: UInt64(tick)))
            #expect(!result.events.contains { $0.type == .enemyAlerted })
        }
        #expect(sim.state.enemies.first { $0.id == id }?.awareness == .unaware)
    }

    /// EN-021: when Exposure crosses into `tracked`, every unaware standard
    /// enemy is alerted by surveillance at the next enemy phase, in ascending
    /// entity ID.
    @Test func encounterEN021TrackedAlertsEveryUnawareEnemy() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(449)
        parkInCameraField(&sim)
        let ids = [
            sim.testing_spawnStandard(.victorianVendor, at: VecI(x: 1500, y: 300), awareness: .unaware),
            sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 1700, y: 300), awareness: .unaware),
            sim.testing_spawnStandard(.sutroSignalWitch, at: VecI(x: 1600, y: 1400), awareness: .unaware),
        ]
        let crossing = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.exposure.detectionState == .tracked, "precondition: this tick crossed into tracked")
        #expect(!crossing.events.contains { $0.type == .enemyAlerted }, "alerts resolve at the next enemy phase")

        let result = sim.step(command: .neutral(tick: 2))
        let alerts = result.events.filter { $0.type == .enemyAlerted }
        #expect(alerts.map(\.primaryEntityId) == ids.sorted().map(Optional.some))
        #expect(alerts.allSatisfy { $0.payload["cause"] == .string("surveillance") })
        #expect(sim.state.enemies.allSatisfy { $0.awareness == .aware })
    }

    /// EN-022: the enemy that is hit is alerted by damage; an unaware enemy
    /// 100 units from it is alerted as an ally; a third, 200 units from the
    /// hit one, stays unaware.
    @Test func encounterEN022DamageAlertsAnAllyOneHop() throws {
        var sim = try Simulation.make(seed: 1)
        let hit = sim.testing_spawnStandard(.cableCarCorrelator, at: Self.far, awareness: .unaware)
        let near = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: Self.far.x, y: Self.far.y + 100), awareness: .unaware)
        let distant = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: Self.far.x, y: Self.far.y + 200), awareness: .unaware)
        sim.testing_injectPulseHitting(position: Self.far.asQ8)
        let struck = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.enemies.first { $0.id == hit }?.awareness == .struck)
        #expect(!struck.events.contains { $0.type == .enemyAlerted })

        let result = sim.step(command: .neutral(tick: 2))
        let alerts = result.events.filter { $0.type == .enemyAlerted }
        #expect(alerts.map(\.primaryEntityId) == [hit, near])
        #expect(alerts.map { $0.payload["cause"] } == [.string("damage"), .string("ally")])
        #expect(sim.state.enemies.first { $0.id == distant }?.awareness == .unaware)
    }

    /// An ally alert never propagates: the third enemy is 100 units from the
    /// ally-alerted one, but 200 from the enemy that saw the Player, and it
    /// stays unaware on this tick and every later one.
    @Test func allyAlertsNeverChain() throws {
        var sim = try Simulation.make(seed: 1)
        let player = VecI(x: 160, y: 192)
        sim.testing_setPlayerPosition(player)
        let seer = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 300, y: 192), awareness: .unaware)
        let ally = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 400, y: 192), awareness: .unaware)
        let third = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 500, y: 192), awareness: .unaware)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        let result = sim.step(command: .neutral(tick: 1))
        let alerts = result.events.filter { $0.type == .enemyAlerted }
        #expect(alerts.map(\.primaryEntityId) == [seer, ally])
        #expect(alerts.map { $0.payload["cause"] } == [.string("sight"), .string("ally")])
        _ = sim.step(command: .neutral(tick: 2))
        #expect(sim.state.enemies.first { $0.id == third }?.awareness == .unaware)
    }

    /// Surveillance outranks damage and sight: a struck enemy with the Player
    /// in sight, alerted while `tracked`, publishes cause `surveillance`.
    @Test func surveillanceTakesPrecedenceOverDamageAndSight() throws {
        var sim = try Simulation.make(seed: 1)
        let player = VecI(x: 160, y: 192)
        sim.testing_setPlayerPosition(player)
        let struck = sim.testing_spawnStandard(.cableCarCorrelator, at: VecI(x: 260, y: 192), awareness: .struck)
        let seen = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 160, y: 300), awareness: .unaware)
        sim.testing_setExposure(500)
        let result = sim.step(command: .neutral(tick: 1))
        let alerts = result.events.filter { $0.type == .enemyAlerted }
        #expect(alerts.map(\.primaryEntityId) == [struck, seen])
        #expect(alerts.allSatisfy { $0.payload["cause"] == .string("surveillance") })
    }

    /// Damage outranks sight.
    @Test func damageTakesPrecedenceOverSight() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setPlayerPosition(VecI(x: 160, y: 192))
        let id = sim.testing_spawnStandard(.cableCarCorrelator, at: VecI(x: 260, y: 192), awareness: .struck)
        let result = sim.step(command: .neutral(tick: 1))
        let alert = try #require(result.events.first { $0.type == .enemyAlerted })
        #expect(alert.primaryEntityId == id)
        #expect(alert.payload["cause"] == .string("damage"))
    }

    // MARK: - Unaware behaviour

    /// An unaware enemy overlapping the Player deals no contact damage; the
    /// same enemy aware does. Sight is set to zero so contact cannot alert it.
    @Test func unawareEnemyDealsNoContactDamage() throws {
        var content = CombatContent.bundled()
        content.awareness.sightRangeUnits = 0
        for (awareness, damaged) in [(EnemyAwareness.unaware, false), (.aware, true)] {
            var sim = try Simulation(seed: 1, arena: ArenaManifest.bundled(), content: content)
            let player = VecI(x: 160, y: 192)
            sim.testing_setPlayerPosition(player)
            sim.testing_fillCivicPool(count: Targeting.activeCeiling)
            // Speed zero so the aware one stays in contact.
            let id = sim.testing_spawnStandard(.cableCarCorrelator, at: VecI(x: 170, y: 192), speed: 0, awareness: awareness, nextSpecialTick: 10_000)
            for tick in 1...60 { _ = sim.step(command: .neutral(tick: UInt64(tick))) }
            #expect((sim.state.player.integrity < PlayerBody.maxIntegrity) == damaged, "\(awareness)")
            #expect(sim.state.enemies.first { $0.id == id }?.awareness == awareness)
        }
    }

    // MARK: - Ambush

    /// CB-011: the first hit on an unaware 20-Integrity enemy deals 20
    /// (10 x 2); it dies.
    @Test func combatCB011AmbushKillsATwentyIntegrityEnemy() throws {
        var sim = try Simulation.make(seed: 1)
        let id = sim.testing_spawnStandard(.fogAnalyticsCloud, at: Self.far, awareness: .unaware)
        sim.testing_injectPulseHitting(position: Self.far.asQ8)
        let result = sim.step(command: .neutral(tick: 1))
        let damage = result.events.filter { $0.type == .entityDamaged && $0.primaryEntityId == id }
        #expect(damage.map { $0.payload["amount"] } == [.integer(20)])
        #expect(result.events.contains { $0.type == .entityDied && $0.primaryEntityId == id })
        #expect(!(sim.state.enemies.first { $0.id == id }?.alive ?? true))
    }

    /// CB-012: two hits in one tick on an unaware 40-Integrity enemy: the
    /// first deals 20 (ambush), the second 10.
    @Test func combatCB012OnlyTheFirstHitIsAnAmbush() throws {
        var sim = try Simulation.make(seed: 1)
        let id = sim.testing_spawnStandard(.cableCarCorrelator, at: Self.far, awareness: .unaware)
        sim.testing_injectPulseHitting(position: Self.far.asQ8)
        sim.testing_injectPulseHitting(position: Self.far.asQ8)
        let result = sim.step(command: .neutral(tick: 1))
        let damage = result.events.filter { $0.type == .entityDamaged && $0.primaryEntityId == id }
        #expect(damage.map { $0.payload["amount"] } == [.integer(20), .integer(10)])
        let enemy = try #require(sim.state.enemies.first { $0.id == id })
        #expect(enemy.integrity == 10)
        #expect(enemy.awareness == .struck)
    }

    /// A hit on an aware enemy, or on a struck one in a later tick, is normal.
    @Test func awareAndStruckEnemiesTakeNormalDamage() throws {
        for awareness in [EnemyAwareness.aware, .struck] {
            var sim = try Simulation.make(seed: 1)
            let id = sim.testing_spawnStandard(.cableCarCorrelator, at: Self.far, awareness: awareness)
            sim.testing_injectPulseHitting(position: Self.far.asQ8)
            let result = sim.step(command: .neutral(tick: 1))
            let damage = result.events.filter { $0.type == .entityDamaged && $0.primaryEntityId == id }
            #expect(damage.map { $0.payload["amount"] } == [.integer(10)], "\(awareness)")
        }
    }

    // MARK: - Digest

    @Test func awarenessIsDigested() throws {
        var a = try Simulation.make(seed: 1)
        var b = try Simulation.make(seed: 1)
        a.testing_spawnStandard(.fogAnalyticsCloud, at: Self.far, awareness: .unaware)
        b.testing_spawnStandard(.fogAnalyticsCloud, at: Self.far, awareness: .aware)
        #expect(a.state.digest() != b.state.digest())
    }

    // MARK: - Content

    @Test func awarenessBlockDecodesFromTheBundledContract() {
        let spec = CombatContent.bundled().awareness
        #expect(spec.appliesTo == [.fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch, .autonomousInformant, .victorianVendor])
        #expect(spec.sightRangeUnits == 160)
        #expect(spec.allyAlertRadiusUnits == 128)
        #expect(spec.surveillanceAlertState == .tracked)
        #expect(spec.ambushDamageMultiplier == 2)
        #expect(spec.awareEncounters == ["M-C"])
        #expect(spec.heatReinforcementsSpawnAware)
        #expect(!spec.surveillanceAlerts(.observed))
        #expect(spec.surveillanceAlerts(.tracked) && spec.surveillanceAlerts(.hunted) && spec.surveillanceAlerts(.lockdown))
    }

    @Test func awarenessBlockFailsClosed() throws {
        let bundled = try #require(
            try JSONSerialization.jsonObject(with: BundledResource.data(name: "combat-content-003", subdirectory: "contracts"))
                as? [String: Any]
        )
        func decodeError(_ key: String?, _ value: Any?) -> CombatContentError? {
            var root = bundled
            if let key {
                var block = root["awareness"] as! [String: Any]
                block[key] = value
                root["awareness"] = block
            } else {
                root["awareness"] = value
            }
            let data = try! JSONSerialization.data(withJSONObject: root)
            do {
                _ = try CombatContent.decode(data)
                return nil
            } catch {
                return error as? CombatContentError
            }
        }
        #expect(decodeError(nil, nil) == .missingField("awareness"))
        #expect(decodeError(nil, [1, 2]) == .wrongType("awareness"))
        for key in ["appliesTo", "sightRangeUnits", "allyAlertRadiusUnits", "surveillanceAlertState",
                    "ambushDamageMultiplier", "awareEncounters", "heatReinforcementsSpawnAware"] {
            #expect(decodeError(key, nil) == .missingField("awareness.\(key)"), "\(key)")
        }
        #expect(decodeError("sightRangeUnits", "160") == .wrongType("awareness.sightRangeUnits"))
        #expect(decodeError("sightRangeUnits", true) == .wrongType("awareness.sightRangeUnits"))
        #expect(decodeError("sightRangeUnits", 0) == .wrongType("awareness.sightRangeUnits"))
        #expect(decodeError("allyAlertRadiusUnits", -1) == .wrongType("awareness.allyAlertRadiusUnits"))
        #expect(decodeError("ambushDamageMultiplier", 0) == .wrongType("awareness.ambushDamageMultiplier"))
        #expect(decodeError("ambushDamageMultiplier", 2.5) == .wrongType("awareness.ambushDamageMultiplier"))
        #expect(decodeError("surveillanceAlertState", "spotted") == .wrongType("awareness.surveillanceAlertState"))
        #expect(decodeError("heatReinforcementsSpawnAware", 1) == .wrongType("awareness.heatReinforcementsSpawnAware"))
        #expect(decodeError("heatReinforcementsSpawnAware", "true") == .wrongType("awareness.heatReinforcementsSpawnAware"))
        #expect(decodeError("awareEncounters", "M-C") == .wrongType("awareness.awareEncounters"))
        #expect(decodeError("appliesTo", ["phantomCritic"]) == .unknownArchetype("phantomCritic"))
        #expect(decodeError("appliesTo", ["fogAnalyticsCloud", "improperSearchDaemon"]) == .wrongType("awareness.appliesTo"))
        #expect(decodeError("appliesTo", ["algorithmicModerate"]) == .wrongType("awareness.appliesTo"))
        #expect(decodeError("appliesTo", "fogAnalyticsCloud") == .wrongType("awareness.appliesTo"))
        #expect(decodeError("sightRange", 160) == .wrongType("awareness.sightRange"))
    }

    // MARK: - Presentation

    /// animation.md § 8a: an unaware enemy presents its idle clip and the
    /// snapshot flags it for the `?` marker; presentation writes nothing.
    @Test func snapshotFlagsUnawareEnemiesWithTheirIdleClip() throws {
        var sim = try Simulation.make(seed: 1)
        let unaware = sim.testing_spawnStandard(.cableCarCorrelator, at: Self.far, awareness: .unaware)
        let aware = sim.testing_spawnStandard(.cableCarCorrelator, at: VecI(x: 900, y: 300), awareness: .aware)
        let before = sim.state
        let snap = PresentationSnapshot(sim.state)
        #expect(sim.state == before)
        let a = try #require(snap.enemies.first { $0.id == unaware })
        let b = try #require(snap.enemies.first { $0.id == aware })
        #expect(a.unaware && !b.unaware)
        #expect(a.clipId == "cableCarCorrelator_idle")
    }

    /// `enemyAlerted` projects the `enemyAlerted` recipe at the alerted
    /// enemy, and the reduced variant under Reduced Motion or Reduced Flash.
    @Test func enemyAlertedProjectsTheExclamationRecipe() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        let event = AuthoritativeEvent(
            tick: 3, phase: 5, type: .enemyAlerted, primary: EntityID(42),
            payload: ["entityId": .string("42"), "cause": .string("sight")], insertion: 0
        )
        for (settings, language) in [
            (PresentationVFXSettings.standard, "exclamationPopAboveActor"),
            (PresentationVFXSettings(reducedMotion: true), "staticExclamationAboveActor"),
            (PresentationVFXSettings(reducedFlash: true), "staticExclamationAboveActor"),
        ] {
            var projector = VFXProjector()
            let projection = projector.project(tick: 3, events: [event], catalog: catalog, settings: settings)
            #expect(projection.presentations.count == 1)
            let pop = try #require(projection.presentations.first)
            #expect(pop.recipeId == "enemyAlerted")
            #expect(pop.language == language)
            #expect(pop.sourceEntityId == EntityID(42))
            #expect(pop.hitStopMs == 0 && !pop.screenShake)
        }
    }

    /// `hud-tutorial.md`: the copy shows once, the first time an unaware
    /// enemy is on screen, for 300 ticks.
    @Test func hintShowsOnceWhenTheFirstUnawareEnemyIsOnScreen() throws {
        var sim = try Simulation.make(seed: 1)
        var hint = AwarenessHintProjector()
        #expect(hint.project(PresentationSnapshot(sim.state)) == nil)
        // Off screen: no copy.
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 2000, y: 1400), awareness: .unaware)
        #expect(hint.project(PresentationSnapshot(sim.state)) == nil)
        // On screen, out of sight.
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 500, y: 192), awareness: .unaware)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        _ = sim.step(command: .neutral(tick: 1))
        #expect(hint.project(PresentationSnapshot(sim.state)) == "UNSEEN ENEMIES HOLD • STRIKE FIRST FOR DOUBLE DAMAGE")
        for tick in 2...300 { _ = sim.step(command: .neutral(tick: UInt64(tick))) }
        #expect(hint.project(PresentationSnapshot(sim.state)) != nil, "tick 300 is the 300th tick shown")
        _ = sim.step(command: .neutral(tick: 301))
        #expect(hint.project(PresentationSnapshot(sim.state)) == nil)
    }

    // MARK: - Helpers

    /// Steps once with the Player inside the encounter's trigger.
    private func enterTrigger(_ encounter: String, sim: inout Simulation) {
        let trigger = sim.state.arena.encounterTriggers.first { ($0.encounterId ?? $0.id) == encounter }!
        sim.testing_setPlayerPosition(trigger.center)
        _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
    }

    /// Steps with Exposure held at zero until `encounter` spawns its first
    /// enemy, and returns it.
    private func stepUntilSpawn(in encounter: String, sim: inout Simulation) -> EnemyBody? {
        for _ in 0..<300 {
            sim.testing_setExposure(0)
            _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
            if let enemy = sim.state.enemies.first(where: { $0.encounterId == encounter }) { return enemy }
        }
        return nil
    }

    /// Places the Player inside the first Camera's live field, so this tick's
    /// contact adds Exposure (as `HeatReinforcementTests` does).
    private func parkInCameraField(_ sim: inout Simulation) {
        let camera = sim.state.cameras[0]
        let px = camera.position.x
        let py = camera.position.y
        let ax = camera.targetAnchor.x.unitsTruncated
        let ay = camera.targetAnchor.y.unitsTruncated
        sim.testing_setPlayerPosition(VecI(x: px + (ax - px) * 3 / 2, y: py + (ay - py) * 3 / 2))
    }
}
