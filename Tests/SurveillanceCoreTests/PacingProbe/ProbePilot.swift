import Foundation
import SurveillanceCore

/// Scripted pilot for the T305 pacing probes and T901 long-replay evidence.
///
/// It starts from the policy in `App/DebugAutopilot.swift` — follow the
/// authoritative objective node, back away from close contacts, hold
/// Extraction. That policy has never finished a run (#63 records it dying at
/// M-C), and a headless copy of it wedged at M-B, pressing into a solid while
/// an enemy it could not shoot sat behind it. This pilot adds:
///
/// - **Grid navigation.** Breadth-first search over the live solids on the
///   `ArenaReachability` 16-unit grid, instead of straight-line steering with
///   a wall-follow.
/// - **Line-of-fire hunting.** The automatic weapon needs a clear line of fire
///   (`Collision.lineOfFireClear`). When every living enemy is out of range or
///   behind a solid, the pilot walks toward the nearest one instead of
///   orbiting a trigger it cannot fight from. It flees only contacts with a
///   clear line, so an enemy wedged behind a wall does not pin it.
/// - **Hazard reading.** It steps out of receipt-mine reach, sidesteps
///   projected elite and boss telegraphs (`lane`, `cone`) and hostile bolts on
///   a collision course, and presses Dodge only as a hit lands.
///
/// Its route knowledge is perfect and its reactions are instant unless the
/// profile says otherwise. It is a measuring instrument, not a model of a
/// person. It reads only `PresentationSnapshot` and never writes state.
struct ProbePilot {
    struct Profile: Sendable {
        var name: String
        /// The pilot decides from the snapshot this many ticks old.
        var perceptionDelayTicks: Int
        var usesDodge: Bool

        /// Perfect route knowledge, zero reaction latency, Dodge on close
        /// contact.
        static let competent = Profile(name: "competent", perceptionDelayTicks: 0, usesDodge: true)

        /// Same route knowledge, 250 ms (15-tick) perception latency, never
        /// dodges. A lower bound on a first run, not an estimate of one.
        static let firstRun = Profile(name: "firstRun", perceptionDelayTicks: 15, usesDodge: false)
    }

    struct Command {
        var moveX: Int16 = 0
        var moveY: Int16 = 0
        var dodge = false
    }

    let profile: Profile
    private let arena: ArenaManifest
    private let bounds: AABB

    /// Three simulated minutes on one objective node counts as a stall.
    static let objectiveTimeoutTicks = 60 * 180
    private var ticksOnObjective = 0
    private var lastObjective: CombatAuthorityNode?
    var stalled: Bool { ticksOnObjective >= Self.objectiveTimeoutTicks }

    private static let step = ArenaReachability.gridStep
    /// Player radius plus a margin, so paths do not graze corners.
    private static let clearance = 22
    private static let kiteRange = 180
    private static let woundedKiteRange = 300
    private static let woundedIntegrity = 45
    private static let arrivalRadius = 40
    private static let heavyMargin = 100
    private static let fireRange = Targeting.civicPulseRange - 24
    private static let replanTicks = 30

    private let cols: Int
    private let rows: Int
    private var walkable: [Bool] = []
    private var walkableSolids: [AABB] = []

    /// Receipt mines, armed or arming, as circles to keep out of.
    private var hazards: [(center: VecI, radius: Int)] = []
    private var path: [VecI] = []
    private var pathGoal: VecI?
    private var ticksSincePlan = 0
    private var orbitSign = 1
    private var lastPosition: VecI?
    private var stuckTicks = 0

    init(profile: Profile, arena: ArenaManifest) {
        self.profile = profile
        self.arena = arena
        bounds = arena.boundsUnits.aabb
        cols = (bounds.maxX - bounds.minX) / Self.step + 1
        rows = (bounds.maxY - bounds.minY) / Self.step + 1
    }

    // MARK: - Decision

    mutating func command(_ snapshot: PresentationSnapshot) -> Command {
        if snapshot.objectiveNode != lastObjective {
            lastObjective = snapshot.objectiveNode
            ticksOnObjective = 0
        } else {
            ticksOnObjective += 1
        }
        if snapshot.solids != walkableSolids { rebuildGrid(snapshot.solids) }

        let position = VecI(x: snapshot.player.x, y: snapshot.player.y)
        hazards = snapshot.mines.map { (VecI(x: $0.x, y: $0.y), $0.radius + PlayerBody.radiusUnits + 8) }
        if let last = lastPosition, distance(last, position) <= 2 { stuckTicks += 1 } else { stuckTicks = 0 }
        lastPosition = position
        if stuckTicks > 20 {
            // Wedged: drop the plan and orbit the other way.
            path = []
            orbitSign = -orbitSign
            stuckTicks = 0
        }

        let objective = destination(for: snapshot)
        let holdingExtraction = snapshot.extractionArmed && arena.extraction.aabb.contains(position)
        let solids = Array(zip(snapshot.solidIds, snapshot.solids)).map { (id: $0.0, box: $0.1) }
        let contacts = snapshot.enemies.map { enemy -> (point: VecI, d: Int, clear: Bool) in
            let point = VecI(x: enemy.x, y: enemy.y)
            let clear = Collision.lineOfFireClear(from: position.asQ8, to: point.asQ8, solids: solids)
            // The elite and the boss hit hardest on contact; keep them further off
            // by treating them as closer than they are.
            let heavy = enemy.role == "improperSearchDaemon" || enemy.role == "algorithmicModerate"
            return (point, distance(position, point) - (heavy ? Self.heavyMargin : 0), clear)
        }
        let nearest = contacts.min { $0.d < $1.d }
        // Only a contact with a clear line can close on the Player directly;
        // one wedged behind a solid is hunted, not fled from.
        let nearestClear = contacts.filter(\.clear).min { $0.d < $1.d }
        let hasShot = contacts.contains { $0.clear && $0.d <= Self.fireRange }
        let kiteRange = snapshot.playerIntegrity <= Self.woundedIntegrity
            ? Self.woundedKiteRange
            : Self.kiteRange

        if let mine = hazards.first(where: { distance($0.center, position) < $0.radius }), !holdingExtraction {
            // Standing in a mine's reach: step out first, whatever else is going on.
            return escape(from: position, hazard: mine.center)
        }
        if let evade = evasion(position: position, snapshot: snapshot), !holdingExtraction {
            // A telegraphed attack or an incoming bolt covers the Player: sidestep it.
            var command = steerOpen(from: position, along: (evade.x, evade.y))
            // Dodge is a rising edge with a cooldown: spend it only as the hit lands.
            command.dodge = profile.usesDodge && evade.urgent
            return command
        }
        if snapshot.extractionArmed {
            if holdingExtraction { return Command() }
            return navigate(from: position, to: arena.extraction.center)
        }
        if let threat = nearestClear, threat.d < kiteRange {
            var command = flee(from: position, threat: threat.point, toward: objective)
            command.dodge = profile.usesDodge && threat.d < kiteRange / 2
            return command
        }
        if let nearest {
            if !hasShot { return navigate(from: position, to: nearest.point) }
            return orbit(position: position, around: (nearestClear ?? nearest).point)
        }
        if distance(position, objective) > Self.arrivalRadius {
            return navigate(from: position, to: objective)
        }
        return Command()
    }

    private func destination(for snapshot: PresentationSnapshot) -> VecI {
        if snapshot.extractionArmed { return arena.extraction.center }
        let triggerId: String
        switch snapshot.objectiveNode {
        case .mobA: triggerId = "trigger-M-A"
        case .mobB: triggerId = "trigger-M-B"
        case .mobC: triggerId = "trigger-M-C"
        case .improperSearchDaemon: triggerId = "trigger-elite"
        case .algorithmicModerate: triggerId = "trigger-boss"
        case .extraction: return arena.extraction.center
        }
        return arena.encounterTriggers.first { $0.id == triggerId }?.center ?? arena.extraction.center
    }

    // MARK: - Movement primitives

    /// Of eight headings, the walkable one that best opens distance from the
    /// threat, with a small bias toward the objective.
    private func flee(from position: VecI, threat: VecI, toward objective: VecI) -> Command {
        var best: (score: Double, dx: Int, dy: Int)?
        for (dx, dy) in Self.headings {
            let probe = VecI(x: position.x + dx * 3, y: position.y + dy * 3)
            guard isOpen(probe) else { continue }
            let away = Double(distance(probe, threat))
            let toward = -Double(distance(probe, objective)) * 0.1
            let score = away + toward
            if best == nil || score > best!.score { best = (score, dx, dy) }
        }
        guard let best else { return vector(dx: position.x - threat.x, dy: position.y - threat.y) }
        return vector(dx: best.dx, dy: best.dy)
    }

    /// Summed sidestep direction away from every lane, cone, or hostile bolt
    /// whose reach covers the Player, or nil when none does.
    private func evasion(position: VecI, snapshot: PresentationSnapshot) -> (x: Double, y: Double, urgent: Bool)? {
        var ex = 0.0
        var ey = 0.0
        var urgent = false
        let px = Double(position.x)
        let py = Double(position.y)
        let body = Double(PlayerBody.radiusUnits + 10)
        for shape in snapshot.telegraphs where shape.kind != .emitterField {
            let unit = Cordic.headingUnit(milliDegrees: shape.headingMilli)
            let ul = (Double(unit.x) * Double(unit.x) + Double(unit.y) * Double(unit.y)).squareRoot()
            guard ul > 0 else { continue }
            let hx = Double(unit.x) / ul
            let hy = Double(unit.y) / ul
            let rx = px - Double(shape.x)
            let ry = py - Double(shape.y)
            let along = rx * hx + ry * hy
            let across = -rx * hy + ry * hx
            guard along > -body, along < Double(shape.rangeUnits) + body else { continue }
            let halfWidth: Double
            if shape.kind == .lane {
                halfWidth = Double(shape.widthUnits) / 2
            } else {
                let half = Double(shape.halfAngleMilli) / 1000 * .pi / 180
                halfWidth = max(0, along) * tan(min(half, 1.4))
            }
            guard abs(across) < halfWidth + body else { continue }
            // Leave on the side the Player already occupies.
            let side = across >= 0 ? 1.0 : -1.0
            ex += -hy * side
            ey += hx * side
            if shape.remainingTicks <= 3 { urgent = true }
        }
        for shot in snapshot.projectiles where shot.hostile {
            let vx = Double(shot.x - shot.previousX)
            let vy = Double(shot.y - shot.previousY)
            let speedSq = vx * vx + vy * vy
            guard speedSq > 0 else { continue }
            let rx = px - Double(shot.x)
            let ry = py - Double(shot.y)
            let t = (rx * vx + ry * vy) / speedSq
            guard t >= 0, t <= 40 else { continue }
            let mx = rx - vx * t
            let my = ry - vy * t
            let miss = (mx * mx + my * my).squareRoot()
            guard miss < Double(shot.radius) + body else { continue }
            let speed = speedSq.squareRoot()
            let cross = rx * vy - ry * vx
            let side = cross >= 0 ? 1.0 : -1.0
            ex += vy / speed * side
            ey += -vx / speed * side
            if t <= 6 { urgent = true }
        }
        if ex == 0, ey == 0 { return nil }
        return (ex, ey, urgent)
    }

    /// The open heading closest to a desired direction.
    private func steerOpen(from position: VecI, along direction: (x: Double, y: Double)) -> Command {
        var best: (score: Double, dx: Int, dy: Int)?
        for (dx, dy) in Self.headings {
            let probe = VecI(x: position.x + dx * 3, y: position.y + dy * 3)
            guard isOpen(probe) else { continue }
            let score = Double(dx) * direction.x + Double(dy) * direction.y
            if best == nil || score > best!.score { best = (score, dx, dy) }
        }
        guard let best else { return Command() }
        return vector(dx: best.dx, dy: best.dy)
    }

    /// Of eight headings, the solid-free one that leaves the hazard fastest.
    private func escape(from position: VecI, hazard: VecI) -> Command {
        var best: (d: Int, dx: Int, dy: Int)?
        for (dx, dy) in Self.headings {
            let probe = VecI(x: position.x + dx * 2, y: position.y + dy * 2)
            guard ArenaReachability.isWalkable(
                probe, radius: PlayerBody.radiusUnits, bounds: bounds, solids: walkableSolids
            ) else { continue }
            let d = distance(probe, hazard)
            if best == nil || d > best!.d { best = (d, dx, dy) }
        }
        guard let best else { return vector(dx: position.x - hazard.x, dy: position.y - hazard.y) }
        return vector(dx: best.dx, dy: best.dy)
    }

    /// Circle the contact at the current range, flipping side at a wall.
    private mutating func orbit(position: VecI, around point: VecI) -> Command {
        for _ in 0..<2 {
            let dx = -(position.y - point.y) * orbitSign
            let dy = (position.x - point.x) * orbitSign
            let magnitude = max(1, Int((Double(dx * dx + dy * dy)).squareRoot()))
            let probe = VecI(x: position.x + dx * 24 / magnitude, y: position.y + dy * 24 / magnitude)
            if isOpen(probe) { return vector(dx: dx, dy: dy) }
            orbitSign = -orbitSign
        }
        return Command()
    }

    private mutating func navigate(from position: VecI, to goal: VecI) -> Command {
        ticksSincePlan += 1
        if pathGoal.map({ distance($0, goal) > Self.step * 2 }) ?? true
            || path.isEmpty
            || ticksSincePlan >= Self.replanTicks
        {
            path = plan(from: position, to: goal)
            pathGoal = goal
            ticksSincePlan = 0
        }
        while let first = path.first, distance(first, position) <= Self.step, path.count > 1 {
            path.removeFirst()
        }
        guard let waypoint = path.first else {
            return vector(dx: goal.x - position.x, dy: goal.y - position.y)
        }
        return vector(dx: waypoint.x - position.x, dy: waypoint.y - position.y)
    }

    // MARK: - Grid

    private static let headings = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        .map { (dx: $0.0 * 8, dy: $0.1 * 8) }

    private mutating func rebuildGrid(_ solids: [AABB]) {
        walkableSolids = solids
        walkable = Array(repeating: false, count: cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols {
                walkable[gy * cols + gx] = ArenaReachability.isWalkable(
                    point(gx, gy), radius: Self.clearance, bounds: bounds, solids: solids
                )
            }
        }
    }

    private func point(_ gx: Int, _ gy: Int) -> VecI {
        VecI(x: bounds.minX + gx * Self.step, y: bounds.minY + gy * Self.step)
    }

    private func cell(_ p: VecI) -> (Int, Int) {
        let gx = min(max((p.x - bounds.minX + Self.step / 2) / Self.step, 0), cols - 1)
        let gy = min(max((p.y - bounds.minY + Self.step / 2) / Self.step, 0), rows - 1)
        return (gx, gy)
    }

    private func isOpen(_ p: VecI) -> Bool {
        ArenaReachability.isWalkable(p, radius: PlayerBody.radiusUnits, bounds: bounds, solids: walkableSolids)
            && !inHazard(p)
    }

    private func inHazard(_ p: VecI) -> Bool {
        hazards.contains { distance($0.center, p) < $0.radius }
    }

    /// Nearest walkable cell to `p`, searched outward ring by ring.
    private func nearestWalkable(_ p: VecI) -> Int? {
        let (cx, cy) = cell(p)
        for r in 0..<8 {
            for gy in max(0, cy - r)...min(rows - 1, cy + r) {
                for gx in max(0, cx - r)...min(cols - 1, cx + r) where walkable[gy * cols + gx] {
                    return gy * cols + gx
                }
            }
        }
        return nil
    }

    /// Eight-connected BFS; diagonal moves need both side cells open.
    private func plan(from start: VecI, to goal: VecI) -> [VecI] {
        guard let s = nearestWalkable(start), let g = nearestWalkable(goal) else { return [] }
        var parent = Array(repeating: -1, count: cols * rows)
        parent[s] = s
        var queue = [s]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == g { break }
            let cx = current % cols
            let cy = current / cols
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nx = cx + dx
                let ny = cy + dy
                guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
                let n = ny * cols + nx
                guard walkable[n], parent[n] == -1, !inHazard(point(nx, ny)) else { continue }
                if dx != 0, dy != 0, !walkable[cy * cols + nx] || !walkable[ny * cols + cx] { continue }
                parent[n] = current
                queue.append(n)
            }
        }
        guard parent[g] != -1 else { return [] }
        var cells: [Int] = []
        var c = g
        while c != s {
            cells.append(c)
            c = parent[c]
        }
        return cells.reversed().map { point($0 % cols, $0 / cols) }
    }

    // MARK: - Math

    private func distance(_ a: VecI, _ b: VecI) -> Int {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return Int((dx * dx + dy * dy).squareRoot())
    }

    /// Full-magnitude normalized command; the controller re-normalizes.
    private func vector(dx: Int, dy: Int) -> Command {
        let magnitude = (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot()
        guard magnitude > 0 else { return Command() }
        let scale = 32_767.0 / magnitude
        return Command(
            moveX: Int16(max(-32_767, min(32_767, (Double(dx) * scale).rounded()))),
            moveY: Int16(max(-32_767, min(32_767, (Double(dy) * scale).rounded()))),
            dodge: false
        )
    }
}
