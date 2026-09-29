import Foundation
import Testing
@testable import SurveillanceCore

/// D-083 heat reinforcements: `enemies-and-encounters.md` § "Heat
/// reinforcements", vectors EN-001 and EN-011 to EN-014, and the
/// `hud-tutorial.md` caption derived from them.
@Suite(.serialized)
struct HeatReinforcementTests {
    // MARK: - Director

    /// EN-011: an M-A wave that starts while `hunted` appends two Autonomous
    /// Informants after the authored members.
    @Test func encounterEN011HuntedAppendsTwoInformantsAfterTheAuthoredMembers() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(800)
        #expect(sim.state.exposure.detectionState == .hunted)
        let result = enterTrigger("M-A", sim: &sim)

        let queue = try #require(sim.state.encounters["M-A"]).spawnQueue
        let authored = Self.authored("M-A", wave: 0, content: sim.state.content)
        #expect(queue.count == authored.count + 2)
        #expect(Array(queue.prefix(authored.count)) == authored)
        #expect(Array(queue.suffix(2)) == [.autonomousInformant, .autonomousInformant])
        #expect(result.events.contains { $0.type == .waveStarted })
    }

    /// EN-012: an M-B wave that starts while `tracked` appends one.
    @Test func encounterEN012TrackedAppendsOneInformant() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(500)
        #expect(sim.state.exposure.detectionState == .tracked)
        _ = enterTrigger("M-B", sim: &sim)

        let queue = try #require(sim.state.encounters["M-B"]).spawnQueue
        let authored = Self.authored("M-B", wave: 0, content: sim.state.content)
        #expect(queue == authored + [.autonomousInformant])
    }

    /// EN-013: M-C is unaffected. It starts in forced Lockdown and never
    /// appends, whatever the Exposure was on entry.
    @Test func encounterEN013MobCNeverAppends() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(800)
        _ = enterTrigger("M-C", sim: &sim)
        let queue = try #require(sim.state.encounters["M-C"]).spawnQueue
        #expect(queue == Self.authored("M-C", wave: 0, content: sim.state.content))
        #expect(sim.state.exposure.detectionState == .lockdown)
    }

    /// The state read is the one resolved after the previous tick, not after
    /// this tick's Exposure resolution: `observed` at 449 stays the input
    /// even when this tick's Camera contact carries Exposure into `tracked`.
    @Test func encounterHeatReadsThePreviousTicksDetectionState() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(449)
        sim.testing_activateEncounter("M-A", spawnQueue: [])
        // Park the Player in a live field so this tick's contact adds Exposure.
        let camera = sim.state.cameras[0]
        let px = camera.position.x
        let py = camera.position.y
        let ax = camera.targetAnchor.x.unitsTruncated
        let ay = camera.targetAnchor.y.unitsTruncated
        sim.testing_setPlayerPosition(VecI(x: px + (ax - px) * 3 / 2, y: py + (ay - py) * 3 / 2))
        let result = sim.step(command: .neutral(tick: 1))

        #expect(sim.state.exposure.detectionState == .tracked, "precondition: this tick crossed into tracked")
        let queue = try #require(sim.state.encounters["M-A"]).spawnQueue
        #expect(queue == Self.authored("M-A", wave: 1, content: sim.state.content), "A2 read observed: no Informants")
        #expect(result.events.contains { $0.type == .waveStarted })
    }

    /// A later wave reads the state when it starts, not when the encounter
    /// activated.
    @Test func encounterHeatAppliesToEveryMobAWave() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_activateEncounter("M-A", spawnQueue: [])
        sim.testing_setExposure(800)
        _ = sim.step(command: .neutral(tick: 1))
        let runtime = try #require(sim.state.encounters["M-A"])
        #expect(runtime.waveIndex == 1)
        #expect(runtime.spawnQueue == Self.authored("M-A", wave: 1, content: sim.state.content)
            + [.autonomousInformant, .autonomousInformant])
    }

    /// EN-015: an M-B wave that starts after Lockdown latched early, before
    /// M-C, appends the table's `lockdown` count, two.
    @Test func encounterEN015EarlyLockdownAppendsTwoInformants() throws {
        var sim = try Simulation.make(seed: 1)
        // Latch Lockdown through the real resolution: Exposure 999 plus a
        // Tamper Spike crosses 1000 in one tick.
        sim.testing_setExposure(999)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.exposure.lockdownEntered)
        #expect(sim.state.encounters["M-C"]?.activated == false, "precondition: Lockdown latched before M-C")

        _ = enterTrigger("M-B", sim: &sim)
        let queue = try #require(sim.state.encounters["M-B"]).spawnQueue
        #expect(queue == Self.authored("M-B", wave: 0, content: sim.state.content)
            + [.autonomousInformant, .autonomousInformant])
    }

    /// EN-014: an appended Informant still alive keeps the wave open after
    /// every authored member is dead; killing it lets the next wave start.
    @Test func encounterEN014AppendedInformantAliveKeepsTheWaveOpen() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_activateEncounter("M-A", spawnQueue: [])
        sim.testing_setExposure(800)
        _ = sim.step(command: .neutral(tick: 1))
        let authoredCount = Self.authored("M-A", wave: 1, content: sim.state.content).count
        #expect(sim.state.encounters["M-A"]?.spawnQueue.count == authoredCount + 2)

        var appended: Set<EntityID> = []
        var known: Set<EntityID> = Set(sim.state.enemies.map(\.id))
        // Keep the weapon quiet so only this test decides who dies.
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        for _ in 0..<600 {
            let queuedBefore = sim.state.encounters["M-A"]?.spawnQueue.count ?? 0
            sim.testing_setPlayerIntegrity(sim.state.player.maxIntegrity)
            _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
            for enemy in sim.state.enemies where enemy.encounterId == "M-A" && !known.contains(enemy.id) {
                known.insert(enemy.id)
                // The last two queued are the appended Informants.
                if queuedBefore <= 2 { appended.insert(enemy.id) }
            }
            if sim.state.encounters["M-A"]?.spawnQueue.isEmpty == true, appended.count == 2 { break }
        }
        #expect(appended.count == 2)
        #expect(sim.state.enemies.filter { appended.contains($0.id) }.allSatisfy { $0.archetype == .autonomousInformant })

        #expect(sim.state.enemies.filter { $0.encounterId == "M-A" && $0.alive }.count == authoredCount + 2,
                "precondition: nothing died while the weapon was held")

        // Kill every authored member through the real damage path. In that one
        // step the weapon can fire at most one 10-damage pulse: no Informant dies.
        sim.testing_emptyCivicPool()
        killEnemies(in: "M-A", sim: &sim) { !appended.contains($0.id) }
        let open = try #require(sim.state.encounters["M-A"])
        #expect(open.living == 2)
        #expect(open.spawnQueue.isEmpty)
        #expect(open.waveIndex == 1, "A3 must not start while an appended Informant lives")
        #expect(!open.completed)

        sim.testing_emptyCivicPool()
        killEnemies(in: "M-A", sim: &sim) { appended.contains($0.id) }
        let cleared = try #require(sim.state.encounters["M-A"])
        #expect(cleared.living == 0)
        #expect(cleared.waveIndex == 2, "A3 starts once the appended Informants are dead too")
    }

    /// EN-001: every scheduled wave completed while `hidden` spawns exactly
    /// the authored totals, A=14, B=17, C=25 (C in its forced Lockdown).
    @Test(arguments: [("M-A", 14), ("M-B", 17), ("M-C", 25)])
    func encounterEN001HiddenRunSpawnsTheAuthoredTotals(encounter: String, total: Int) throws {
        var sim = try Simulation.make(seed: 1)
        _ = enterTrigger(encounter, sim: &sim)
        for _ in 0..<6_000 {
            guard let runtime = sim.state.encounters[encounter], !runtime.completed else { break }
            if sim.state.upgrade.pending { break }
            if encounter != "M-C" {
                sim.testing_setExposure(0)
            }
            sim.testing_setPlayerIntegrity(sim.state.player.maxIntegrity)
            killEnemies(in: encounter, sim: &sim) { _ in true }
        }
        let runtime = try #require(sim.state.encounters[encounter])
        #expect(runtime.completed)
        #expect(runtime.spawned == total)
    }

    // MARK: - Content

    @Test func heatBlockDecodesFromTheBundledContract() {
        let heat = CombatContent.bundled().heat
        #expect(heat.reinforcementArchetype == .autonomousInformant)
        #expect(heat.encounters == ["M-A", "M-B"])
        #expect(heat.byDetectionState == [.hidden: 0, .observed: 0, .tracked: 1, .hunted: 2, .lockdown: 2])
        #expect(heat.reinforcements(encounter: "M-C", state: .hunted) == 0)
    }

    @Test func heatBlockFailsClosed() throws {
        let bundled = try #require(
            try JSONSerialization.jsonObject(with: BundledResource.data(name: "combat-content-004", subdirectory: "contracts"))
                as? [String: Any]
        )
        func decodeError(_ mutate: (inout [String: Any]) -> Void) -> CombatContentError? {
            var root = bundled
            mutate(&root)
            let data = try! JSONSerialization.data(withJSONObject: root)
            do {
                _ = try CombatContent.decode(data)
                return nil
            } catch {
                return error as? CombatContentError
            }
        }
        #expect(decodeError { $0["heat"] = nil } == .missingField("heat"))
        #expect(decodeError {
            var heat = $0["heat"] as! [String: Any]
            var table = heat["byDetectionState"] as! [String: Any]
            table["hunted"] = nil
            heat["byDetectionState"] = table
            $0["heat"] = heat
        } == .missingField("heat.byDetectionState.hunted"))
        #expect(decodeError {
            var heat = $0["heat"] as! [String: Any]
            var table = heat["byDetectionState"] as! [String: Any]
            table["lockdown"] = nil
            heat["byDetectionState"] = table
            $0["heat"] = heat
        } == .missingField("heat.byDetectionState.lockdown"))
        #expect(decodeError {
            var heat = $0["heat"] as! [String: Any]
            var table = heat["byDetectionState"] as! [String: Any]
            table["spotted"] = 1
            heat["byDetectionState"] = table
            $0["heat"] = heat
        } == .wrongType("heat.byDetectionState.spotted"))
        #expect(decodeError {
            var heat = $0["heat"] as! [String: Any]
            heat["reinforcementArchetype"] = "phantomCritic"
            $0["heat"] = heat
        } == .unknownArchetype("phantomCritic"))
    }

    // MARK: - Caption

    /// The caption is derived from the published events and matches what the
    /// director queued.
    @Test func captionNamesTheCountAndTheStateTheDirectorRead() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(800)
        let result = enterTrigger("M-A", sim: &sim)
        var projector = HeatCaptionProjector()
        let copy = projector.project(
            tick: result.tick,
            events: result.events,
            detection: sim.state.exposure.detectionState,
            heat: sim.state.content.heat
        )
        #expect(copy == "REINFORCEMENTS +2 • HUNTED")
        let later = projector.project(
            tick: result.tick + HeatCaptionProjector.visibleTicks - 1,
            events: [],
            detection: .hidden,
            heat: sim.state.content.heat
        )
        #expect(later == copy)
        let expired = projector.project(
            tick: result.tick + HeatCaptionProjector.visibleTicks,
            events: [],
            detection: .hidden,
            heat: sim.state.content.heat
        )
        #expect(expired == nil)
    }

    /// When the state changed in the wave-start tick, the caption uses the
    /// `before` the director read, not the new state.
    /// D-088: the chevron recipe's count comes from the same rule as the
    /// caption, so the two can never disagree.
    @Test func vfxReinforcementCountMatchesTheCaption() {
        let heat = CombatContent.bundled().heat
        let wave = AuthoritativeEvent(tick: 1, phase: 14, type: .waveStarted, payload: ["encounterId": .string("M-A"), "waveId": .string("A1")], insertion: 0)
        let mc = AuthoritativeEvent(tick: 1, phase: 14, type: .waveStarted, payload: ["encounterId": .string("M-C"), "waveId": .string("C1")], insertion: 1)
        for state in [DetectionState.hidden, .observed, .tracked, .hunted, .lockdown] {
            let count = HeatCaptionProjector.reinforcements(events: [wave], detection: state, heat: heat)
            #expect(count == heat.reinforcements(encounter: "M-A", state: state), "\(state)")
            #expect(HeatCaptionProjector.copy(count: count, state: state) != nil || count == 0)
        }
        #expect(HeatCaptionProjector.reinforcements(events: [mc], detection: .hunted, heat: heat) == 0)
        #expect(HeatCaptionProjector.reinforcements(events: [], detection: .hunted, heat: heat) == 0)
    }

    @Test func captionUsesTheStateBeforeThisTicksChange() {
        let heat = CombatContent.bundled().heat
        let events = [
            AuthoritativeEvent(tick: 5, phase: 14, type: .detectionStateChanged,
                               payload: ["before": .string("tracked"), "after": .string("hunted")], insertion: 0),
            AuthoritativeEvent(tick: 5, phase: 15, type: .waveStarted,
                               payload: ["encounterId": .string("M-B"), "waveId": .string("B2")], insertion: 1),
        ]
        var projector = HeatCaptionProjector()
        #expect(projector.project(tick: 5, events: events, detection: .hunted, heat: heat) == "REINFORCEMENTS +1 • TRACKED")
    }

    @Test func captionIsAbsentForHiddenObservedAndMobC() {
        let heat = CombatContent.bundled().heat
        func wave(_ id: String) -> [AuthoritativeEvent] {
            [AuthoritativeEvent(tick: 9, phase: 15, type: .waveStarted,
                                payload: ["encounterId": .string(id), "waveId": .string("x")], insertion: 0)]
        }
        var projector = HeatCaptionProjector()
        #expect(projector.project(tick: 9, events: wave("M-A"), detection: .observed, heat: heat) == nil)
        #expect(projector.project(tick: 9, events: wave("M-A"), detection: .hidden, heat: heat) == nil)
        #expect(projector.project(tick: 9, events: wave("M-C"), detection: .lockdown, heat: heat) == nil)
        // A wave with none clears an older caption.
        _ = projector.project(tick: 10, events: wave("M-B"), detection: .hunted, heat: heat)
        #expect(projector.project(tick: 11, events: wave("M-B"), detection: .hidden, heat: heat) == nil)
    }

    // MARK: - Helpers

    static func authored(_ encounter: String, wave: Int, content: CombatContent) -> [ArchetypeID] {
        content.encounters[encounter]!.waves[wave].members.flatMap { repeatElement($0.archetype, count: $0.count) }
    }

    /// Steps once with the Player inside the encounter's trigger.
    @discardableResult
    private func enterTrigger(_ encounter: String, sim: inout Simulation) -> TickResult {
        let trigger = sim.state.arena.encounterTriggers.first { ($0.encounterId ?? $0.id) == encounter }!
        sim.testing_setPlayerPosition(trigger.center)
        return sim.step(command: .neutral(tick: sim.state.tick + 1))
    }

    /// Kills the matching living enemies of `encounter` through the real
    /// damage path, one step.
    private func killEnemies(in encounter: String, sim: inout Simulation, where keep: (EnemyBody) -> Bool) {
        for enemy in sim.state.enemies where enemy.encounterId == encounter && enemy.alive && keep(enemy) {
            let shots = (enemy.integrity + Targeting.enemyDamage - 1) / Targeting.enemyDamage
            for _ in 0..<shots { sim.testing_injectPulseHitting(position: enemy.position) }
        }
        _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
    }
}
