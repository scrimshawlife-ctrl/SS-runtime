#if DEBUG
import CoreGraphics
import SurveillanceCore

/// DEBUG-only scripted pilot that plays a whole run.
///
/// It drives nothing but the interfaces a person drives: a normalized
/// `PlayerCommand` for movement and Dodge, and a synthetic tap in HUD point
/// space for the upgrade card. That matters — the upgrade gate is a hard
/// blocker (`Simulation.step` returns `.upgradeSelectionPending` and refuses to
/// advance until a valid choice arrives), so reaching it through the real
/// hit-test path is the only way to know the gate actually opens.
///
/// It never reads or writes authoritative state, and it is never compiled into
/// a release build.
///
/// Enable with `-SSAutopilot <scenario>`:
///
/// | Scenario | Behaviour |
/// |---|---|
/// | `run` | play the objective graph through to Extraction |
/// | `mobA` … `boss`, `extraction` | walk to one objective and hold |
///
/// `-SSAutopilotUpgrade <signalJammer\|ricochetPulse\|ghostStep>` picks which
/// countermeasure to take; the default is Ricochet Pulse.
struct DebugAutopilot {
    enum Mode {
        /// Follow the authoritative objective graph to the end.
        case fullRun
        /// Walk to one fixed point and stop.
        case waypoint(VecI)
    }

    private let mode: Mode
    private let arena: ArenaManifest
    let upgradeChoice: UpgradeID

    /// Ticks spent without the objective changing, so a wedged run gives up
    /// instead of grinding forever.
    private var ticksOnObjective = 0
    private var lastObjective: CombatAuthorityNode?
    private static let objectiveTimeoutTicks = 60 * 180

    /// Straight-line steering walks into walls. The arena is authored with
    /// solids between objectives, so the pilot detects that it has stopped
    /// moving and side-steps — a wall-follow, not pathfinding.
    private var lastPosition: VecI?
    private var stuckTicks = 0
    private var detourTicksRemaining = 0
    private var detourSign = 1
    /// Consecutive detours that failed to get the pilot closer to its target.
    private var failedDetours = 0
    /// Closest the pilot has been to the current target, so "did that detour
    /// help?" is answerable rather than assumed.
    private var bestDistanceToTarget = Int.max
    private static let stuckThresholdTicks = 20
    private static let detourTicks = 70
    private static let maxDetourTicks = 420
    private static let stuckDistanceUnits = 3
    /// Progress worth resetting the escalation for. Smaller than this is noise
    /// from the pilot jittering against a solid.
    private static let progressUnits = 24

    /// Standing still inside a fight is how the previous pilot died at a
    /// trigger. Below this range it backs away while the Civic Pulse works.
    private static let kiteRange = 180
    /// Hurt pilots back off further. M-C forces Lockdown by design, so the
    /// difference between reaching the elite and dying there is spacing.
    private static let woundedKiteRange = 340
    private static let woundedIntegrity = 45
    private static let arrivalRadius = 40
    /// combat-001 target range; there is no reason to close further.
    private static let engageRange = 460

    // MARK: - Construction

    static func fromLaunchArguments(_ arguments: [String], arena: ArenaManifest) -> DebugAutopilot? {
        guard let flag = arguments.firstIndex(of: "-SSAutopilot"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        let scenario = arguments[arguments.index(after: flag)]

        var upgrade = UpgradeID.ricochetPulse
        if let upgradeFlag = arguments.firstIndex(of: "-SSAutopilotUpgrade"),
           arguments.index(after: upgradeFlag) < arguments.endIndex,
           let parsed = UpgradeID(rawValue: arguments[arguments.index(after: upgradeFlag)])
        {
            upgrade = parsed
        }
        return DebugAutopilot(scenario: scenario, arena: arena, upgrade: upgrade)
    }

    init?(scenario: String, arena: ArenaManifest, upgrade: UpgradeID = .ricochetPulse) {
        self.arena = arena
        upgradeChoice = upgrade
        func trigger(_ encounterId: String) -> VecI? {
            arena.encounterTriggers.first { $0.id == "trigger-\(encounterId)" }?.center
        }
        switch scenario {
        case "run", "tour": mode = .fullRun
        case "mobA": guard let t = trigger("M-A") else { return nil }; mode = .waypoint(t)
        case "mobB": guard let t = trigger("M-B") else { return nil }; mode = .waypoint(t)
        case "mobC": guard let t = trigger("M-C") else { return nil }; mode = .waypoint(t)
        case "elite": guard let t = trigger("elite") else { return nil }; mode = .waypoint(t)
        case "boss": guard let t = trigger("boss") else { return nil }; mode = .waypoint(t)
        case "extraction": mode = .waypoint(arena.extraction.center)
        default: return nil
        }
    }

    // MARK: - Objective

    /// Where the current graph node wants the Player.
    private func destination(for snapshot: PresentationSnapshot) -> VecI {
        if case .waypoint(let point) = mode { return point }
        if snapshot.extractionArmed { return arena.extraction.center }
        let triggerId: String
        switch snapshot.objectiveNode {
        case .mobA: triggerId = "trigger-M-A"
        case .mobB: triggerId = "trigger-M-B"
        case .mobC: triggerId = "trigger-M-C"
        case .improperSearchDaemon: triggerId = "trigger-elite"
        case .algorithmicModerate: triggerId = "trigger-boss"
        case .extraction: return arena.extraction.center
        }
        return arena.encounterTriggers.first { $0.id == triggerId }?.center
            ?? arena.extraction.center
    }

    var stalled: Bool { ticksOnObjective >= Self.objectiveTimeoutTicks }

    /// Why the pilot did what it did last tick, for the autopilot log. A stall
    /// is only diagnosable if the intent behind a frozen position is visible.
    private(set) var lastDecision = "-"


    // MARK: - Command

    struct Command {
        var moveX: Int16 = 0
        var moveY: Int16 = 0
        var dodge = false
    }

    mutating func command(_ snapshot: PresentationSnapshot) -> Command {
        if snapshot.objectiveNode != lastObjective {
            lastObjective = snapshot.objectiveNode
            ticksOnObjective = 0
            failedDetours = 0
            bestDistanceToTarget = Int.max
        } else {
            ticksOnObjective += 1
        }

        let position = VecI(x: snapshot.player.x, y: snapshot.player.y)
        let target = destination(for: snapshot)
        let nearest = nearestEnemy(to: position, in: snapshot)

        if let last = lastPosition, distance(last, position) <= Self.stuckDistanceUnits {
            stuckTicks += 1
        } else {
            stuckTicks = 0
        }
        lastPosition = position
        // Did the last detour actually help? Only real progress toward the
        // target counts, so jitter against a solid cannot reset the escalation.
        let distanceToTarget = distance(position, target)
        if distanceToTarget + Self.progressUnits < bestDistanceToTarget {
            bestDistanceToTarget = distanceToTarget
            failedDetours = 0
        }

        if stuckTicks >= Self.stuckThresholdTicks, detourTicksRemaining == 0 {
            // Flipping the side on every detour looks like it escapes dead
            // ends, and does — but against a long wall it guarantees the pilot
            // oscillates around one spot forever, which is how it wedged at
            // M-A. Commit to a side for two attempts before trying the other,
            // and lengthen each attempt so a wall can actually be traversed.
            failedDetours += 1
            if failedDetours % 2 == 0 { detourSign = -detourSign }
            detourTicksRemaining = min(
                Self.detourTicks * failedDetours,
                Self.maxDetourTicks
            )
            stuckTicks = 0
        }
        if detourTicksRemaining > 0 { detourTicksRemaining -= 1 }

        // Extraction only completes by standing inside the zone, so contact is
        // the goal there and crowding is acceptable.
        let holdingExtraction = snapshot.extractionArmed
            && arena.extraction.aabb.contains(position)

        let kiteRange = snapshot.playerIntegrity <= Self.woundedIntegrity
            ? Self.woundedKiteRange
            : Self.kiteRange

        var command = Command()
        var reason: String
        if let nearest, !holdingExtraction, nearest.distance < kiteRange {
            // Back away along the enemy vector while the automatic weapon works.
            command = steer(from: position, away: nearest.point)
            // Dodge is a rising edge, ignored when unavailable, so pressing it
            // whenever something is close costs nothing.
            command.dodge = nearest.distance < kiteRange / 2
            reason = "kite"
        } else if distance(position, target) > Self.arrivalRadius {
            command = steer(from: position, toward: target)
            reason = "travel"
        } else if let nearest, nearest.distance > Self.engageRange {
            // Arrived, nothing in weapon range: close enough to fight.
            command = steer(from: position, toward: nearest.point)
            reason = "close"
        } else if let nearest {
            // Arrived, and the contact already sits inside weapon range but
            // outside kite range — between `kiteRange` and `engageRange`, a
            // band wider than the kite range itself. Every branch above misses
            // it, and the pilot used to hold a zero command here: standing at
            // the trigger while enemies gathered and Integrity drained.
            //
            // The band is the right place to fight, so keep it and orbit
            // instead of standing. Circling holds the range the Civic Pulse
            // wants while making the pilot a moving target.
            command = perpendicular(steer(from: position, away: nearest.point), sign: detourSign)
            reason = "orbit"
        } else {
            reason = "idle"
        }

        // Cornered: slide along the wall instead of pressing into it, which is
        // how the pilot used to get pinned. Applied to whatever was chosen
        // above — including an idle command, which a rotation alone cannot
        // rescue, since `perpendicular` of zero is still zero.
        if detourTicksRemaining > 0 {
            command = sidestep(command, position: position, target: target)
            reason += "+detour"
        }
        lastDecision = "\(reason) tgt=\(target.x),\(target.y) dTgt=\(distance(position, target))"
            + " near=\(nearest.map { String($0.distance) } ?? "-")"
            + " cmd=\(command.moveX),\(command.moveY) stuck=\(stuckTicks)"
            + " detour=\(detourTicksRemaining)/\(failedDetours)"
        return command
    }

    /// Rotate a live command a quarter turn; give an idle one a real direction.
    ///
    /// An idle command reaches here when the pilot is wedged with nothing to
    /// steer by — on top of its target, or held still by geometry. Rotating
    /// zero returns zero, so the detour would spin without ever moving. Fall
    /// back to a quarter turn off the target bearing, and to a cardinal when
    /// even that is degenerate.
    private func sidestep(_ command: Command, position: VecI, target: VecI) -> Command {
        if command.moveX != 0 || command.moveY != 0 {
            var turned = perpendicular(command, sign: detourSign)
            turned.dodge = command.dodge
            return turned
        }
        let toTarget = steer(from: position, toward: target)
        if toTarget.moveX != 0 || toTarget.moveY != 0 {
            var turned = perpendicular(toTarget, sign: detourSign)
            turned.dodge = command.dodge
            return turned
        }
        return Command(moveX: Int16(32_767 * detourSign), moveY: 0, dodge: command.dodge)
    }

    /// Where to tap when the protected upgrade overlay is open, in the same
    /// safe-rectangle point space a finger works in.
    @MainActor
    func upgradeTapPoint(projector: HUDProjector, hud: HUDRenderer) -> CGPoint? {
        hud.upgradeCardCentre(for: upgradeChoice, projector: projector)
    }

    // MARK: - Geometry

    private struct Contact {
        var point: VecI
        var distance: Int
    }

    private func nearestEnemy(to position: VecI, in snapshot: PresentationSnapshot) -> Contact? {
        var best: Contact?
        for enemy in snapshot.enemies {
            let point = VecI(x: enemy.x, y: enemy.y)
            let d = distance(position, point)
            if best == nil || d < best!.distance {
                best = Contact(point: point, distance: d)
            }
        }
        return best
    }

    private func distance(_ a: VecI, _ b: VecI) -> Int {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return Int((dx * dx + dy * dy).squareRoot())
    }

    /// Rotates a command 90 degrees, for side-stepping a solid.
    private func perpendicular(_ command: Command, sign: Int) -> Command {
        Command(
            moveX: Int16(clamping: -Int(command.moveY) * sign),
            moveY: Int16(clamping: Int(command.moveX) * sign),
            dodge: command.dodge
        )
    }

    private func steer(from: VecI, toward: VecI) -> Command {
        vector(dx: toward.x - from.x, dy: toward.y - from.y)
    }

    private func steer(from: VecI, away: VecI) -> Command {
        vector(dx: from.x - away.x, dy: from.y - away.y)
    }

    /// Full-magnitude normalized command; the controller re-normalizes and clamps.
    private func vector(dx: Int, dy: Int) -> Command {
        let magnitude = (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot()
        guard magnitude > 0 else { return Command() }
        let scale = 32_767.0 / magnitude
        return Command(
            moveX: Int16(max(-32_767, min(32_767, (Double(dx) * scale).rounded()))),
            moveY: Int16(max(-32_767, min(32_767, (Double(dy) * scale).rounded()))),
            dodge: false
        )
    }
}
#endif
