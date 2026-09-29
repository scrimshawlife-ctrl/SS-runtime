public enum EnemyAIState: Equatable, Sendable {
    case pursue
    case orbit
    case telegraph
    case resolve
    case cooldown
    case charge
    case recover
    case keepRange
    case fire
    case throwMine
    case queryTelegraph
    case queryResolve
    case dashTelegraph
    case dash
}

/// D-089 awareness of one enemy. Authoritative and digested.
///
/// A standard enemy can spawn `unaware`. The first damage it takes is an
/// ambush (×`ambushDamageMultiplier`) and leaves it `struck`: the ambush is
/// spent, so later hits are normal, but it is not alerted until the start of
/// the next enemy phase, where damage is one of the alert causes. Until it is
/// `aware` it holds position, never attacks, and deals no contact damage. An
/// alerted enemy never returns to unaware. The elite and the boss are always
/// `aware`.
public enum EnemyAwareness: String, Equatable, Sendable {
    case unaware
    case struck
    case aware
}

public struct EnemyBody: Equatable, Sendable {
    public var id: EntityID
    public var archetype: ArchetypeID
    public var position: VecQ8
    public var velocity: VecQ8
    public var integrity: Int
    public var radius: Int
    public var speedUnitsPerSecond: Int
    public var contactDps: Int
    public var state: EnemyAIState
    public var stateTicks: Int
    public var spawnTick: UInt64
    public var nextSpecialTick: UInt64
    public var lockPosition: VecQ8?
    public var encounterId: String
    public var queryMarkers: [VecQ8] = []
    /// D-089. Defaults to aware: only a standard-enemy spawn can be unaware.
    public var awareness: EnemyAwareness = .aware
    public var alive: Bool { integrity > 0 }
    /// Not yet alerted: holds, never attacks, no contact damage.
    public var isUnaware: Bool { awareness != .aware }
}

public enum DaemonQuery {
    public static let circleRadius = 56
    public static let lateralOffset = 96
    public static let resolveDamage = 14

    public static func markers(playerPosition: VecQ8, facing: VecQ8) -> [VecQ8] {
        let dir = facing == .zero ? VecQ8(unitsX: 1, unitsY: 0) : facing
        let perp = dir.clockwisePerpendicular
        return [
            playerPosition,
            playerPosition.offset(units: lateralOffset, along: perp),
            playerPosition.offset(units: -lateralOffset, along: perp)
        ]
    }

    public static func damage(playerPosition: VecQ8, markers: [VecQ8]) -> Int {
        markers.reduce(0) { total, center in
            total + (center.contains(playerPosition, radiusUnits: circleRadius) ? resolveDamage : 0)
        }
    }
}

public struct MineBody: Equatable, Sendable {
    public var id: EntityID
    public var ownerId: EntityID
    public var position: VecQ8
    public var armRemaining: Int
    public var lifeRemaining: Int
    public var radius: Int
    public var damage: Int
    public var armed: Bool { armRemaining <= 0 }
}

public struct EncounterRuntime: Equatable, Sendable {
    public var id: String
    public var activated: Bool
    public var completed: Bool
    public var waveIndex: Int
    public var spawnQueue: [ArchetypeID]
    public var nextSpawnTick: UInt64
    public var deferTicks: Int
    public var living: Int
    public var spawned: Int
    public var cleanupTick: UInt64?
    /// D-083 heat reinforcements still queued. They are always the last
    /// entries of `spawnQueue`, so the head is a reinforcement exactly when
    /// the queue is no longer than this. D-089 spawns them aware.
    public var queuedReinforcements: Int = 0
}

public enum EncounterDirector {
    public static let encounterOrder = ["M-A", "M-B", "M-C"]

    /// encounter-objectives-001 §5 / FR-040A. Camera count, Network Blackout, Exposure, and upgrade are not inputs.
    public static func extractionArmed(
        mobAComplete: Bool,
        mobBComplete: Bool,
        mobCComplete: Bool,
        eliteDefeated: Bool,
        bossDefeated: Bool,
        playerAlive: Bool,
        runFailed: Bool
    ) -> Bool {
        mobAComplete && mobBComplete && mobCComplete && eliteDefeated && bossDefeated && playerAlive && !runFailed
    }
}
