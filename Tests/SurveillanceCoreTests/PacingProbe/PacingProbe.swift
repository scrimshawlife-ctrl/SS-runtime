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
        /// Integrity lost, by the archetype of the damaging entity.
        var damageBySource: [String: Int]
        /// `arena.md` § 5 segment starts (D-079), measured by the core.
        var timeline: PacingTimeline

        var seconds: Double { Double(ticks) / 60 }
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
            let result = sim.step(command: command)
            if sustained, !sim.isTerminal { sim.testing_setPlayerIntegrity(PlayerBody.maxIntegrity) }

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
            }
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
            damageBySource: damageBySource,
            timeline: timeline
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
            + "\"lockdownEntered\":\(r.lockdownEntered),"
            + "\"damageBySource\":\(map(r.damageBySource)),"
            + "\"zoneEntry\":\(map(r.zoneEntry)),\"milestones\":\(map(r.milestones)),"
            + "\"segmentStarts\":\(map(Dictionary(uniqueKeysWithValues: r.timeline.starts.map { ($0.key.rawValue, $0.value) }))),"
            + "\"segmentsOffTarget\":[\(r.timeline.segmentsOffTarget.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]}"
    }
}
