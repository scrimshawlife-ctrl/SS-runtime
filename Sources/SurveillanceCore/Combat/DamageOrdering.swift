/// One projectile intersection within a single tick, and the total order the
/// damage phase resolves them in.
///
/// This lives outside `Simulation.resolveDamage` so the ordering rule can be
/// tested as a rule rather than inferred from the side effects of a 180-line
/// function. It was a local `struct Hit` and a `sort` closure, which meant
/// `combat.md` CB-005 through CB-007 — three of the load-bearing determinism
/// rules in the game — had no test by ID or by behaviour.
///
/// Determinism rests on this being a *total* order. Two builds that disagree on
/// any tie diverge on the tick it happens, and every replay after it is wrong;
/// gate B-002 exists to catch exactly that across architectures. So the order
/// never falls back on the order hits were discovered in, which depends on pool
/// iteration and is not authoritative.
struct DamageHit: Equatable, Sendable {
    /// Sweep intersection time along this tick's motion. Walls resolve at 0.
    var t: Int64
    /// Entity struck. `EntityID(0)` for a wall, which has no entity.
    var target: EntityID
    var projectile: EntityID
    var isWall: Bool
    /// Index into the projectile pool. Addressing only — never ordering, because
    /// pool position is an allocation detail and not authoritative.
    var index: Int

    /// `combat.md` CB-005, CB-007, CB-006, in that precedence:
    ///
    /// - **CB-005** earliest intersection first;
    /// - **CB-007** on an exact tie a wall consumes the projectile, so a shot
    ///   cannot pass through a solid to reach something behind it;
    /// - **CB-006** then the lower target ID;
    /// - then the lower projectile ID, so the order is total and two hits can
    ///   never compare equal.
    static func precedes(_ a: DamageHit, _ b: DamageHit) -> Bool {
        if a.t != b.t { return a.t < b.t }
        if a.isWall != b.isWall { return a.isWall && !b.isWall }
        if a.target != b.target { return a.target < b.target }
        return a.projectile < b.projectile
    }

    /// The authoritative resolution order for one tick's hits.
    static func ordered(_ hits: [DamageHit]) -> [DamageHit] {
        hits.sorted(by: precedes)
    }
}
