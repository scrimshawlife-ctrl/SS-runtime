import Testing
@testable import SurveillanceCore

/// D-071 (T602): a standard enemy presents every authoritative state, not only
/// its attack. Before this, a standard enemy showed art while telegraphing and a
/// blockout the rest of the time.
@Suite struct StandardEnemyClipProjectionTests {
    static let moving = VecQ8(unitsX: 2, unitsY: 0)

    @Test(arguments: [
        (ArchetypeID.fogAnalyticsCloud, EnemyAIState.orbit, "fogAnalyticsCloud_move"),
        (.fogAnalyticsCloud, .cooldown, "fogAnalyticsCloud_move"),
        (.cableCarCorrelator, .pursue, "cableCarCorrelator_move"),
        (.sutroSignalWitch, .keepRange, "sutroSignalWitch_move"),
        (.victorianVendor, .cooldown, "victorianVendor_move"),
    ])
    func movingEnemiesPresentMove(role: ArchetypeID, state: EnemyAIState, expected: String) {
        #expect(ActorClipProjection.standardClipId(role: role, state: state, velocity: Self.moving) == expected)
    }

    @Test(arguments: [ArchetypeID.fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch, .autonomousInformant, .victorianVendor])
    func stationaryEnemiesPresentIdle(role: ArchetypeID) {
        #expect(ActorClipProjection.standardClipId(role: role, state: .pursue, velocity: .zero) == "\(role.rawValue)_idle")
    }

    /// The Informant's pursuit is its attack presentation, so moving pursuit
    /// keeps the delivered pursuit clip and there is no move clip to fall into.
    @Test func informantPursuitKeepsItsPursuitClip() {
        #expect(ActorClipProjection.standardClipId(role: .autonomousInformant, state: .pursue, velocity: Self.moving) == "autonomousInformant_anticipate")
    }

    /// Only the Correlator has an authoritative RECOVER, 45 ticks.
    @Test func correlatorRecoverPresentsItsRecoverClip() throws {
        #expect(ActorClipProjection.standardClipId(role: .cableCarCorrelator, state: .recover, velocity: .zero) == "cableCarCorrelator_recover")
        let clip = try #require(ClipCatalog.bundled().clipsById["cableCarCorrelator_recover"])
        #expect(ReactionClipTrackerDuration.ticks(clip) == 45)
    }

    /// Attack states still win over locomotion.
    @Test func attackStatesAreUnchanged() {
        #expect(ActorClipProjection.standardClipId(role: .cableCarCorrelator, state: .telegraph, velocity: .zero) == "cableCarCorrelator_anticipate")
        #expect(ActorClipProjection.standardClipId(role: .cableCarCorrelator, state: .charge, velocity: Self.moving) == "cableCarCorrelator_commit")
        #expect(ActorClipProjection.standardClipId(role: .sutroSignalWitch, state: .telegraph, velocity: .zero) == "sutroSignalWitch_anticipate")
    }

    /// Every clip the projection can name for a standard enemy exists in the
    /// bundled contract, so no ID can be misspelled into a permanent blockout.
    @Test func everyProjectedClipExistsInTheContract() throws {
        let clips = try ClipCatalog.bundled().clipsById
        let roles: [ArchetypeID] = [.fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch, .autonomousInformant, .victorianVendor]
        let states: [EnemyAIState] = [.pursue, .orbit, .telegraph, .resolve, .cooldown, .charge, .recover, .keepRange, .fire, .throwMine]
        for role in roles {
            for state in states {
                for velocity in [VecQ8.zero, Self.moving] {
                    if let id = ActorClipProjection.standardClipId(role: role, state: state, velocity: velocity) {
                        #expect(clips[id] != nil, "\(role) \(state) projects \(id), which the contract does not define")
                    }
                }
            }
        }
    }
}

/// Frames ÷ fps in 60 Hz ticks, the same rule `ReactionClipTracker` uses.
enum ReactionClipTrackerDuration {
    static func ticks(_ clip: ClipRecord) -> Int {
        let perDirection = clip.directions.isEmpty ? clip.frameIds.count : clip.frameIds.count / clip.directions.count
        return (perDirection * 60 + clip.framesPerSecond - 1) / clip.framesPerSecond
    }
}
