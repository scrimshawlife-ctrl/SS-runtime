import Foundation

/// `run-shell.md` § 12 (D-095): the five medals a successful run can earn.
///
/// Presentation only. Every medal is derived from the run's own authoritative
/// event stream and terminal state, so a replay of the run earns the same
/// medals (RS-022). Nothing here is ever an input to `Simulation`, and nothing
/// here enters the digest or the receipt.
public enum Medal: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case ghost
    case shadow
    case blackout
    case surgical
    case swift

    /// The name the run card, the title, and Share print.
    public var name: String { rawValue.uppercased() }

    /// § 12 `SWIFT`: under 5:30, that is, under 19,800 ticks.
    public static let swiftTicks: UInt64 = 19_800
}

/// Folds a run's events, tick by tick, into what the medals need to know.
///
/// Feed it every tick's published events in order. It reads nothing else
/// from the simulation except the set of Transit Patrol member IDs, which it
/// learns from the state it is handed (they spawn with the run).
public struct MedalTracker: Equatable, Sendable {
    /// `GHOST`: the Detection State reached `tracked` or above before M-C's
    /// first `waveStarted`.
    public private(set) var trackedBeforeMobC = false
    /// `SHADOW`: a Transit Patrol member was alerted before M-A's first
    /// `waveStarted`.
    public private(set) var patrolAlertedBeforeMobA = false
    public private(set) var mobAStarted = false
    public private(set) var mobCStarted = false
    private var patrolMembers: Set<EntityID> = []

    public init() {}

    public mutating func reset() {
        self = MedalTracker()
    }

    /// Learns the patrol members present in `state`. Call it before the
    /// tick's events (members exist from the first tick, and an ID is never
    /// reused, so remembering every one ever seen is exact).
    public mutating func notePatrol(_ state: WorldState) {
        for enemy in state.enemies where enemy.patrol != nil {
            patrolMembers.insert(enemy.id)
        }
    }

    /// One tick's events, in published order. Within a tick the published
    /// order (phase, then ordinal) decides "before": the alert phase runs
    /// before waves start, so an alert on the tick M-A starts counts.
    public mutating func ingest(_ events: [AuthoritativeEvent]) {
        for event in events {
            switch event.type {
            case .detectionStateChanged:
                guard !mobCStarted,
                      case .string(let after)? = event.payload["after"],
                      let state = DetectionState(rawValue: after)
                else { continue }
                if Self.reachesTracked(state) { trackedBeforeMobC = true }
            case .enemyAlerted:
                guard !mobAStarted, let id = event.primaryEntityId else { continue }
                if patrolMembers.contains(id) { patrolAlertedBeforeMobA = true }
            case .waveStarted:
                guard case .string(let encounter)? = event.payload["encounterId"] else { continue }
                if encounter == CombatAuthorityNode.mobA.rawValue { mobAStarted = true }
                if encounter == CombatAuthorityNode.mobC.rawValue { mobCStarted = true }
            default:
                continue
            }
        }
    }

    static func reachesTracked(_ state: DetectionState) -> Bool {
        switch state {
        case .hidden, .observed: false
        case .tracked, .hunted, .lockdown: true
        }
    }

    /// The medals `state` earned, in canonical order. Empty unless the run
    /// succeeded (RS-021).
    public func medals(for state: WorldState) -> [Medal] {
        guard state.outcome == .success else { return [] }
        return Medal.allCases.filter { medal in
            switch medal {
            case .ghost: !trackedBeforeMobC
            case .shadow: !patrolAlertedBeforeMobA
            case .blackout: state.networkBlackout
            case .surgical: Self.surgical(integrity: state.player.integrity, max: state.player.maxIntegrity)
            case .swift: state.tick < Medal.swiftTicks
            }
        }
    }

    /// § 12 `SURGICAL`: at least half of `player.integrity` (RS-020: 74 of
    /// 150 is not, 75 is).
    public static func surgical(integrity: Int, max: Int) -> Bool {
        integrity * 2 >= max
    }

    /// Replays `commands` from `seed` and derives the medals: what RS-022
    /// checks, and what a stored ghost would earn.
    public static func replayMedals(seed: UInt64, commands: [PlayerCommand]) throws -> [Medal] {
        var sim = try Simulation.make(seed: seed)
        var tracker = MedalTracker()
        var index = 0
        while !sim.isTerminal, index < commands.count {
            tracker.notePatrol(sim.state)
            let result = sim.step(command: commands[index])
            tracker.ingest(result.events)
            index += 1
        }
        return tracker.medals(for: sim.state)
    }
}

/// `run-shell.md` § 12 storage: the medals earned today on one seed and Replay
/// Identity, kept beside the day's best run. Local only; never shared.
public struct MedalRecord: Codable, Equatable, Sendable {
    public var rulesetVersion: String
    public var contentVersion: String
    public var arenaVersion: String
    public var replaySchemaVersion: String
    public var seed: UInt64
    public var medals: [Medal]

    public init(identity: ReplayIdentity, seed: UInt64, medals: [Medal] = []) {
        rulesetVersion = identity.rulesetVersion
        contentVersion = identity.contentVersion
        arenaVersion = identity.arenaVersion
        replaySchemaVersion = identity.replaySchemaVersion
        self.seed = seed
        self.medals = Medal.allCases.filter(medals.contains)
    }

    public var identity: ReplayIdentity {
        ReplayIdentity(
            rulesetVersion: rulesetVersion,
            contentVersion: contentVersion,
            arenaVersion: arenaVersion,
            replaySchemaVersion: replaySchemaVersion
        )
    }

    /// Today's earned set for `seed` and `identity`: the stored record when it
    /// matches both, otherwise nothing (a new day, or a different ruleset).
    public static func earned(_ stored: MedalRecord?, seed: UInt64, identity: ReplayIdentity) -> Set<Medal> {
        guard let stored, stored.seed == seed, stored.identity == identity else { return [] }
        return Set(stored.medals)
    }

    /// Adds `earned` to what was stored. Returns the record to store and the
    /// medals that are new today (RS-023: a repeat is not `NEW`).
    public static func merging(
        _ stored: MedalRecord?,
        earned: [Medal],
        seed: UInt64,
        identity: ReplayIdentity
    ) -> (record: MedalRecord, new: Set<Medal>) {
        let before = Self.earned(stored, seed: seed, identity: identity)
        let new = Set(earned).subtracting(before)
        let record = MedalRecord(identity: identity, seed: seed, medals: Array(before.union(earned)))
        return (record, new)
    }
}

/// The title's goal list (§ 12): all five medals, earned or not, in order.
public struct MedalGoal: Equatable, Sendable {
    public let medal: Medal
    public let earned: Bool

    /// Filled for earned, outlined for not yet: shape as well as colour.
    public var glyph: String { earned ? "◆" : "◇" }

    public static func goals(earned: Set<Medal>) -> [MedalGoal] {
        Medal.allCases.map { MedalGoal(medal: $0, earned: earned.contains($0)) }
    }
}
