import Foundation
@testable import SurveillanceCore

/// T305 pacing probe: plays one whole run headlessly with `ProbePilot`,
/// records when each milestone happened, and keeps every command so the run
/// can be re-executed as a replay (T901).
///
/// Time is simulation ticks at the fixed 60 Hz rate. The upgrade overlay
/// freezes the clock, so card-reading time never appears in these numbers.
///
/// `sustained` runs are a diagnostic, not a legal run: after every tick the
/// probe restores Player Integrity to full through the test-only
/// `testing_setPlayerIntegrity` hook, so the run cannot end in death. They
/// measure how long the content takes to clear when survival is not the
/// limit. Their digests are not replayable and are never used as T901
/// evidence.
struct PacingProbe {
    struct Result: Sendable {
        var profile: String
        var sustained: Bool
        var seed: UInt64
        var upgrade: UpgradeID
        var outcome: RunOutcome
        var failureReason: String?
        /// The pilot gave up: three simulated minutes on one objective node.
        var stalledOn: String?
        var ticks: UInt64
        var digest: String
        var commands: [PlayerCommand]
        /// First tick the Player stood inside each arena zone, by zone ID.
        var zoneEntry: [String: UInt64]
        /// First tick each milestone event was published.
        var milestones: [String: UInt64]
        var playerIntegrity: Int
        var camerasDestroyed: Int
        var lockdownEntered: Bool
        /// All eight Cameras destroyed (Network Blackout).
        var networkBlackout: Bool
        /// Integrity lost, by the archetype of the damaging entity.
        var damageBySource: [String: Int]
        /// `arena.md` § 5 segment starts (D-079), measured by the core.
        var timeline: PacingTimeline
        /// D-083: every M-A/M-B wave start, the Detection State the director
        /// read, and the Informants it appended.
        var waveHeat: [WaveHeat] = []
        /// First M-C `waveStarted` tick.
        var mobCStartTick: UInt64?
        /// D-089: `enemyAlerted` events by cause.
        var alertsByCause: [String: Int] = [:]
        /// D-089: standard enemies killed, and those of them whose first hit
        /// was an ambush (it was unaware when first hit, whether or not that
        /// hit killed it).
        var standardKills = 0
        var ambushKills = 0
        /// Standard enemies whose first hit was an ambush, killed or not.
        var ambushes = 0
        /// Standard enemies spawned unaware.
        var spawnedUnaware = 0
        var standardSpawned = 0
        /// Standard enemies that spawned aware, by the spawning rule that made
        /// them so: `awareEncounter` (M-C), `surveillance` (`tracked` or above
        /// when the director read it), or `reinforcement` (D-083 heat).
        var spawnedAwareBy: [String: Int] = [:]
        /// Integrity lost before the first M-C wave started.
        var damageBeforeMobC = 0
        /// D-091: each Transit Patrol member's outcome, fixed when the first
        /// M-A wave starts (the Player has left the corridor): `ambushed` (its
        /// first damage was an ambush), `fought` (alerted before any ambush),
        /// or `sneakedPast` (still unaware, never hit).
        var patrolOutcomes: [String: Int] = [:]
        /// `enemyAlerted` causes for patrol members only.
        var patrolAlertsByCause: [String: Int] = [:]

        var seconds: Double { Double(ticks) / 60 }
        var damageTaken: Int { damageBySource.values.reduce(0, +) }
        var reinforcements: Int { waveHeat.reduce(0) { $0 + $1.added } }
    }

    struct WaveHeat: Sendable {
        var encounter: String
        var wave: String
        var tick: UInt64
        var state: DetectionState
        var added: Int
        /// The authoritative spawn queue at the wave-start tick, which the
        /// presentation-derived `added` must agree with.
        var queued: Int
        var authored: Int
        /// Highest Exposure since the previous M-A/M-B wave start (run start
        /// for A1). Not a rule input; it is here to test alternatives.
        var peakExposureSincePreviousWave: Int
        /// Cameras destroyed before this wave started.
        var camerasDestroyedBefore: Int
    }

    /// Hard ceiling: 30 simulated minutes. No accepted target is near this.
    static let tickCeiling: UInt64 = 60 * 60 * 30

    /// Events whose first occurrence marks a pacing milestone.
    static let milestoneEvents: [EventType] = [
        .detectionStateChanged, .playerDamaged, .lockdownEntered, .waveStarted,
        .mobEncounterCompleted, .upgradeSelected, .eliteActivated, .eliteDefeated,
        .bossActivated, .bossDefeated, .extractionArmed, .extractionReset,
        .runSucceeded, .runFailed,
    ]

    static func run(
        seed: UInt64,
        upgrade: UpgradeID,
        profile: ProbePilot.Profile,
        sustained: Bool = false
    ) throws -> Result {
        var sim = try Simulation.make(seed: seed)
        var pilot = ProbePilot(profile: profile, arena: sim.state.arena)
        var commands: [PlayerCommand] = []
        var zoneEntry: [String: UInt64] = [:]
        var milestones: [String: UInt64] = [:]
        var mobCompletions = 0
        // Ring of past snapshots for perception latency.
        var history: [PresentationSnapshot] = []
        var stalledOn: String?
        var damageBySource: [String: Int] = [:]
        var timeline = PacingTimeline()
        var waveHeat: [WaveHeat] = []
        var mobCStartTick: UInt64?
        var peakSinceWave = 0
        var alertsByCause: [String: Int] = [:]
        var firstHitAmbush: [EntityID: Bool] = [:]
        var seenEnemies: Set<EntityID> = []
        var standardKills = 0
        var ambushKills = 0
        var spawnedUnaware = 0
        var standardSpawned = 0
        var spawnedAwareBy: [String: Int] = [:]
        var damageBeforeMobC = 0
        let standard = Set(sim.state.content.awareness.appliesTo)
        var patrolAlerted: Set<EntityID> = []
        var patrolOutcomes: [String: Int] = [:]
        var patrolAlertsByCause: [String: Int] = [:]

        while !sim.isTerminal, sim.state.tick < tickCeiling {
            let current = PresentationSnapshot(sim.state)
            history.append(current)
            if history.count > profile.perceptionDelayTicks + 1 { history.removeFirst() }
            let perceived = history.first!

            let steer = pilot.command(perceived)
            if pilot.stalled {
                stalledOn = current.objectiveNode.rawValue
                break
            }
            let tick = sim.state.tick + 1
            let command: PlayerCommand
            if sim.state.upgrade.pending {
                command = PlayerCommand(
                    tick: tick, moveX: 0, moveY: 0, dodgePressed: false,
                    upgradeChoiceIndex: upgrade.selectionIndex
                )
            } else {
                command = PlayerCommand(
                    tick: tick, moveX: steer.moveX, moveY: steer.moveY, dodgePressed: steer.dodge
                )
            }
            commands.append(command)
            let detectionBefore = sim.state.exposure.detectionState
            let result = sim.step(command: command)
            if sustained, !sim.isTerminal { sim.testing_setPlayerIntegrity(PlayerBody.maxIntegrity) }

            // D-089 measurement. Awareness moves to `struck` only in damage
            // resolution and to `aware` only at the next enemy phase, so an
            // enemy first damaged this tick and now `struck` was ambushed.
            for enemy in sim.state.enemies where standard.contains(enemy.archetype) && !seenEnemies.contains(enemy.id) {
                seenEnemies.insert(enemy.id)
                standardSpawned += 1
                guard enemy.spawnTick == sim.state.tick else { continue }
                if enemy.awareness != .aware {
                    spawnedUnaware += 1
                } else {
                    let rules = sim.state.content.awareness
                    let cause = rules.awareEncounters.contains(enemy.encounterId) ? "awareEncounter"
                        : rules.surveillanceAlerts(detectionBefore) ? "surveillance" : "reinforcement"
                    spawnedAwareBy[cause, default: 0] += 1
                }
            }
            for event in result.events {
                switch event.type {
                case .enemyAlerted:
                    if case .string(let cause)? = event.payload["cause"] { alertsByCause[cause, default: 0] += 1 }
                    if let id = event.primaryEntityId, sim.state.enemies.first(where: { $0.id == id })?.patrol != nil {
                        patrolAlerted.insert(id)
                        if case .string(let cause)? = event.payload["cause"] { patrolAlertsByCause[cause, default: 0] += 1 }
                    }
                case .entityDamaged:
                    guard let id = event.primaryEntityId, firstHitAmbush[id] == nil,
                          let enemy = sim.state.enemies.first(where: { $0.id == id }),
                          standard.contains(enemy.archetype) else { continue }
                    firstHitAmbush[id] = enemy.awareness == .struck
                case .entityDied:
                    guard let id = event.primaryEntityId,
                          let enemy = sim.state.enemies.first(where: { $0.id == id }),
                          standard.contains(enemy.archetype) else { continue }
                    standardKills += 1
                    if firstHitAmbush[id] == true { ambushKills += 1 }
                default:
                    break
                }
            }

            for event in result.events where event.type == .playerDamaged {
                var amount = 0
                if case .integer(let value)? = event.payload["amount"] { amount = Int(value) }
                let source = event.secondaryEntityId.flatMap { id -> String? in
                    if let enemy = sim.state.enemies.first(where: { $0.id == id }) {
                        return enemy.archetype.rawValue
                    }
                    // Projectile hits name the projectile; attribute it to its owner.
                    guard let shot = sim.state.projectiles.first(where: { $0.id == id }) else { return nil }
                    let owner = sim.state.enemies.first { $0.id == shot.ownerId }?.archetype.rawValue ?? "unknown"
                    return owner + "Projectile"
                } ?? "unattributed"
                damageBySource[source, default: 0] += amount
                if mobCStartTick == nil { damageBeforeMobC += amount }
            }
            for event in result.events where event.type == .waveStarted {
                guard case .string(let encounter)? = event.payload["encounterId"],
                      case .string(let wave)? = event.payload["waveId"] else { continue }
                if encounter == "M-A", patrolOutcomes.isEmpty {
                    for member in sim.state.enemies where member.patrol != nil {
                        let outcome = firstHitAmbush[member.id] == true ? "ambushed"
                            : patrolAlerted.contains(member.id) || firstHitAmbush[member.id] == false ? "fought"
                            : "sneakedPast"
                        patrolOutcomes[outcome, default: 0] += 1
                    }
                }
                if encounter == "M-C" {
                    if mobCStartTick == nil { mobCStartTick = event.tick }
                    continue
                }
                let state = HeatCaptionProjector.stateAtWaveStart(
                    events: result.events, current: sim.state.exposure.detectionState
                )
                let authored = sim.state.content.encounters[encounter]?.waves
                    .first { $0.id == wave }?.members.reduce(0) { $0 + $1.count } ?? 0
                waveHeat.append(WaveHeat(
                    encounter: encounter,
                    wave: wave,
                    tick: event.tick,
                    state: state,
                    added: sim.state.content.heat.reinforcements(encounter: encounter, state: state),
                    queued: sim.state.encounters[encounter]?.spawnQueue.count ?? 0,
                    authored: authored,
                    peakExposureSincePreviousWave: peakSinceWave,
                    camerasDestroyedBefore: sim.state.destructions.count
                ))
                peakSinceWave = 0
            }
            peakSinceWave = max(peakSinceWave, sim.state.exposure.exposure)
            for event in result.events where milestoneEvents.contains(event.type) {
                var key = event.type.rawValue
                if event.type == .mobEncounterCompleted {
                    mobCompletions += 1
                    key += "#\(mobCompletions)"
                }
                if milestones[key] == nil { milestones[key] = event.tick }
            }
            let position = VecI(
                x: sim.state.player.position.x.unitsTruncated,
                y: sim.state.player.position.y.unitsTruncated
            )
            for zone in sim.state.arena.zones where zoneEntry[zone.id] == nil {
                if zone.aabb.contains(position) { zoneEntry[zone.id] = sim.state.tick }
            }
            let playerZone = sim.state.arena.zones.first { $0.aabb.contains(position) }?.id
            timeline.observe(tick: sim.state.tick, events: result.events, playerZone: playerZone)
        }

        return Result(
            profile: profile.name,
            sustained: sustained,
            seed: seed,
            upgrade: upgrade,
            outcome: sim.state.outcome,
            failureReason: sim.state.failureReason?.rawValue,
            stalledOn: stalledOn,
            ticks: sim.state.tick,
            digest: sim.state.digest(),
            commands: commands,
            zoneEntry: zoneEntry,
            milestones: milestones,
            playerIntegrity: sim.state.player.integrity,
            camerasDestroyed: sim.state.destructions.count,
            lockdownEntered: sim.state.exposure.lockdownEntered,
            networkBlackout: sim.state.networkBlackout,
            damageBySource: damageBySource,
            timeline: timeline,
            waveHeat: waveHeat,
            mobCStartTick: mobCStartTick,
            alertsByCause: alertsByCause,
            standardKills: standardKills,
            ambushKills: ambushKills,
            ambushes: firstHitAmbush.values.filter { $0 }.count,
            spawnedUnaware: spawnedUnaware,
            standardSpawned: standardSpawned,
            spawnedAwareBy: spawnedAwareBy,
            damageBeforeMobC: damageBeforeMobC,
            patrolOutcomes: patrolOutcomes,
            patrolAlertsByCause: patrolAlertsByCause
        )
    }

    /// Re-executes a probe's command stream through the public replay path.
    static func replay(_ result: Result) -> TickResult? {
        let envelope = ReplayEnvelope(
            identity: .current,
            seed: result.seed,
            commands: result.commands
        )
        guard case .success(let tick) = Simulation.execute(envelope) else { return nil }
        return tick
    }

    /// Canonical replay JSON, in the shape `ReplayEnvelope.load` accepts.
    static func replayJSON(_ result: Result) -> String {
        let id = ReplayIdentity.current
        var lines: [String] = []
        for c in result.commands {
            var line = "{\"tick\":\(c.tick),\"moveX\":\(c.moveX),\"moveY\":\(c.moveY),\"dodgePressed\":\(c.dodgePressed)"
            if let choice = c.upgradeChoiceIndex { line += ",\"upgradeChoiceIndex\":\(choice)" }
            lines.append(line + "}")
        }
        return """
        {"schemaVersion":"\(id.replaySchemaVersion)","rulesetVersion":"\(id.rulesetVersion)",\
        "contentVersion":"\(id.contentVersion)","arenaVersion":"\(id.arenaVersion)",\
        "seed":\(result.seed),"commands":[\(lines.joined(separator: ","))]}
        """
    }

    /// One JSON object per run, for the evidence report.
    static func reportLine(_ r: Result, replayDigests: [String]) -> String {
        func map<V>(_ m: [String: V]) -> String {
            "{" + m.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
        }
        let stalled = r.stalledOn.map { "\"\($0)\"" } ?? "null"
        let failure = r.failureReason.map { "\"\($0)\"" } ?? "null"
        let digests = replayDigests.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"profile\":\"\(r.profile)\",\"sustained\":\(r.sustained),\"seed\":\(r.seed),\"upgrade\":\"\(r.upgrade.rawValue)\","
            + "\"outcome\":\"\(r.outcome.rawValue)\",\"failureReason\":\(failure),\"stalledOn\":\(stalled),"
            + "\"ticks\":\(r.ticks),\"digest\":\"\(r.digest)\",\"replayDigests\":[\(digests)],"
            + "\"playerIntegrity\":\(r.playerIntegrity),\"camerasDestroyed\":\(r.camerasDestroyed),"
            + "\"lockdownEntered\":\(r.lockdownEntered),\"networkBlackout\":\(r.networkBlackout),"
            + "\"reinforcements\":\(r.reinforcements),"
            + "\"mobCStartTick\":\(r.mobCStartTick.map(String.init) ?? "null"),"
            + "\"alertsByCause\":\(map(r.alertsByCause)),\"standardKills\":\(r.standardKills),"
            + "\"ambushKills\":\(r.ambushKills),\"ambushes\":\(r.ambushes),"
            + "\"standardSpawned\":\(r.standardSpawned),\"spawnedUnaware\":\(r.spawnedUnaware),"
            + "\"damageTaken\":\(r.damageTaken),\"damageBeforeMobC\":\(r.damageBeforeMobC),"
            + "\"spawnedAwareBy\":\(map(r.spawnedAwareBy)),"
            + "\"patrolOutcomes\":\(map(r.patrolOutcomes)),\"patrolAlertsByCause\":\(map(r.patrolAlertsByCause)),"
            + "\"waveHeat\":[\(r.waveHeat.map { "{\"wave\":\"\($0.wave)\",\"tick\":\($0.tick),\"state\":\"\($0.state.rawValue)\",\"added\":\($0.added),\"queued\":\($0.queued),\"authored\":\($0.authored),\"peakExposure\":\($0.peakExposureSincePreviousWave),\"camerasBefore\":\($0.camerasDestroyedBefore)}" }.joined(separator: ","))],"
            + "\"damageBySource\":\(map(r.damageBySource)),"
            + "\"zoneEntry\":\(map(r.zoneEntry)),\"milestones\":\(map(r.milestones)),"
            + "\"segmentStarts\":\(map(Dictionary(uniqueKeysWithValues: r.timeline.starts.map { ($0.key.rawValue, $0.value) }))),"
            + "\"segmentsOffTarget\":[\(r.timeline.segmentsOffTarget.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]}"
    }
}
