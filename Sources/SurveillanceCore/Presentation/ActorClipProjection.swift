/// Which clip an actor is presenting, derived from its authoritative state.
///
/// `animation.md` §1: "Every gameplay clip maps to an authoritative state or
/// event." So the mapping is a projection of `EnemyAIState` and `BossRuntime`,
/// never a guess made by the renderer.
///
/// A state with no clip returns `nil` and the actor keeps its authored
/// blockout. That is not an oversight here: `clip-metadata-001` defines only
/// anticipate and commit clips for the five standard enemies, and only attack,
/// transition, stagger, and defeat clips for the Captain. Neither has a
/// locomotion clip, so both fall back to blockout while simply moving.
public enum ActorClipProjection {
    /// Clip for a standard or elite enemy, or nil when its state has none.
    public static func clipId(for enemy: EnemyBody, bossRuntime: BossRuntime?) -> String? {
        switch enemy.archetype {
        case .algorithmicModerate:
            return captainClipId(bossRuntime)
        case .improperSearchDaemon:
            return daemonClipId(enemy.state)
        case .fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch,
             .autonomousInformant, .victorianVendor:
            return standardClipId(role: enemy.archetype, state: enemy.state)
        }
    }

    /// bosses.md §Improper Search Daemon: every state in the sequence has a clip.
    static func daemonClipId(_ state: EnemyAIState) -> String? {
        let suffix: String
        switch state {
        case .pursue: suffix = "pursuit"
        case .queryTelegraph: suffix = "queryTelegraph"
        case .queryResolve: suffix = "queryResolve"
        case .dashTelegraph: suffix = "dashTelegraph"
        case .dash: suffix = "dash"
        case .recover: suffix = "recover"
        default: return nil
        }
        return "improperSearchDaemon_\(suffix)"
    }

    /// The Captain presents the attack it is winding up, and its transition,
    /// stagger, and defeat clips otherwise.
    static func captainClipId(_ runtime: BossRuntime?) -> String? {
        guard let runtime else { return nil }
        if runtime.recoveryRemaining > 0 { return "algorithmicModerate_phaseTransition" }
        guard let attack = runtime.currentAttack,
              runtime.telegraphRemaining > 0 || runtime.attackRemaining > 0
        else { return nil }
        return ClipCatalog.clipId(for: attack)
    }

    /// Each standard enemy has one anticipation clip and one commit clip, and
    /// the state that reaches each differs by role.
    static func standardClipId(role: ArchetypeID, state: EnemyAIState) -> String? {
        switch (role, state) {
        case (.fogAnalyticsCloud, .telegraph): return "fogAnalyticsCloud_anticipate"
        case (.fogAnalyticsCloud, .resolve): return "fogAnalyticsCloud_commit"

        case (.cableCarCorrelator, .telegraph): return "cableCarCorrelator_anticipate"
        case (.cableCarCorrelator, .charge): return "cableCarCorrelator_commit"

        case (.sutroSignalWitch, .telegraph): return "sutroSignalWitch_anticipate"
        case (.sutroSignalWitch, .fire): return "sutroSignalWitch_commit"

        // The Informant has no special attack; its pursuit is its whole
        // presentation, so the anticipation clip carries the chase.
        case (.autonomousInformant, .pursue): return "autonomousInformant_anticipate"
        case (.autonomousInformant, .charge): return "autonomousInformant_commit"

        case (.victorianVendor, .telegraph): return "victorianVendor_anticipate"
        case (.victorianVendor, .throwMine): return "victorianVendor_commit"

        default: return nil
        }
    }

    /// Compass direction an actor faces, from its velocity, falling back to
    /// south when it is still.
    public static func direction(for velocity: VecQ8) -> String {
        ClipFrameLibrary.direction(forFacing: velocity)
    }
}
