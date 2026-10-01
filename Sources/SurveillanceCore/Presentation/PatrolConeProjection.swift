import Foundation

/// D-091 patrol cone as drawn (animation.md § 8a): an unaware patrol member's
/// vision cone on the ground, clipped at solids like a Camera field, and gone
/// once the member is alerted. Presentation only; the rule is
/// `PatrolSystem.sees`.
public struct PatrolCone: Equatable, Sendable {
    /// The patrol member.
    public var id: EntityID
    /// Cone origin: the member's position, in whole units.
    public var x: Int
    public var y: Int
    /// The authoritative facing, Q8 raw, for callers that apply the rule's
    /// own integer test.
    public var facing: VecQ8
    /// Facing as a clockwise-from-+X heading (the `Cordic` convention).
    public var headingMilli: Int
    public var rangeUnits: Int
    public var halfAngleMilli: Int
    /// The cone's outline in arena units, clipped where a ray meets a solid:
    /// the origin, then points along the arc from one edge to the other.
    public var outline: [VecI]
}

public enum PatrolConeProjection {
    /// Rays across the cone. Enough that a clipped edge reads as the solid's
    /// edge at the cone's 240-unit range.
    public static let rays = 24

    public static func project(_ state: WorldState) -> [PatrolCone] {
        let spec = state.content.patrol
        let solids = state.liveSolids.map(\.box)
        return state.enemies
            .filter { $0.alive && $0.isUnaware && $0.patrol != nil }
            .sorted { $0.id < $1.id }
            .compactMap { member in
                guard let facing = member.patrol?.facing, facing != .zero else { return nil }
                let origin = VecI(x: member.position.x.unitsTruncated, y: member.position.y.unitsTruncated)
                return PatrolCone(
                    id: member.id,
                    x: origin.x,
                    y: origin.y,
                    facing: facing,
                    headingMilli: Cordic.atan2Milli(y: facing.y.raw, x: facing.x.raw),
                    rangeUnits: spec.sightUnits,
                    halfAngleMilli: spec.sightHalfAngleMilliDegrees,
                    outline: outline(
                        origin: origin,
                        facing: facing,
                        rangeUnits: spec.sightUnits,
                        halfAngleMilli: spec.sightHalfAngleMilliDegrees,
                        solids: solids
                    )
                )
            }
    }

    /// Ray-cast outline: each ray stops at the nearest solid it meets.
    public static func outline(
        origin: VecI,
        facing: VecQ8,
        rangeUnits: Int,
        halfAngleMilli: Int,
        solids: [AABB]
    ) -> [VecI] {
        let ox = Double(origin.x)
        let oy = Double(origin.y)
        let base = atan2(Double(facing.y.raw), Double(facing.x.raw))
        let half = Double(halfAngleMilli) / 1000 * .pi / 180
        var points = [origin]
        for i in 0...rays {
            let angle = base - half + 2 * half * Double(i) / Double(rays)
            let dx = cos(angle)
            let dy = sin(angle)
            var reach = Double(rangeUnits)
            for box in solids {
                if let t = entry(ox: ox, oy: oy, dx: dx, dy: dy, box: box), t < reach { reach = max(0, t) }
            }
            points.append(VecI(x: Int((ox + dx * reach).rounded()), y: Int((oy + dy * reach).rounded())))
        }
        return points
    }

    /// Distance along the ray to where it enters `box`, or nil if it never
    /// does. A ray starting inside a box is stopped at once.
    private static func entry(ox: Double, oy: Double, dx: Double, dy: Double, box: AABB) -> Double? {
        var near = -Double.infinity
        var far = Double.infinity
        for (o, d, lo, hi) in [
            (ox, dx, Double(box.minX), Double(box.maxX)),
            (oy, dy, Double(box.minY), Double(box.maxY))
        ] {
            if abs(d) < 1e-12 {
                if o < lo || o > hi { return nil }
                continue
            }
            let t1 = (lo - o) / d
            let t2 = (hi - o) / d
            near = max(near, min(t1, t2))
            far = min(far, max(t1, t2))
        }
        guard near <= far, far >= 0 else { return nil }
        return max(0, near)
    }
}
