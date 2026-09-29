/// D-091 Transit Patrol fairness (`enemies-and-encounters.md` § Transit
/// Patrol, EN-030), proven against the arena data and the patrol rules:
///
/// 1. every waypoint lies inside its zone and outside every solid, gate, and
///    encounter trigger (also enforced at load by `ArenaLoader`);
/// 2. every member walks its whole loop: it arrives at every waypoint (a
///    Camera mount across a leg would pin it for the rest of the run);
/// 3. no cone ever reaches the Player spawn or any point of zone Z-01;
/// 4. at every tick of the full patrol cycle, a walkable route from the
///    Player spawn in Z-01 into the M-A trigger exists that no cone covers.
///
/// "Every tick" is literal. The members are simulated together from their
/// spawn with the rules' own movement (`EnemySystem.moveUnaware`, separation
/// included) until the joint configuration repeats. That gives the exact
/// transient and period, and every tick of both is checked. The Player takes
/// no part: until a member is alerted, nothing the Player does moves it.
///
/// Camera mounts are solids, and which Cameras stand depends on the seed, so
/// the proof runs for every Z-02 and Z-03 Camera subset a legal placement can
/// produce (zone quotas, incompatibilities, and the Z-02 tutorial-eligible
/// rule; a superset of the legal sets). Motion depends only on the Z-02
/// subset, which the proof confirms: no member ever comes within a tick's
/// reach of any other mount. Mounts outside Z-02 and Z-03 are added as walking
/// obstacles, which can only remove routes.
public enum PatrolFairness {
    public struct Report: Equatable, Sendable {
        /// Rule 1 failures.
        public var waypointViolations: [String] = []
        /// Rule 2 failures.
        public var unreachedWaypoints: [String] = []
        /// Joint configurations that never repeated within the budget, or
        /// members that came within reach of a mount outside Z-02.
        public var unproven: [String] = []
        /// Rule 3 failures.
        public var protectedCoverage: [String] = []
        /// Rule 4 failures.
        public var blockedTicks: [String] = []
        /// Ticks checked per Z-02 subset: transient plus period.
        public var cycles: [String: [Int]] = [:]

        public var passes: Bool {
            waypointViolations.isEmpty && unreachedWaypoints.isEmpty && unproven.isEmpty
                && protectedCoverage.isEmpty && blockedTicks.isEmpty
        }
    }

    /// The route and cone grid: `ArenaReachability.gridStep`.
    public static let step = ArenaReachability.gridStep
    /// A joint configuration that has not repeated after this many ticks is
    /// reported as unproven, never trusted.
    public static let tickBudget = 2_000_000

    public static func evaluate(_ manifest: ArenaManifest, content: CombatContent) -> Report {
        var report = Report()
        report.waypointViolations = waypointViolations(manifest)
        guard !manifest.patrols.isEmpty else { return report }
        guard manifest.patrols.count <= 3 else {
            report.unproven.append("more than three members: the joint key does not fit")
            return report
        }
        let enabled = manifest.cameraSockets.filter(\.enabled)
        let z02 = enabled.filter { $0.zoneId == "Z-02" }
        let z03 = enabled.filter { $0.zoneId == "Z-03" }
        let need02 = CameraPlacement.requiredByZone.first { $0.zone == "Z-02" }?.count ?? 2
        let need03 = CameraPlacement.requiredByZone.first { $0.zone == "Z-03" }?.count ?? 1
        let subsets02 = subsets(z02, size: need02).filter { $0.contains(where: \.tutorialEligible) && compatible($0) }
        let subsets03 = subsets(z03, size: need03).filter(compatible)
        let base = manifest.permanentSolids.map { (id: $0.id, box: $0.aabb) }
            + manifest.gates.filter { $0.initiallyClosed ?? false }.map { (id: $0.id, box: $0.aabb) }
        let half = manifest.standardCameraGeometry.mountCollisionRadiusUnits
        func mount(_ socket: CameraSocket) -> (id: String, box: AABB) {
            (SelectedCamera.mountSolidPrefix + socket.socketId, AABB(center: socket.position, halfSize: VecI(x: half, y: half)))
        }
        for a in subsets02 {
            let nameA = a.map(\.socketId).joined(separator: "+")
            let motion = base + a.map(mount)
            guard let orbit = jointOrbit(manifest: manifest, content: content, solids: motion) else {
                report.unproven.append("\(nameA): no repeat within \(tickBudget) ticks")
                continue
            }
            report.cycles[nameA] = [orbit.transient, orbit.period]
            // Motion ignored the mounts of other zones; prove none was ever
            // within a tick's reach. (Z-02 sockets outside the subset have
            // no mount in this configuration.)
            let outside = enabled.filter { $0.zoneId != "Z-02" }.map { mount($0).box }
            for (m, states) in orbit.states.enumerated() {
                let reach = states[0].radius + 2
                if states.contains(where: { s in
                    outside.contains { Circle(center: s.position, radiusUnits: reach).penetrates($0) }
                }) {
                    report.unproven.append("\(nameA) \(manifest.patrols[m].id): reaches a mount outside the subset")
                }
            }
            report.unreachedWaypoints += unreached(orbit, manifest: manifest, content: content, name: nameA)
            for b in subsets03 {
                let name = nameA + "+" + b.map(\.socketId).joined(separator: "+")
                let sight = motion + b.map(mount)
                let walk = sight.map(\.box) + enabled
                    .filter { $0.zoneId != "Z-02" && $0.zoneId != "Z-03" }
                    .map { mount($0).box }
                check(orbit, manifest: manifest, content: content, sight: sight, walk: walk, name: name, into: &report)
            }
        }
        return report
    }

    // MARK: - Rule 1

    public static func waypointViolations(_ manifest: ArenaManifest) -> [String] {
        var out: [String] = []
        for route in manifest.patrols {
            let zone = manifest.zones.first { $0.id == route.zoneId }
            for (k, p) in route.waypoints.enumerated() {
                let label = "\(route.id): waypoint \(k) (\(p.x), \(p.y))"
                if zone?.aabb.contains(p) != true { out.append("\(label) outside \(route.zoneId)") }
                for solid in manifest.permanentSolids where solid.aabb.contains(p) {
                    out.append("\(label) inside \(solid.id)")
                }
                for gate in manifest.gates where gate.aabb.contains(p) { out.append("\(label) inside \(gate.id)") }
                for trigger in manifest.encounterTriggers where trigger.aabb.contains(p) {
                    out.append("\(label) inside \(trigger.id)")
                }
            }
        }
        return out
    }

    // MARK: - Motion

    /// The members' joint motion from spawn (tick index 0) until the joint
    /// configuration repeats. Each member's distinct states are interned;
    /// `timeline[k][m]` indexes member m's state at tick k.
    struct JointOrbit {
        var states: [[EnemyBody]]
        var timeline: [[Int32]]
        var transient: Int
        var period: Int
        var ticks: Int { transient + period }
    }

    private struct MemberKey: Hashable {
        var x, y, fx, fy: Int64
        var target, dwell: Int
        init(_ e: EnemyBody) {
            x = e.position.x.raw
            y = e.position.y.raw
            fx = e.patrol?.facing.x.raw ?? 0
            fy = e.patrol?.facing.y.raw ?? 0
            target = e.patrol?.target ?? 0
            dwell = e.patrol?.dwellRemaining ?? 0
        }
    }

    static func jointOrbit(
        manifest: ArenaManifest,
        content: CombatContent,
        solids: [(id: String, box: AABB)]
    ) -> JointOrbit? {
        var allocator = EntityAllocator()
        var enemies: [EnemyBody] = []
        for (index, route) in manifest.patrols.enumerated() {
            guard let stats = content.standardEnemies[route.archetype] else { return nil }
            enemies.append(PatrolSystem.member(
                route: route, index: index, id: allocator.next(), stats: stats, tick: 1, nextSpecialTick: 1
            ))
        }
        let movement = UnawareMovement(arena: manifest, content: content)
        let bounds = manifest.boundsUnits.aabb
        let count = enemies.count
        var interned = [[MemberKey: Int32]](repeating: [:], count: count)
        var states = [[EnemyBody]](repeating: [], count: count)
        var timeline: [[Int32]] = []
        var seen: [UInt64: Int] = [:]
        for k in 0...tickBudget {
            var ids: [Int32] = []
            var packed: UInt64 = 0
            for m in 0..<count {
                let key = MemberKey(enemies[m])
                let id: Int32
                if let known = interned[m][key] {
                    id = known
                } else {
                    id = Int32(states[m].count)
                    interned[m][key] = id
                    states[m].append(enemies[m])
                }
                guard id < (1 << 21) else { return nil }
                ids.append(id)
                packed = packed << 21 | UInt64(id)
            }
            if let first = seen[packed] {
                return JointOrbit(states: states, timeline: timeline, transient: first, period: k - first)
            }
            seen[packed] = k
            timeline.append(ids)
            // One enemy phase for all-unaware members: ascending ID order.
            for index in enemies.indices {
                EnemySystem.moveUnaware(enemies: &enemies, index: index, movement: movement, bounds: bounds, solids: solids)
            }
        }
        return nil
    }

    /// Rule 2: an arrival at waypoint k starts the hold with the target still
    /// k, so each k must appear as a first hold tick somewhere in the orbit.
    static func unreached(_ orbit: JointOrbit, manifest: ArenaManifest, content: CombatContent, name: String) -> [String] {
        let dwell = content.patrol.dwellTicks
        var out: [String] = []
        for (m, route) in manifest.patrols.enumerated() {
            var arrived = Set<Int>()
            for state in orbit.states[m] {
                guard let patrol = state.patrol else { continue }
                if dwell > 0 ? patrol.dwellRemaining == dwell - 1 : false { arrived.insert(patrol.target) }
            }
            // With no hold, the target itself advancing past k is the arrival.
            if dwell == 0 { arrived = Set(orbit.states[m].compactMap { $0.patrol.map { ($0.target + route.waypoints.count - 1) % route.waypoints.count } }) }
            for k in route.waypoints.indices where !arrived.contains(k) {
                out.append("\(name) \(route.id): never arrives at waypoint \(k)")
            }
        }
        return out
    }

    // MARK: - Grid

    struct Grid {
        var minX: Int
        var minY: Int
        var cols: Int
        var rows: Int
        var walkable: [Bool]
        func point(_ i: Int) -> VecI { VecI(x: minX + (i % cols) * step, y: minY + (i / cols) * step) }
        func index(_ p: VecI) -> Int? {
            guard p.x >= minX, p.y >= minY else { return nil }
            let gx = (p.x - minX + step / 2) / step
            let gy = (p.y - minY + step / 2) / step
            guard gx < cols, gy < rows else { return nil }
            return gy * cols + gx
        }
    }

    /// The route domain: the grid over the union of Z-01, Z-02, and Z-03.
    /// Keeping the route inside it only makes the proof stricter.
    static func grid(_ manifest: ArenaManifest, walk: [AABB]) -> Grid {
        let zones = manifest.zones.filter { ["Z-01", "Z-02", "Z-03"].contains($0.id) }.map(\.aabb)
        let minX = zones.map(\.minX).min()! / step * step
        let minY = zones.map(\.minY).min()! / step * step
        let cols = (zones.map(\.maxX).max()! - minX) / step + 1
        let rows = (zones.map(\.maxY).max()! - minY) / step + 1
        let bounds = manifest.boundsUnits.aabb
        var walkable = [Bool](repeating: false, count: cols * rows)
        for i in walkable.indices {
            let p = VecI(x: minX + (i % cols) * step, y: minY + (i / cols) * step)
            walkable[i] = ArenaReachability.isWalkable(p, radius: PlayerBody.radiusUnits, bounds: bounds, solids: walk)
        }
        return Grid(minX: minX, minY: minY, cols: cols, rows: rows, walkable: walkable)
    }

    /// Whether the member in `state` sees `point`, by the rule itself.
    static func sees(_ state: EnemyBody, _ point: VecI, spec: PatrolSpec, solids: [(id: String, box: AABB)]) -> Bool {
        guard let facing = state.patrol?.facing else { return false }
        let q = point.asQ8
        return PatrolSystem.inCone(origin: state.position, facing: facing, point: q, spec: spec)
            && Collision.lineOfFireClear(from: state.position, to: q, solids: solids)
    }

    /// Grid cells the member's cone covers in `state`.
    static func coverage(_ state: EnemyBody, grid: Grid, spec: PatrolSpec, solids: [(id: String, box: AABB)]) -> [Int] {
        let r = spec.sightUnits + step
        let cx = state.position.x.unitsTruncated
        let cy = state.position.y.unitsTruncated
        var out: [Int] = []
        let gx0 = max(0, (cx - r - grid.minX) / step)
        let gx1 = min(grid.cols - 1, (cx + r - grid.minX) / step)
        let gy0 = max(0, (cy - r - grid.minY) / step)
        let gy1 = min(grid.rows - 1, (cy + r - grid.minY) / step)
        guard gx0 <= gx1, gy0 <= gy1 else { return [] }
        for gy in gy0...gy1 {
            for gx in gx0...gx1 {
                let i = gy * grid.cols + gx
                if sees(state, grid.point(i), spec: spec, solids: solids) { out.append(i) }
            }
        }
        return out
    }

    /// The first point of the Player spawn or the Z-01 rectangle (every
    /// point on an 8-unit lattice, walkable or not, edges included) the
    /// member sees in `state`, or nil.
    static func protectedPoint(_ state: EnemyBody, manifest: ArenaManifest, spec: PatrolSpec, solids: [(id: String, box: AABB)]) -> VecI? {
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        if sees(state, spawn, spec: spec, solids: solids) { return spawn }
        guard let z01 = manifest.zones.first(where: { $0.id == "Z-01" })?.aabb else { return nil }
        var y = z01.minY
        while y <= z01.maxY {
            var x = z01.minX
            while x <= z01.maxX {
                if sees(state, VecI(x: x, y: y), spec: spec, solids: solids) { return VecI(x: x, y: y) }
                x += step / 2
            }
            y += step / 2
        }
        return nil
    }

    /// Four-connected flood over walkable, uncovered cells from `start`;
    /// true when it enters `goal`.
    static func routeExists(grid: Grid, covered: [Bool], start: Int, goal: [Bool]) -> Bool {
        guard grid.walkable[start], !covered[start] else { return false }
        var seen = [Bool](repeating: false, count: covered.count)
        seen[start] = true
        var queue = [start]
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            if goal[i] { return true }
            let x = i % grid.cols
            let y = i / grid.cols
            if x + 1 < grid.cols { visit(i + 1) }
            if x > 0 { visit(i - 1) }
            if y + 1 < grid.rows { visit(i + grid.cols) }
            if y > 0 { visit(i - grid.cols) }
        }
        return false
        func visit(_ n: Int) {
            if seen[n] || !grid.walkable[n] || covered[n] { return }
            seen[n] = true
            queue.append(n)
        }
    }

    // MARK: - Rules 3 and 4 for one Camera subset

    private static func check(
        _ orbit: JointOrbit,
        manifest: ArenaManifest,
        content: CombatContent,
        sight: [(id: String, box: AABB)],
        walk: [AABB],
        name: String,
        into report: inout Report
    ) {
        let spec = content.patrol
        for (m, states) in orbit.states.enumerated() {
            for state in states {
                if let p = protectedPoint(state, manifest: manifest, spec: spec, solids: sight) {
                    report.protectedCoverage.append(
                        "\(name) \(manifest.patrols[m].id): at (\(state.position.x.unitsTruncated), \(state.position.y.unitsTruncated)) sees (\(p.x), \(p.y))"
                    )
                    break
                }
            }
        }

        let grid = grid(manifest, walk: walk)
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        guard let start = grid.index(spawn),
              let trigger = manifest.encounterTriggers.first(where: { $0.encounterId == "M-A" })?.aabb
        else {
            report.blockedTicks.append("\(name): no spawn cell or M-A trigger")
            return
        }
        let cells = grid.cols * grid.rows
        let goal = (0..<cells).map { trigger.contains(grid.point($0)) }
        let covers = orbit.states.map { states in states.map { coverage($0, grid: grid, spec: spec, solids: sight) } }
        // A superset of each member's coverage over the whole orbit.
        let unions = covers.map { Array(Set($0.joined())) }
        let blank = [Bool](repeating: false, count: cells)
        func passes(_ lists: [[Int]]) -> Bool {
            var covered = blank
            for list in lists { for c in list { covered[c] = true } }
            return routeExists(grid: grid, covered: covered, start: start, goal: goal)
        }
        // A tick passes outright if the route survives with some member's
        // cone widened to its whole-orbit union; otherwise the exact cones
        // decide. Both are memoised on the member states involved.
        var relaxed: [[Int32]: Bool] = [:]
        var exact: [[Int32]: Bool] = [:]
        var failures = 0
        for k in 0..<orbit.ticks {
            let ids = orbit.timeline[k]
            var ok = false
            for widened in ids.indices {
                var key = ids
                key[widened] = -1 - Int32(widened)
                let result: Bool
                if let known = relaxed[key] {
                    result = known
                } else {
                    result = passes(ids.indices.map { $0 == widened ? unions[$0] : covers[$0][Int(ids[$0])] })
                    relaxed[key] = result
                }
                if result { ok = true; break }
            }
            if !ok {
                if let known = exact[ids] {
                    ok = known
                } else {
                    ok = passes(ids.indices.map { covers[$0][Int(ids[$0])] })
                    exact[ids] = ok
                }
            }
            if !ok {
                failures += 1
                if failures <= 3 { report.blockedTicks.append("\(name): tick index \(k)") }
            }
        }
        if failures > 3 { report.blockedTicks.append("\(name): \(failures) blocked ticks in all") }
    }

    // MARK: - Subsets

    private static func subsets(_ items: [CameraSocket], size: Int) -> [[CameraSocket]] {
        if size == 0 { return [[]] }
        guard items.count >= size else { return [] }
        var out: [[CameraSocket]] = []
        for (i, first) in items.enumerated() {
            for rest in subsets(Array(items[(i + 1)...]), size: size - 1) { out.append([first] + rest) }
        }
        return out
    }

    private static func compatible(_ set: [CameraSocket]) -> Bool {
        for a in set {
            for b in set where a.socketId != b.socketId && a.incompatibleSocketIds.contains(b.socketId) {
                return false
            }
        }
        return true
    }
}
