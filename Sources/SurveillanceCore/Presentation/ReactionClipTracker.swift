import Foundation

/// Event-driven reaction clips: hurt, stagger, and defeat.
///
/// `clip-metadata-001` binds these clips to authoritative event markers —
/// `playerDamaged`, `entityDamaged`, `entityDied`, `eliteDefeated`,
/// `bossDefeated` — but no state machine reaches them, because damage and death
/// are events, not states. Until this type existed none was ever selected: the
/// Player's hurt, the Improper Search Daemon's hurt and defeat, and the
/// Algorithmic Moderate's stagger and defeat were delivered art that never
/// played. A defeated enemy also left the snapshot on the tick it died, so a
/// defeat clip had nothing to play on.
///
/// The tracker reads each tick's authoritative events and holds a reaction for
/// exactly its clip's duration. Which clip reacts to which event comes from the
/// clip's own marker, so a role gains reactions by adding clips to the
/// contract, with no mapping table here to fall out of date.
///
/// Presentation only (`animation.md` §1): it reads events and never writes
/// simulation state, so the replay digest cannot change. A reaction is also a
/// preference, not a replacement — the renderer tries it first and falls back
/// to the state clip, so an unbacked reaction can never hide a telegraph.
public struct ReactionClipTracker: Sendable {
    public struct Reaction: Equatable, Sendable {
        public var clipId: String
        /// Exclusive: the reaction shows while `tick < endTick`.
        public var endTick: UInt64
    }

    /// A defeated enemy held on screen for its defeat clip after it has left
    /// authoritative state.
    public struct Remains: Equatable, Sendable {
        public var sprite: PresentationSnapshot.CircleSprite
        public var endTick: UInt64
    }

    static let damageMarker = "entityDamaged"
    static let playerDamageMarker = "playerDamaged"
    static let defeatMarkers: Set<String> = ["entityDied", "eliteDefeated", "bossDefeated"]

    private let clipsById: [String: ClipRecord]
    private let hurtClipByRole: [String: ClipRecord]
    private let defeatClipByRole: [String: ClipRecord]
    private let playerHurtClip: ClipRecord?

    public private(set) var reactions: [EntityID: Reaction] = [:]
    public private(set) var remains: [EntityID: Remains] = [:]
    public private(set) var playerReaction: Reaction?

    public init(clips: [ClipRecord]) {
        // Deterministic when a role ever declares two clips for one marker:
        // the lowest clip ID wins.
        let ordered = clips.sorted { $0.clipId.utf8LessThan($1.clipId) }
        var byId: [String: ClipRecord] = [:]
        var hurt: [String: ClipRecord] = [:]
        var defeat: [String: ClipRecord] = [:]
        var playerHurt: ClipRecord?
        for clip in ordered {
            byId[clip.clipId] = clip
            let marker = clip.authoritativeEventMarker
            if clip.actorRole == "player" {
                if marker == Self.playerDamageMarker, playerHurt == nil { playerHurt = clip }
                continue
            }
            if marker == Self.damageMarker, hurt[clip.actorRole] == nil { hurt[clip.actorRole] = clip }
            if Self.defeatMarkers.contains(marker), defeat[clip.actorRole] == nil { defeat[clip.actorRole] = clip }
        }
        clipsById = byId
        hurtClipByRole = hurt
        defeatClipByRole = defeat
        playerHurtClip = playerHurt
    }

    public init(catalog: ClipCatalog) {
        self.init(clips: catalog.clips)
    }

    public static func bundled() throws -> ReactionClipTracker {
        try ReactionClipTracker(catalog: .bundled())
    }

    /// A tracker with no clips: reacts to nothing. The fallback when the
    /// contract cannot load, so presentation degrades to state clips.
    public static let empty = ReactionClipTracker(clips: [])

    /// Ticks one direction of `clip` plays for: frames ÷ fps at 60 Hz, rounded up.
    public static func durationTicks(_ clip: ClipRecord) -> UInt64 {
        guard clip.framesPerSecond > 0 else { return 0 }
        let perDirection = clip.directions.isEmpty ? clip.frameIds.count : clip.frameIds.count / clip.directions.count
        return UInt64((perDirection * 60 + clip.framesPerSecond - 1) / clip.framesPerSecond)
    }

    /// Records the reactions `result`'s events call for.
    ///
    /// `previousEnemies` is the enemy list from before the step and
    /// `currentEnemies` the list after it. A defeated enemy may already be gone
    /// from the second, so its last position and facing are taken from
    /// whichever list still holds it, preferring the later.
    public mutating func ingest(_ result: TickResult, previousEnemies: [EnemyBody], currentEnemies: [EnemyBody]) {
        let tick = result.tick
        prune(at: tick)
        func enemy(_ id: EntityID) -> EnemyBody? {
            currentEnemies.first { $0.id == id } ?? previousEnemies.first { $0.id == id }
        }
        let died = Set(result.events.filter { $0.type == .entityDied }.compactMap(\.primaryEntityId))
        for event in result.events {
            switch event.type {
            case .entityDied:
                guard let id = event.primaryEntityId, let body = enemy(id),
                      let clip = defeatClipByRole[body.archetype.rawValue] else { continue }
                reactions[id] = nil
                remains[id] = Remains(
                    sprite: PresentationSnapshot.CircleSprite(
                        id: body.id,
                        x: body.position.x.unitsTruncated,
                        y: body.position.y.unitsTruncated,
                        radius: body.radius,
                        role: body.archetype.rawValue,
                        silhouette: ActorSilhouette.enemy(body.archetype),
                        clipId: clip.clipId,
                        direction: ActorClipProjection.direction(for: body.velocity)
                    ),
                    endTick: tick + Self.durationTicks(clip)
                )
            case .entityDamaged:
                // Cameras take entityDamaged too; they are not enemies and are
                // skipped by the lookup. A killing blow shows defeat, not hurt.
                guard let id = event.primaryEntityId, !died.contains(id), let body = enemy(id),
                      let clip = hurtClipByRole[body.archetype.rawValue] else { continue }
                reactions[id] = Reaction(clipId: clip.clipId, endTick: tick + Self.durationTicks(clip))
            case .playerDamaged:
                guard let clip = playerHurtClip else { continue }
                playerReaction = Reaction(clipId: clip.clipId, endTick: tick + Self.durationTicks(clip))
            default:
                continue
            }
        }
    }

    /// Writes the reactions active at `snapshot.tick` into it.
    public func apply(to snapshot: inout PresentationSnapshot) {
        let tick = snapshot.tick
        for index in snapshot.enemies.indices {
            let sprite = snapshot.enemies[index]
            guard let reaction = reactions[sprite.id], reaction.endTick > tick,
                  let clip = clipsById[reaction.clipId],
                  mayInterrupt(sprite.clipId, with: clip)
            else { continue }
            snapshot.enemies[index].reactionClipId = reaction.clipId
        }
        snapshot.defeated = remains.values
            .filter { $0.endTick > tick }
            .map(\.sprite)
            .sorted { $0.id < $1.id }
        if let reaction = playerReaction, reaction.endTick > tick,
           let clip = clipsById[reaction.clipId],
           mayInterrupt(snapshot.playerClipId, with: clip)
        {
            snapshot.playerReactionClipId = reaction.clipId
        }
    }

    /// `animation.md` §4 `cancel_windows`: a reaction may cut the clip already
    /// playing only when that clip lists the reaction's state. No clip at all
    /// (a blockout) can always be interrupted.
    func mayInterrupt(_ base: String?, with reaction: ClipRecord) -> Bool {
        guard let base, let current = clipsById[base] else { return true }
        return current.cancelWindows.contains(reaction.state)
    }

    public mutating func reset() {
        reactions = [:]
        remains = [:]
        playerReaction = nil
    }

    private mutating func prune(at tick: UInt64) {
        reactions = reactions.filter { $0.value.endTick > tick }
        remains = remains.filter { $0.value.endTick > tick }
        if let reaction = playerReaction, reaction.endTick <= tick { playerReaction = nil }
    }
}
