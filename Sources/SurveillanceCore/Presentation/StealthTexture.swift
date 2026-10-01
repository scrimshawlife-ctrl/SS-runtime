import Foundation

// D-097 stealth texture (animation.md § 8c): the takedown, the takedown
// streak, and the patrol near-miss. Presentation only. Everything here reads
// a tick's events and the enemy lists either side of it; nothing is ever an
// input to `Simulation`, so the digest and the receipt cannot change.

public enum StealthTexture {
    /// § 8c: a 70 ms hit-stop on a takedown.
    public static let takedownHitStopMs = 70
    /// § 8c: `impact_enemy` played 4 semitones lower.
    public static let takedownPitchCents = -400
    /// § 8c: the HUD caption `TAKEDOWN` (the caption stack upper-cases it).
    public static let takedownCaption = "Takedown"
    /// Not an `audio-haptics-001` cue: a caption-only entry, classed routine
    /// by `CaptionClass.of` because it is not a safety cue.
    public static let takedownCueId = "takedown"
    /// § 8c near miss: 1.25 × the cone range, as a ratio.
    public static let nearMissRangeNumerator = 5
    public static let nearMissRangeDenominator = 4

    /// The tick's audio with each takedown's `impact_enemy` voice pitched down
    /// and one `TAKEDOWN` caption added. Other cues are untouched.
    public static func decorate(_ audio: AudioProjection, takedowns: [EntityID]) -> AudioProjection {
        guard !takedowns.isEmpty else { return audio }
        var audio = audio
        let targets = Set(takedowns)
        for index in audio.cues.indices
        where audio.cues[index].audioId == "impact_enemy"
            && audio.cues[index].sourceEntityId.map(targets.contains) == true
        {
            audio.cues[index].pitchCents = takedownPitchCents
        }
        let next = (audio.captionCues.map(\.sequence).max() ?? -1) + 1
        audio.captionCues.append(
            .presentation(
                audioId: takedownCueId,
                caption: takedownCaption,
                priority: 6,
                sourceEntityId: takedowns.first,
                sequence: next
            )
        )
        return audio
    }
}

/// Finds takedowns and keeps the streak (§ 8c).
///
/// A takedown is an ambush hit that kills its target. The event stream does
/// not flag ambushes, so the rule is reconstructed from the same facts the
/// simulation used: the enemy died this tick, it was `unaware` (never struck)
/// at the end of the previous tick, and no `enemyAlerted` for it was published
/// this tick (the alert phase runs before the damage phase, so an alerted
/// enemy's hit is not an ambush). Its first hit this tick was then the ambush
/// (`AwarenessSystem.hitDamage`).
public struct TakedownTracker: Equatable, Sendable {
    /// Consecutive takedowns since an enemy last became aware.
    public private(set) var streak = 0
    public private(set) var total = 0

    public init() {}

    public mutating func reset() {
        self = TakedownTracker()
    }

    /// Ingests one tick. Returns this tick's takedowns, by ascending ID.
    ///
    /// Order inside the tick follows the simulation's phase order: an enemy
    /// becoming aware (alert phase, or spawning aware) resets the streak
    /// first, then this tick's takedowns count up from there.
    @discardableResult
    public mutating func ingest(
        events: [AuthoritativeEvent],
        before: [EnemyBody],
        after: [EnemyBody]
    ) -> [EntityID] {
        let takedowns = Self.takedowns(events: events, before: before)
        if Self.anyBecameAware(before: before, after: after) { streak = 0 }
        streak += takedowns.count
        total += takedowns.count
        return takedowns
    }

    public static func takedowns(events: [AuthoritativeEvent], before: [EnemyBody]) -> [EntityID] {
        let unaware = Set(before.filter { $0.alive && $0.awareness == .unaware }.map(\.id))
        let alerted = Set(events.filter { $0.type == .enemyAlerted }.compactMap(\.primaryEntityId))
        return events
            .filter { $0.type == .entityDied }
            .compactMap(\.primaryEntityId)
            .filter { unaware.contains($0) && !alerted.contains($0) }
            .sorted()
    }

    /// True when a living enemy is `aware` after the tick and was not aware
    /// (or did not exist) before it: an alert, or an enemy that spawned aware.
    public static func anyBecameAware(before: [EnemyBody], after: [EnemyBody]) -> Bool {
        let wasAware = Set(before.filter { $0.awareness == .aware }.map(\.id))
        return after.contains { $0.alive && $0.awareness == .aware && !wasAware.contains($0.id) }
    }

    /// § 8c HUD copy, `TAKEDOWN ×3`. Shown from the second consecutive
    /// takedown: a single one already has its caption, ring, and sound.
    public var hudCopy: String? {
        streak >= 2 ? "TAKEDOWN ×\(streak)" : nil
    }
}

/// § 8c near miss: the patrol members whose cone edge brightens.
public enum PatrolNearMiss {
    /// Members (ascending ID) the Player is within 1.25 × cone range of and
    /// inside the half-angle of, but who do not see the Player (outside the
    /// true range, or behind a solid). Uses the rule's own integer cone test
    /// with only the range scaled, so the bright edge can never disagree with
    /// `PatrolSystem.sees` about what "seen" means.
    public static func members(_ state: WorldState) -> [EntityID] {
        let spec = state.content.patrol
        var wide = spec
        wide.sightUnits = spec.sightUnits * StealthTexture.nearMissRangeNumerator
            / StealthTexture.nearMissRangeDenominator
        let solids = state.liveSolids
        let player = state.player.position
        return state.enemies
            .filter { $0.alive && $0.awareness != .aware && $0.patrol != nil }
            .filter { member in
                guard let facing = member.patrol?.facing, facing != .zero else { return false }
                return PatrolSystem.inCone(origin: member.position, facing: facing, point: player, spec: wide)
                    && !PatrolSystem.sees(member: member, player: player, spec: spec, solids: solids)
            }
            .map(\.id)
            .sorted()
    }

    /// Edge brightness 0…1 at `frame` (display frames). A 1 s pulse between
    /// 0.6 and 1; Reduced Motion holds a steady bright edge.
    public static func edgeIntensity(frame: UInt64, reducedMotion: Bool) -> Double {
        guard !reducedMotion else { return 1 }
        let phase = Double(frame % 60) / 60
        return 0.8 + 0.2 * cos(phase * 2 * .pi)
    }
}
