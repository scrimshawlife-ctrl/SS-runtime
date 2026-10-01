/// D-091 Transit Patrol (`enemies-and-encounters.md` § Transit Patrol) and the
/// D-090 unaware drift: how an unaware standard enemy moves, and how a patrol
/// member sees.
public enum PatrolSystem {
    /// Q8 per-tick speed for `percent` of `unitsPerSecond`, rounded half away
    /// from zero once, so 40% of 84 is 33.6 units per second rather than 33.
    public static func scaledSpeedQ8(unitsPerSecond: Int, percent: Int) -> Int64 {
        IntMath.mulDivHalfAway(Int64(unitsPerSecond) * Int64(percent), Q8.scale, 60 * 100)
    }

    /// True when `point` is inside a cone at `origin` along `facing`: squared
    /// Q8 distance at most `range`², then the D-082 integer angle test at the
    /// spec's half-angle, `dot(f, d) > 0` and
    /// `denominator · dot² ≥ numerator · |f|² · |d|²` on exact 128-bit
    /// products. A zero facing sees nothing. Line of sight is separate.
    public static func inCone(origin: VecQ8, facing f: VecQ8, point: VecQ8, spec: PatrolSpec) -> Bool {
        if f == .zero { return false }
        let range = Int64(spec.sightUnits) * Q8.scale
        let dx = point.x.raw - origin.x.raw
        let dy = point.y.raw - origin.y.raw
        let dSq = dx * dx + dy * dy
        guard dSq <= range * range else { return false }
        let dot = f.x.raw * dx + f.y.raw * dy
        guard dot > 0 else { return false }
        let fSq = UInt64(f.x.raw * f.x.raw + f.y.raw * f.y.raw)
        let cos2 = spec.cosineSquared
        let left = UInt128Product(UInt64(dot), UInt64(dot)).times(cos2.denominator)
        let right = UInt128Product(fSq, UInt64(dSq)).times(cos2.numerator)
        return left >= right
    }

    /// Cone sight (EN-026–EN-028): inside the cone with a clear line under the
    /// weapon line-of-fire rule against `solids`.
    public static func sees(
        member: EnemyBody,
        player: VecQ8,
        spec: PatrolSpec,
        solids: [(id: String, box: AABB)]
    ) -> Bool {
        guard let patrol = member.patrol else { return false }
        return inCone(origin: member.position, facing: patrol.facing, point: player, spec: spec)
            && Collision.lineOfFireClear(from: member.position, to: player, solids: solids)
    }

    /// The patrol member for route `index` as it spawns (EN-024): unaware at
    /// its first waypoint, heading for the second, facing from the first to
    /// the second.
    public static func member(
        route: PatrolRoute,
        index: Int,
        id: EntityID,
        stats: StandardEnemyStats,
        integrityPercent: Int = 100,
        tick: UInt64,
        nextSpecialTick: UInt64
    ) -> EnemyBody {
        let first = route.waypoints[0]
        let second = route.waypoints[1 % route.waypoints.count]
        return EnemyBody(
            id: id,
            archetype: route.archetype,
            position: first.asQ8,
            velocity: .zero,
            // D-093: tough enough that one ambush wounds but does not kill.
            integrity: stats.hp * integrityPercent / 100,
            radius: stats.radius,
            speedUnitsPerSecond: stats.speed,
            contactDps: stats.contactDps,
            state: .pursue,
            stateTicks: 0,
            spawnTick: tick,
            nextSpecialTick: nextSpecialTick,
            lockPosition: nil,
            encounterId: encounterId(for: route),
            awareness: .unaware,
            patrol: PatrolState(
                route: index,
                target: 1 % route.waypoints.count,
                dwellRemaining: 0,
                facing: VecI(x: second.x - first.x, y: second.y - first.y).asQ8
            )
        )
    }

    /// A patrol member's `encounterId`. No encounter, heat rule, or
    /// completion count ever names it, so it is outside all three (EN-029).
    public static func encounterId(for route: PatrolRoute) -> String {
        "patrol:\(route.id)"
    }
}

/// What an unaware enemy needs to move: the drift anchors and patrol routes
/// from the arena, and the content values. Built once per enemy phase.
public struct UnawareMovement: Equatable, Sendable {
    public var triggerCentres: [String: VecQ8]
    public var routes: [[VecQ8]]
    public var awareness: AwarenessSpec
    public var patrol: PatrolSpec

    public init(arena: ArenaManifest, content: CombatContent) {
        var centres: [String: VecQ8] = [:]
        for trigger in arena.encounterTriggers {
            if let id = trigger.encounterId { centres[id] = trigger.center.asQ8 }
        }
        triggerCentres = centres
        routes = arena.patrols.map { $0.waypoints.map(\.asQ8) }
        awareness = content.awareness
        patrol = content.patrol
    }
}

extension EnemySystem {
    /// One unaware enemy's enemy phase. It never attacks. A patrol member
    /// patrols (EN-025); any other enemy drifts toward its encounter's
    /// trigger centre and stops within the stop distance (EN-031, D-090).
    /// Both use the shared steering, separation, and X-then-Y solid
    /// collision, capped at their reduced speed.
    ///
    /// Out of line, like `Simulation.resolveAwareness`, so it adds nothing to
    /// the debug stack frame of the enemy loop (SS-runtime #104).
    @inline(never)
    static func moveUnaware(
        enemies: inout [EnemyBody],
        index: Int,
        movement: UnawareMovement,
        bounds: AABB,
        solids: [(id: String, box: AABB)]
    ) {
        let enemy = enemies[index]
        let goal: VecQ8
        let percent: Int
        if var patrol = enemy.patrol {
            guard movement.routes.indices.contains(patrol.route), !movement.routes[patrol.route].isEmpty else {
                enemies[index].velocity = .zero
                return
            }
            let route = movement.routes[patrol.route]
            let arrival = Int64(movement.patrol.arrivalUnits) * Q8.scale
            if patrol.dwellRemaining == 0,
               enemy.position.distanceSquared(to: route[patrol.target]) <= arrival * arrival
            {
                if movement.patrol.dwellTicks > 0 {
                    patrol.dwellRemaining = movement.patrol.dwellTicks
                } else {
                    patrol.target = (patrol.target + 1) % route.count
                }
            }
            if patrol.dwellRemaining > 0 {
                // Holding at the waypoint just reached; on the last hold tick
                // it takes the next waypoint, wrapping at the end.
                patrol.dwellRemaining -= 1
                if patrol.dwellRemaining == 0 { patrol.target = (patrol.target + 1) % route.count }
                enemies[index].patrol = patrol
                enemies[index].velocity = .zero
                return
            }
            enemies[index].patrol = patrol
            goal = route[patrol.target]
            percent = movement.patrol.speedPercent
        } else {
            guard let centre = movement.triggerCentres[enemy.encounterId] else {
                enemies[index].velocity = .zero
                return
            }
            let stop = Int64(movement.awareness.unawareDriftStopUnits) * Q8.scale
            if enemy.position.distanceSquared(to: centre) <= stop * stop {
                enemies[index].velocity = .zero
                return
            }
            goal = centre
            percent = movement.awareness.unawareDriftPercent
        }

        let speed = PatrolSystem.scaledSpeedQ8(unitsPerSecond: enemy.speedUnitsPerSecond, percent: percent)
        enemies[index].velocity = Steering.toward(enemy.position, goal, speedPerTickQ8: speed)
        Steering.applySeparation(enemies: &enemies, index: index)
        Steering.clampSpeed(&enemies[index].velocity, max: speed)
        let moved = Collision.slideCircle(
            from: enemy.position,
            delta: enemies[index].velocity,
            radius: enemy.radius,
            bounds: bounds,
            solids: solids
        )
        if enemy.patrol != nil {
            let travel = VecQ8(
                x: Q8(raw: moved.x.raw - enemy.position.x.raw),
                y: Q8(raw: moved.y.raw - enemy.position.y.raw)
            )
            if travel != .zero { enemies[index].patrol?.facing = travel }
        }
        enemies[index].position = moved
    }
}
