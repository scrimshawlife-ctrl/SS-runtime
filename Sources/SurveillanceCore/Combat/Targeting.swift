public enum ProjectileKind: Equatable, Sendable {
    case civicPulse
    case ricochet
    case sutroBolt
    case bossBolt
}

public struct ProjectileBody: Equatable, Sendable {
    public var id: EntityID
    public var ownerId: EntityID
    public var kind: ProjectileKind
    public var position: VecQ8
    public var previous: VecQ8
    public var velocity: VecQ8
    public var radius: Int
    public var damage: Int
    public var cameraDamage: Int
    public var age: Int
    public var lifetime: Int
    public var distanceTravelledQ8: Int64
    public var maxTravelQ8: Int64
    public var hitEntityIds: [EntityID]
    public var alive: Bool
    /// The Camera this shot was fired at, if any. D-085: that Camera's own
    /// mount does not stop the shot. Not digested (projectiles never are).
    public var targetCameraId: EntityID? = nil
}

/// `camera-destruction.md` § 6 candidate classes (D-082). A Camera that is not
/// chosen has no class: it is never an automatic target.
public enum TargetClass: Int, Equatable, Sendable {
    case closeEnemy = 1
    case chosenCamera = 2
    case otherEnemy = 3
}

public enum Targeting {
    public static let civicPulseRange = 512
    public static let closeEnemyRange = 96
    public static let cadence = 30
    public static let firstOpportunity: UInt64 = 30
    public static let projectileSpeedPerTick = 12
    public static let projectileRadius = 4
    public static let projectileLifetime = 45
    public static let maxTravel = 540
    public static let activeCeiling = 32
    public static let enemyDamage = 10
    public static let cameraDamage = 1
    public static let ricochetRange = 160

    /// D-031 / D-082 / `camera-destruction-001` §6 / T409: class, then squared
    /// distance to anchor, then stable ID. Only a chosen Camera is a candidate.
    /// D-092: an unaware patrol member is a candidate only within
    /// `unawarePatrolRange` of the Player (`patrol.sightUnits`, inclusive).
    public static func select(
        player: PlayerBody,
        enemies: [EnemyBody],
        cameras: [SelectedCamera],
        solids: [(id: String, box: AABB)],
        unawarePatrolRange: Int? = nil
    ) -> (EntityID, VecQ8)? {
        struct Candidate {
            var id: EntityID
            var `class`: TargetClass
            var distSq: Int64
            var anchor: VecQ8
        }
        var list: [Candidate] = []
        for enemy in enemies where enemy.alive {
            let distSq = player.position.distanceSquared(to: enemy.position)
            if !inRange(distSq) { continue }
            if !patrolCandidate(enemy, distSq: distSq, range: unawarePatrolRange, player: player) { continue }
            if !Collision.lineOfFireClear(from: player.position, to: enemy.position, solids: solids) { continue }
            let close = distSq <= Int64(closeEnemyRange) * Int64(closeEnemyRange) * Q8.scale * Q8.scale
            list.append(
                Candidate(
                    id: enemy.id,
                    class: close ? .closeEnemy : .otherEnemy,
                    distSq: distSq,
                    anchor: enemy.position
                )
            )
        }
        for camera in cameras where camera.isDamageable {
            guard isChosen(velocity: player.velocity, from: player.position, to: camera.targetAnchor) else { continue }
            let distSq = player.position.distanceSquared(to: camera.targetAnchor)
            if !inRange(distSq) { continue }
            if !lineOfFireClear(from: player.position, to: camera, solids: solids) { continue }
            list.append(
                Candidate(
                    id: camera.entityId,
                    class: .chosenCamera,
                    distSq: distSq,
                    anchor: camera.targetAnchor
                )
            )
        }
        list.sort {
            if $0.class != $1.class { return $0.class.rawValue < $1.class.rawValue }
            if $0.distSq != $1.distSq { return $0.distSq < $1.distSq }
            return $0.id < $1.id
        }
        guard let best = list.first else { return nil }
        return (best.id, best.anchor)
    }

    /// `upgrades.md` Ricochet Pulse: one continuation, nearest then lowest ID, excluding the origin target.
    public static func ricochetTarget(
        origin: VecQ8,
        excluding: EntityID,
        enemies: [EnemyBody],
        cameras: [SelectedCamera],
        solids: [(id: String, box: AABB)]
    ) -> (EntityID, VecQ8)? {
        struct Candidate { var id: EntityID; var distSq: Int64; var anchor: VecQ8 }
        var list: [Candidate] = []
        let range = Int64(ricochetRange) * Q8.scale
        for enemy in enemies where enemy.alive && enemy.id != excluding {
            let distSq = origin.distanceSquared(to: enemy.position)
            if distSq <= range * range, Collision.lineOfFireClear(from: origin, to: enemy.position, solids: solids) {
                list.append(Candidate(id: enemy.id, distSq: distSq, anchor: enemy.position))
            }
        }
        for camera in cameras where camera.isDamageable && camera.entityId != excluding {
            let distSq = origin.distanceSquared(to: camera.targetAnchor)
            if distSq <= range * range, lineOfFireClear(from: origin, to: camera, solids: solids) {
                list.append(Candidate(id: camera.entityId, distSq: distSq, anchor: camera.targetAnchor))
            }
        }
        list.sort {
            if $0.distSq != $1.distSq { return $0.distSq < $1.distSq }
            return $0.id < $1.id
        }
        guard let next = list.first else { return nil }
        return (next.id, next.anchor)
    }

    /// D-082 chosen Camera: `v` is non-zero, `dot(v, d) > 0`, and
    /// `4 · dot(v, d)² ≥ 3 · |v|² · |d|²` (within 30 degrees of travel), on Q8
    /// raw components. Both sides of the inequality exceed 64 bits at arena
    /// scale, so they are compared as exact 128-bit products.
    public static func isChosen(velocity v: VecQ8, from player: VecQ8, to anchor: VecQ8) -> Bool {
        if v == .zero { return false }
        let dx = anchor.x.raw - player.x.raw
        let dy = anchor.y.raw - player.y.raw
        let dot = v.x.raw * dx + v.y.raw * dy
        guard dot > 0 else { return false }
        let vSq = UInt64(v.x.raw * v.x.raw + v.y.raw * v.y.raw)
        let dSq = UInt64(dx * dx + dy * dy)
        let left = UInt128Product(UInt64(dot), UInt64(dot)).times(4)
        let right = UInt128Product(vSq, dSq).times(3)
        return left >= right
    }

    /// D-085: a Camera's own mount never blocks line of fire to that Camera;
    /// every other solid, other mounts included, blocks as usual. On the
    /// diagonal sockets the 16-unit anchor lies inside the ±12 mount box.
    public static func lineOfFireClear(
        from origin: VecQ8,
        to camera: SelectedCamera,
        solids: [(id: String, box: AABB)]
    ) -> Bool {
        let own = camera.mountSolidId
        return !solids.contains { $0.id != own && Collision.segmentIntersects(origin, camera.targetAnchor, box: $0.box) }
    }

    /// D-092 / D-093: an unaware patrol member is a candidate only within
    /// `range` of the Player **and** only while the Player moves toward it (the
    /// D-082 chosen-Camera test), so walking past holds fire.
    @inline(never)
    static func patrolCandidate(_ enemy: EnemyBody, distSq: Int64, range: Int?, player: PlayerBody) -> Bool {
        guard let range, enemy.isPatrolMember, enemy.isUnaware else { return true }
        let r = Int64(range) * Q8.scale
        return distSq <= r * r && isChosen(velocity: player.velocity, from: player.position, to: enemy.position)
    }

    public static func inRange(_ distSqQ8: Int64) -> Bool {
        let r = Int64(civicPulseRange) * Q8.scale
        return distSqQ8 <= r * r
    }

    public static func aimVelocity(from: VecQ8, to: VecQ8, targetVelocity: VecQ8) -> VecQ8 {
        let speed = Int64(projectileSpeedPerTick) * Q8.scale
        if let intercept = intercept(from: from, to: to, targetVelocity: targetVelocity, speed: speed) {
            return intercept
        }
        return direct(from: from, to: to, speed: speed)
    }

    public static func direct(from: VecQ8, to: VecQ8, speed: Int64) -> VecQ8 {
        let dx = to.x.raw - from.x.raw
        let dy = to.y.raw - from.y.raw
        let mag = IntMath.isqrt(dx * dx + dy * dy)
        if mag == 0 { return VecQ8(x: Q8(raw: speed), y: .zero) }
        return VecQ8(
            x: Q8(raw: IntMath.mulDivHalfAway(dx, speed, mag)),
            y: Q8(raw: IntMath.mulDivHalfAway(dy, speed, mag))
        )
    }

    private static func intercept(from: VecQ8, to: VecQ8, targetVelocity: VecQ8, speed: Int64) -> VecQ8? {
        let rx = to.x.raw - from.x.raw
        let ry = to.y.raw - from.y.raw
        let vx = targetVelocity.x.raw
        let vy = targetVelocity.y.raw
        let a = vx * vx + vy * vy - speed * speed
        let b = 2 * (rx * vx + ry * vy)
        let c = rx * rx + ry * ry
        if a == 0 {
            if b == 0 { return nil }
            let t = IntMath.divHalfAway(-c, b)
            if t <= 0 { return nil }
            let aim = VecQ8(x: Q8(raw: rx + vx * t / Q8.scale), y: Q8(raw: ry + vy * t / Q8.scale))
            return direct(from: .zero, to: aim, speed: speed)
        }
        guard let disc = IntMath.quadraticDiscriminant(a: a, b: b, c: c) else { return nil }
        let s = IntMath.isqrt(disc)
        let t1 = IntMath.divHalfAway(-b - s, 2 * a)
        let t2 = IntMath.divHalfAway(-b + s, 2 * a)
        let t = [t1, t2].filter { $0 > 0 }.min()
        guard let t else { return nil }
        let aim = VecQ8(x: Q8(raw: rx + vx * t / Q8.scale), y: Q8(raw: ry + vy * t / Q8.scale))
        return direct(from: .zero, to: aim, speed: speed)
    }
}
