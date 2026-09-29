/// Why an unaware enemy became alerted (`enemyAlerted.cause`, D-089), in
/// precedence order: a cause outranks every cause after it.
public enum AlertCause: String, Equatable, Sendable, CaseIterable {
    case surveillance
    case damage
    case sight
    case ally
}

/// D-089 alert resolution (`enemies-and-encounters.md` § Awareness,
/// `simulation-order.md` phase 5). Runs once per tick at the start of the
/// enemy phase, before any enemy thinks or moves.
public enum AwarenessSystem {
    public struct Alert: Equatable, Sendable {
        public var entityId: EntityID
        public var cause: AlertCause
    }

    /// Alerts every unaware enemy that meets a cause, in ascending entity ID,
    /// and returns the alerts in that order.
    ///
    /// - **surveillance**: `detection` (resolved after the previous tick) is
    ///   the alert state or above; every unaware enemy is alerted by it.
    /// - **damage**: the enemy took damage since its last enemy phase, that
    ///   is, in the previous tick's damage phase (it is `struck`).
    /// - **sight**: squared distance to the Player at most the sight range
    ///   squared, on Q8 positions, with a clear line under the weapon's
    ///   line-of-fire rule against the same solids. A Transit Patrol member
    ///   sees only in its cone (D-091, `PatrolSystem.sees`) instead.
    /// - **ally**: within the ally radius of an enemy alerted this tick by
    ///   damage or sight. One hop: an ally alert never alerts anyone.
    public static func resolve(
        enemies: inout [EnemyBody],
        player: VecQ8,
        detection: DetectionState,
        spec: AwarenessSpec,
        solids: [(id: String, box: AABB)],
        patrol: PatrolSpec? = nil
    ) -> [Alert] {
        let ordered = enemies.indices
            .filter { enemies[$0].alive && enemies[$0].isUnaware }
            .sorted { enemies[$0].id < enemies[$1].id }
        guard !ordered.isEmpty else { return [] }

        var causes: [Int: AlertCause] = [:]
        if spec.surveillanceAlerts(detection) {
            for index in ordered { causes[index] = .surveillance }
        } else {
            let sight = Int64(spec.sightRangeUnits) * Q8.scale
            for index in ordered {
                let enemy = enemies[index]
                if enemy.awareness == .struck {
                    causes[index] = .damage
                } else if enemy.isPatrolMember {
                    if let patrol, PatrolSystem.sees(member: enemy, player: player, spec: patrol, solids: solids) {
                        causes[index] = .sight
                    }
                } else if enemy.position.distanceSquared(to: player) <= sight * sight,
                          Collision.lineOfFireClear(from: enemy.position, to: player, solids: solids)
                {
                    causes[index] = .sight
                }
            }
            // Positions of this tick's damage and sight alerts: the only
            // sources of an ally alert.
            let sources = ordered.compactMap { causes[$0] != nil ? enemies[$0].position : nil }
            let radius = Int64(spec.allyAlertRadiusUnits) * Q8.scale
            for index in ordered where causes[index] == nil {
                let position = enemies[index].position
                if sources.contains(where: { position.distanceSquared(to: $0) <= radius * radius }) {
                    causes[index] = .ally
                }
            }
        }

        var alerts: [Alert] = []
        for index in ordered {
            guard let cause = causes[index] else { continue }
            enemies[index].awareness = .aware
            enemies[index].velocity = .zero
            alerts.append(Alert(entityId: enemies[index].id, cause: cause))
        }
        return alerts
    }

    /// The damage a hit deals before the Integrity clamp, and whether it is
    /// the ambush (`combat.md`, CB-011/CB-012). Only the first damage to an
    /// `unaware` enemy is multiplied; it leaves the enemy `struck`.
    public static func hitDamage(
        base: Int,
        awareness: inout EnemyAwareness,
        multiplier: Int
    ) -> (amount: Int, ambush: Bool) {
        switch awareness {
        case .unaware:
            awareness = .struck
            return (base * multiplier, true)
        case .struck, .aware:
            return (base, false)
        }
    }
}
