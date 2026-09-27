import Testing
@testable import SurveillanceCore

/// D-072: four of the five standard enemies never sit in an attack state, so
/// their commit clips are held by `ReactionClipTracker` from a state transition
/// (Fog, Witch, Vendor) or a contact hit (Informant). Before this, four
/// delivered commit clips could never play (SS-runtime #87).
@Suite(.serialized)
struct CommitClipTests {
    typealias R = ReactionClipTrackerTests

    static func enemy(_ id: UInt64, _ archetype: ArchetypeID, _ state: EnemyAIState) -> EnemyBody {
        var body = R.enemy(id, archetype)
        body.state = state
        return body
    }

    static func presented(_ tracker: ReactionClipTracker, tick: UInt64, id: UInt64, _ archetype: ArchetypeID, base: String) throws -> String? {
        var snap = try R.snapshot(tick: tick, enemies: [R.sprite(id, archetype, clip: base)])
        tracker.apply(to: &snap)
        return snap.enemies[0].reactionClipId ?? snap.enemies[0].clipId
    }

    /// Leaving TELEGRAPH for COOLDOWN is the resolution tick; the commit holds
    /// for its duration (2 frames at 12 fps = 10 ticks) and then yields.
    @Test(arguments: [ArchetypeID.fogAnalyticsCloud, .sutroSignalWitch, .victorianVendor])
    func telegraphToCooldownHoldsTheCommitForItsDuration(_ role: ArchetypeID) throws {
        var tracker = try ReactionClipTracker.bundled()
        let commit = "\(role.rawValue)_commit"
        let clip = try #require(ClipCatalog.bundled().clipsById[commit])
        #expect(ReactionClipTracker.durationTicks(clip) == 10)

        tracker.ingest(
            R.result(200, []),
            previousEnemies: [Self.enemy(3, role, .telegraph)],
            currentEnemies: [Self.enemy(3, role, .cooldown)]
        )
        let base = "\(role.rawValue)_move"
        #expect(try Self.presented(tracker, tick: 200, id: 3, role, base: base) == commit)
        #expect(try Self.presented(tracker, tick: 209, id: 3, role, base: base) == commit)
        #expect(try Self.presented(tracker, tick: 210, id: 3, role, base: base) == base)
    }

    /// Staying in COOLDOWN, or entering it from anywhere but TELEGRAPH, is not
    /// a resolution. The Witch and Vendor stay in COOLDOWN between attacks.
    @Test func cooldownWithoutATelegraphIsNotACommit() throws {
        var tracker = try ReactionClipTracker.bundled()
        for previous in [EnemyAIState.cooldown, .pursue, .orbit] {
            tracker.ingest(
                R.result(50, []),
                previousEnemies: [Self.enemy(4, .sutroSignalWitch, previous)],
                currentEnemies: [Self.enemy(4, .sutroSignalWitch, .cooldown)]
            )
        }
        #expect(tracker.commits.isEmpty)
        // A newly spawned enemy has no previous state to compare.
        tracker.ingest(R.result(51, []), previousEnemies: [], currentEnemies: [Self.enemy(5, .fogAnalyticsCloud, .cooldown)])
        #expect(tracker.commits.isEmpty)
    }

    /// The Correlator's commit is its CHARGE state, projected directly; the
    /// tracker does not also hold one.
    @Test func correlatorCommitStaysAStateClip() throws {
        var tracker = try ReactionClipTracker.bundled()
        tracker.ingest(
            R.result(10, []),
            previousEnemies: [Self.enemy(6, .cableCarCorrelator, .telegraph)],
            currentEnemies: [Self.enemy(6, .cableCarCorrelator, .cooldown)]
        )
        #expect(tracker.commits.isEmpty)
        #expect(ActorClipProjection.standardClipId(role: .cableCarCorrelator, state: .charge, velocity: .zero) == "cableCarCorrelator_commit")
    }

    /// The Informant's contact hit is its commit, keyed by the hit's source.
    @Test func informantContactHitShowsItsCommit() throws {
        var tracker = try ReactionClipTracker.bundled()
        let informant = Self.enemy(8, .autonomousInformant, .pursue)
        let fog = Self.enemy(9, .fogAnalyticsCloud, .orbit)
        let hit = AuthoritativeEvent(tick: 300, phase: 12, type: .playerDamaged, primary: EntityID(1), secondary: EntityID(8), insertion: 0)
        tracker.ingest(R.result(300, [hit]), previousEnemies: [informant, fog], currentEnemies: [informant, fog])

        #expect(try Self.presented(tracker, tick: 300, id: 8, .autonomousInformant, base: "autonomousInformant_anticipate") == "autonomousInformant_commit")
        #expect(try Self.presented(tracker, tick: 310, id: 8, .autonomousInformant, base: "autonomousInformant_anticipate") == "autonomousInformant_anticipate")
        #expect(tracker.commits[EntityID(9)] == nil)
        #expect(tracker.playerReaction?.clipId == "player_hurt")
    }

    /// Damage from any other source does not make the Informant commit.
    @Test func damageFromAnotherSourceIsNotAnInformantCommit() throws {
        var tracker = try ReactionClipTracker.bundled()
        let informant = Self.enemy(8, .autonomousInformant, .pursue)
        let witch = Self.enemy(9, .sutroSignalWitch, .cooldown)
        let bolt = AuthoritativeEvent(tick: 40, phase: 12, type: .playerDamaged, primary: EntityID(1), secondary: EntityID(9), insertion: 0)
        let unsourced = AuthoritativeEvent(tick: 40, phase: 12, type: .playerDamaged, primary: EntityID(1), insertion: 1)
        tracker.ingest(R.result(40, [bolt, unsourced]), previousEnemies: [informant, witch], currentEnemies: [informant, witch])
        #expect(tracker.commits.isEmpty)
    }

    /// A commit lists hurt and defeat in its cancel windows, so a hit during
    /// it still shows the flinch; a death clears it.
    @Test func hurtCutsACommitAndDeathClearsIt() throws {
        var tracker = try ReactionClipTracker.bundled()
        tracker.ingest(
            R.result(100, []),
            previousEnemies: [Self.enemy(3, .victorianVendor, .telegraph)],
            currentEnemies: [Self.enemy(3, .victorianVendor, .cooldown)]
        )
        let vendor = Self.enemy(3, .victorianVendor, .cooldown)
        tracker.ingest(R.result(102, [R.event(.entityDamaged, 3, tick: 102)]), previousEnemies: [vendor], currentEnemies: [vendor])
        #expect(try Self.presented(tracker, tick: 102, id: 3, .victorianVendor, base: "victorianVendor_idle") == "victorianVendor_hurt")

        tracker.ingest(R.result(104, [R.event(.entityDied, 3, tick: 104)]), previousEnemies: [vendor], currentEnemies: [])
        #expect(tracker.commits.isEmpty)
    }

    @Test func resetClearsCommits() throws {
        var tracker = try ReactionClipTracker.bundled()
        tracker.ingest(
            R.result(1, []),
            previousEnemies: [Self.enemy(3, .fogAnalyticsCloud, .telegraph)],
            currentEnemies: [Self.enemy(3, .fogAnalyticsCloud, .cooldown)]
        )
        #expect(!tracker.commits.isEmpty)
        tracker.reset()
        #expect(tracker.commits.isEmpty)
    }

    /// No state projects a commit D-072 moved to the tracker, so a stale
    /// mapping cannot come back unnoticed.
    @Test func projectionNamesOnlyTheCorrelatorCommit() {
        let roles: [ArchetypeID] = [.fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch, .autonomousInformant, .victorianVendor]
        let states: [EnemyAIState] = [.pursue, .orbit, .telegraph, .resolve, .cooldown, .charge, .recover, .keepRange, .fire, .throwMine]
        for role in roles {
            for state in states {
                for velocity in [VecQ8.zero, VecQ8(unitsX: 3, unitsY: 0)] {
                    let id = ActorClipProjection.standardClipId(role: role, state: state, velocity: velocity) ?? ""
                    if id.hasSuffix("_commit") {
                        #expect(role == .cableCarCorrelator && state == .charge, "\(role) \(state) projects \(id)")
                    }
                }
            }
        }
    }
}
