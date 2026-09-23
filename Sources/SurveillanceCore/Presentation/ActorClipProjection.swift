/// Which clip an actor is presenting, derived from its authoritative state.
///
/// `animation.md` §1: "Every gameplay clip maps to an authoritative state or
/// event." So the mapping is a projection of `EnemyAIState` and `BossRuntime`,
/// never a guess made by the renderer.
///
/// A state with no clip returns `nil` and the actor keeps its authored
/// blockout. The standard enemies present every state (D-071): their attack
/// pair, `idle` at zero velocity, `move` otherwise, and the Cable-Car
/// Correlator's `recover`. The Captain has no locomotion clip and keeps its
/// blockout while simply moving. Hurt, stagger, and defeat are events, not
/// states, and are layered on by `ReactionClipTracker`.
///
/// A returned clip may still be unbacked: D-071's frames are planned
/// originals until delivered, and the renderer keeps the blockout for any
/// direction that is not fully backed.
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
            return standardClipId(role: enemy.archetype, state: enemy.state, velocity: enemy.velocity)
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
    /// the state that reaches each differs by role. Every other state is
    /// locomotion or standing (D-071).
    static func standardClipId(role: ArchetypeID, state: EnemyAIState, velocity: VecQ8) -> String? {
        switch (role, state) {
        case (.fogAnalyticsCloud, .telegraph): return "fogAnalyticsCloud_anticipate"
        case (.fogAnalyticsCloud, .resolve): return "fogAnalyticsCloud_commit"

        case (.cableCarCorrelator, .telegraph): return "cableCarCorrelator_anticipate"
        case (.cableCarCorrelator, .charge): return "cableCarCorrelator_commit"

        case (.sutroSignalWitch, .telegraph): return "sutroSignalWitch_anticipate"
        case (.sutroSignalWitch, .fire): return "sutroSignalWitch_commit"

        case (.autonomousInformant, .charge): return "autonomousInformant_commit"

        case (.victorianVendor, .telegraph): return "victorianVendor_anticipate"
        case (.victorianVendor, .throwMine): return "victorianVendor_commit"

        // enemies-and-encounters.md: only the Correlator has a RECOVER.
        case (.cableCarCorrelator, .recover): return "cableCarCorrelator_recover"

        default: break
        }
        guard locomotionStates.contains(state) else { return nil }
        if velocity == .zero { return "\(role.rawValue)_idle" }
        // The Informant has no special attack; its pursuit is its whole
        // presentation, so the anticipation clip carries the chase and it has
        // no move clip (D-071).
        if role == .autonomousInformant { return "autonomousInformant_anticipate" }
        return "\(role.rawValue)_move"
    }

    /// States in which a standard enemy is only moving or standing.
    static let locomotionStates: Set<EnemyAIState> = [.pursue, .orbit, .keepRange, .cooldown]

    /// Compass direction an actor faces, from its velocity, falling back to
    /// south when it is still.
    public static func direction(for velocity: VecQ8) -> String {
        ClipFrameLibrary.direction(forFacing: velocity)
    }
}
