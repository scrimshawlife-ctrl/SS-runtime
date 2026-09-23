import Testing
@testable import SurveillanceCore

/// Event-driven hurt, stagger, and defeat clips, against the real bundled
/// `clip-metadata-001`. Before `ReactionClipTracker`, none of these delivered
/// clips was ever selected: damage and death are events, and no state machine
/// reached them.
@Suite(.serialized)
struct ReactionClipTrackerTests {
    static func enemy(_ id: UInt64, _ archetype: ArchetypeID, integrity: Int = 10, x: Int = 300, vx: Int = 0) -> EnemyBody {
        EnemyBody(
            id: EntityID(id), archetype: archetype,
            position: VecQ8(unitsX: x, unitsY: 400), velocity: VecQ8(unitsX: vx, unitsY: 0),
            integrity: integrity, radius: 20, speedUnitsPerSecond: 100, contactDps: 5,
            state: .pursue, stateTicks: 0, spawnTick: 0, nextSpecialTick: 0,
            lockPosition: nil, encounterId: "M-A"
        )
    }

    static func event(_ type: EventType, _ id: UInt64?, tick: UInt64, insertion: Int = 0) -> AuthoritativeEvent {
        AuthoritativeEvent(tick: tick, phase: 10, type: type, primary: id.map { EntityID($0) }, insertion: insertion)
    }

    static func result(_ tick: UInt64, _ events: [AuthoritativeEvent]) -> TickResult {
        TickResult(tick: tick, events: events, digest: "", outcome: .playing)
    }

    /// A real snapshot, with the actors under test swapped in.
    static func snapshot(tick: UInt64, enemies: [PresentationSnapshot.CircleSprite] = [], playerClip: String = "player_idle") throws -> PresentationSnapshot {
        var snap = PresentationSnapshot(try Simulation.make(seed: 1).state)
        snap.tick = tick
        snap.enemies = enemies
        snap.playerClipId = playerClip
        return snap
    }

    static func sprite(_ id: UInt64, _ archetype: ArchetypeID, clip: String?) -> PresentationSnapshot.CircleSprite {
        PresentationSnapshot.CircleSprite(
            id: EntityID(id), x: 300, y: 400, radius: 20, role: archetype.rawValue,
            silhouette: ActorSilhouette.enemy(archetype), clipId: clip, direction: "s"
        )
    }

    @Test func durationIsFramesOverFpsInTicks() throws {
        let clips = try ClipCatalog.bundled().clipsById
        // 3 frames at 20 fps = 0.15 s = 9 ticks.
        #expect(ReactionClipTracker.durationTicks(try #require(clips["player_hurt"])) == 9)
        #expect(ReactionClipTracker.durationTicks(try #require(clips["improperSearchDaemon_hurt"])) == 9)
        // 6 frames at 12 fps = 0.5 s = 30 ticks.
        #expect(ReactionClipTracker.durationTicks(try #require(clips["improperSearchDaemon_defeat"])) == 30)
    }

    @Test func eliteDamageShowsItsHurtClipForExactlyItsDuration() throws {
        var tracker = try ReactionClipTracker.bundled()
        let daemon = Self.enemy(7, .improperSearchDaemon)
        tracker.ingest(Self.result(100, [Self.event(.entityDamaged, 7, tick: 100)]), previousEnemies: [daemon], currentEnemies: [daemon])

        for (tick, expected) in [(UInt64(100), "improperSearchDaemon_hurt"), (108, "improperSearchDaemon_hurt"), (109, nil)] {
            var snap = try Self.snapshot(tick: tick, enemies: [Self.sprite(7, .improperSearchDaemon, clip: "improperSearchDaemon_pursuit")])
            tracker.apply(to: &snap)
            #expect(snap.enemies[0].reactionClipId == expected, "tick \(tick)")
        }
    }

    /// The Moderate's reaction is its `stagger` clip — found by marker, not by
    /// name — and its attack clips cancel only on defeat, so a stagger never
    /// cuts a wind-up the contract protects.
    @Test func moderateStaggersOnlyWhenNoAttackIsPlaying() throws {
        var tracker = try ReactionClipTracker.bundled()
        let moderate = Self.enemy(9, .algorithmicModerate)
        tracker.ingest(Self.result(50, [Self.event(.entityDamaged, 9, tick: 50)]), previousEnemies: [moderate], currentEnemies: [moderate])

        var idle = try Self.snapshot(tick: 50, enemies: [Self.sprite(9, .algorithmicModerate, clip: nil)])
        tracker.apply(to: &idle)
        #expect(idle.enemies[0].reactionClipId == "algorithmicModerate_stagger")

        var attacking = try Self.snapshot(tick: 50, enemies: [Self.sprite(9, .algorithmicModerate, clip: "algorithmicModerate_safetyRationale")])
        tracker.apply(to: &attacking)
        #expect(attacking.enemies[0].reactionClipId == nil)
    }

    /// A killing blow shows defeat, not hurt, and the defeated actor is held
    /// at its last position for the defeat clip even though it has left state.
    @Test func killingBlowHoldsTheDefeatClipAfterTheEnemyIsGone() throws {
        var tracker = try ReactionClipTracker.bundled()
        let daemon = Self.enemy(7, .improperSearchDaemon, integrity: 5, x: 640, vx: -3)
        tracker.ingest(
            Self.result(200, [Self.event(.entityDamaged, 7, tick: 200, insertion: 0), Self.event(.entityDied, 7, tick: 200, insertion: 1)]),
            previousEnemies: [daemon], currentEnemies: []
        )
        #expect(tracker.reactions[EntityID(7)] == nil)

        var during = try Self.snapshot(tick: 229)
        tracker.apply(to: &during)
        let fallen = try #require(during.defeated.first)
        #expect(fallen.clipId == "improperSearchDaemon_defeat")
        #expect(fallen.x == 640)
        #expect(fallen.direction == "w")

        var after = try Self.snapshot(tick: 230)
        tracker.apply(to: &after)
        #expect(after.defeated.isEmpty)
    }

    /// Simulation order puts damage (phase 9) before death (phase 10), but the
    /// tracker must not depend on it: a killing blow shows defeat whatever
    /// order its events arrive in.
    @Test func killingBlowShowsDefeatNotHurtInEitherEventOrder() throws {
        var tracker = try ReactionClipTracker.bundled()
        let daemon = Self.enemy(7, .improperSearchDaemon, integrity: 5)
        tracker.ingest(
            Self.result(300, [Self.event(.entityDied, 7, tick: 300, insertion: 0), Self.event(.entityDamaged, 7, tick: 300, insertion: 1)]),
            previousEnemies: [daemon], currentEnemies: []
        )
        #expect(tracker.reactions[EntityID(7)] == nil)
        #expect(tracker.remains[EntityID(7)]?.sprite.clipId == "improperSearchDaemon_defeat")
    }

    /// `player_dodge` and `player_extraction` do not list `hurt` in their cancel
    /// windows, and a terminal clip lists nothing, so none of them is cut.
    @Test(arguments: [("player_move", "player_hurt"), ("player_idle", "player_hurt"), ("player_dodge", nil), ("player_extraction", nil), ("player_defeat", nil)])
    func playerHurtRespectsCancelWindows(base: String, expected: String?) throws {
        var tracker = try ReactionClipTracker.bundled()
        tracker.ingest(Self.result(10, [Self.event(.playerDamaged, 1, tick: 10)]), previousEnemies: [], currentEnemies: [])
        var snap = try Self.snapshot(tick: 10, playerClip: base)
        tracker.apply(to: &snap)
        #expect(snap.playerReactionClipId == expected)
    }

    /// Cameras take `entityDamaged` too. They are not enemies and have their own
    /// presentation, so the tracker must not react to them.
    @Test func damageToANonEnemyIsIgnored() throws {
        var tracker = try ReactionClipTracker.bundled()
        tracker.ingest(Self.result(10, [Self.event(.entityDamaged, 42, tick: 10)]), previousEnemies: [], currentEnemies: [])
        #expect(tracker.reactions.isEmpty)
        #expect(tracker.remains.isEmpty)
    }

    /// A role gets reactions only by declaring marker clips; nothing is inferred.
    @Test func aTrackerWithNoMarkerClipsReactsToNothing() throws {
        var tracker = ReactionClipTracker.empty
        let daemon = Self.enemy(7, .improperSearchDaemon)
        tracker.ingest(
            Self.result(5, [Self.event(.entityDamaged, 7, tick: 5), Self.event(.entityDied, 7, tick: 5), Self.event(.playerDamaged, 1, tick: 5)]),
            previousEnemies: [daemon], currentEnemies: []
        )
        #expect(tracker.reactions.isEmpty && tracker.remains.isEmpty && tracker.playerReaction == nil)
    }

    @Test func resetClearsEveryReaction() throws {
        var tracker = try ReactionClipTracker.bundled()
        let daemon = Self.enemy(7, .improperSearchDaemon)
        tracker.ingest(
            Self.result(5, [Self.event(.entityDamaged, 7, tick: 5), Self.event(.playerDamaged, 1, tick: 5)]),
            previousEnemies: [daemon], currentEnemies: [daemon]
        )
        tracker.reset()
        #expect(tracker.reactions.isEmpty && tracker.remains.isEmpty && tracker.playerReaction == nil)
    }
}
