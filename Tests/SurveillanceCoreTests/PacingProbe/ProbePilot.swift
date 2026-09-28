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
        /// How the pilot treats Cameras (D-082, D-083).
        enum CameraStyle: Sendable {
            /// Ignores Cameras: the T305 policy.
            case indifferent
            /// Routes around Camera fields where a path exists, never walks
            /// at a Camera the weapon would then choose, and breaks line of
            /// sight to recover Exposure before the next wave can start.
            case stealth
            /// Walks at every Camera it passes with a clear line, so the
            /// weapon chooses and destroys it.
            case loud
        }

        var name: String
        /// The pilot decides from the snapshot this many ticks old.
        var perceptionDelayTicks: Int
        var usesDodge: Bool
        var cameraStyle: CameraStyle = .indifferent

        /// Perfect route knowledge, zero reaction latency, Dodge on close
        /// contact.
        static let competent = Profile(name: "competent", perceptionDelayTicks: 0, usesDodge: true)

        /// Same route knowledge, 250 ms (15-tick) perception latency, never
        /// dodges. A lower bound on a first run, not an estimate of one.
        static let firstRun = Profile(name: "firstRun", perceptionDelayTicks: 15, usesDodge: false)

        /// `competent`, played as a careful run.
        static let stealth = Profile(name: "stealth", perceptionDelayTicks: 0, usesDodge: true, cameraStyle: .stealth)

        /// `competent`, played as a loud run.
        static let loud = Profile(name: "loud", perceptionDelayTicks: 0, usesDodge: true, cameraStyle: .loud)
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
    /// Stealth: one step into a Camera field costs as much as this many
    /// steps outside one.
    private static let fieldStepCost = 12
    /// Loud: a Camera anchor this close with a clear line gets walked at.
    private static let loudReach = 360

    private let cols: Int
    private let rows: Int
    private var walkable: [Bool] = []
    private var walkableSolids: [AABB] = []

    /// A live Camera in the geometry the rules use: field origin and target
    /// anchor from the arena socket, not from the sprite.
    private struct LiveCamera {
        var id: EntityID
        var origin: VecQ8
        var anchor: VecQ8
        var headingMilli: Int
        var halfFieldMilli: Int
        var range: Int
    }
    private var liveCameras: [LiveCamera] = []
    /// Grid cells some live Camera field covers (stealth only).
    private var inField: [Bool] = []
    private var fieldKey: [EntityID] = []
    private var fieldSolids: [AABB] = []
    private var solidPairs: [(id: String, box: AABB)] = []
    private var huntCache: (target: VecI, goal: VecI)?
    private var detourStuckTicks = 0
    private var detourOverrideTicks = 0
    private var lastDetourPosition: VecI?
    private var huntTicks = 0

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
        let command = decide(snapshot)
        guard profile.cameraStyle == .stealth else { return command }
        if detourOverrideTicks > 0 {
            // Every Camera-free heading was blocked: walking past the Camera
            // is the only way on, and a careful player would take it too.
            detourOverrideTicks -= 1
            return command
        }
        let filtered = withoutChosenCamera(command, snapshot: snapshot)
        let position = VecI(x: snapshot.player.x, y: snapshot.player.y)
        if filtered.moveX != command.moveX || filtered.moveY != command.moveY {
            detourStuckTicks = lastDetourPosition == position ? detourStuckTicks + 1 : 0
            lastDetourPosition = position
            if detourStuckTicks >= 15 {
                detourStuckTicks = 0
                detourOverrideTicks = 60
                return command
            }
        } else {
            detourStuckTicks = 0
        }
        return filtered
    }

    private mutating func decide(_ snapshot: PresentationSnapshot) -> Command {
        if snapshot.objectiveNode != lastObjective {
            lastObjective = snapshot.objectiveNode
            ticksOnObjective = 0
        } else {
            ticksOnObjective += 1
        }
        if snapshot.solids != walkableSolids { rebuildGrid(snapshot.solids) }
        solidPairs = Array(zip(snapshot.solidIds, snapshot.solids)).map { (id: $0.0, box: $0.1) }
        refreshCameras(snapshot)

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
            let clear = Self.clearShot(from: position, to: point, solids: solids)
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
        if profile.cameraStyle == .loud, let camera = cameraToDestroy(from: position) {
            // Walk straight at it: the weapon now chooses it at every attack
            // opportunity until its three hits land.
            return vector(dx: camera.x - position.x, dy: camera.y - position.y)
        }
        if profile.cameraStyle == .stealth, contacts.isEmpty, snapshot.detection != .hidden,
           snapshot.detection != .lockdown
        {
            // Seen with nothing to fight: get out of every field and wait for
            // Exposure to fall back to hidden before the next wave can start.
            return hide(from: position)
        }
        if let nearest {
            if !hasShot {
                // Walk to the nearest place with a clear shot at it. Walking
                // at the enemy itself deadlocks when it is wedged behind a
                // solid and pursues along the far side (seen at M-A under
                // ss-rules-002).
                return navigate(from: position, to: firingPosition(from: position, at: nearest.point) ?? nearest.point)
            }
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

    /// A line of fire that stays clear when either end moves two units. The
    /// snapshot gives whole-unit positions; the rules test Q8 ones, so a
    /// segment that grazes a corner can be clear here and blocked there, and
    /// the pilot would then orbit a target the weapon cannot see.
    static func clearShot(from a: VecI, to b: VecI, solids: [(id: String, box: AABB)]) -> Bool {
        for (dx, dy) in [(0, 0), (2, 2), (-2, 2), (2, -2), (-2, -2)] {
            let from = VecI(x: a.x + dx, y: a.y + dy).asQ8
            let to = VecI(x: b.x - dx, y: b.y + dy).asQ8
            if !Collision.lineOfFireClear(from: from, to: to, solids: solids) { return false }
        }
        return true
    }

    /// Nearest walkable cell, by path, with a clear line of fire to `target`
    /// inside fire range and outside kiting range. Cached for `replanTicks`
    /// while the target stays within two grid steps.
    private mutating func firingPosition(from position: VecI, at target: VecI) -> VecI? {
        huntTicks += 1
        if let cached = huntCache, distance(cached.target, target) <= Self.step * 2, huntTicks < Self.replanTicks {
            return cached.goal
        }
        huntTicks = 0
        guard let s = nearestWalkable(position) else { return nil }
        var seen = Array(repeating: false, count: cols * rows)
        seen[s] = true
        var queue = [s]
        var head = 0
        // Stealth prefers a firing position no Camera field covers.
        let preferUnseen = profile.cameraStyle == .stealth && inField.count == cols * rows
        var goal: VecI?
        var fallback: VecI?
        var fallbackAt = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let p = point(current % cols, current / cols)
            let d = distance(p, target)
            if d <= Self.fireRange, d >= Self.kiteRange,
               Self.clearShot(from: p, to: target, solids: solidPairs)
            {
                if !preferUnseen || !inField[current] {
                    goal = p
                    break
                }
                if fallback == nil {
                    fallback = p
                    fallbackAt = head
                }
            }
            // Do not walk across the arena for an unseen spot.
            if fallback != nil, head - fallbackAt > 400 { break }
            for n in neighbours(current) where !seen[n] {
                seen[n] = true
                queue.append(n)
            }
        }
        goal = goal ?? fallback
        huntCache = goal.map { (target: target, goal: $0) }
        return goal
    }

    // MARK: - Cameras (stealth and loud)

    /// Live Cameras from the snapshot, located on their arena sockets, and
    /// for stealth the grid cells their fields cover, rebuilt when a Camera
    /// dies or the solids change.
    private mutating func refreshCameras(_ snapshot: PresentationSnapshot) {
        guard profile.cameraStyle != .indifferent else { return }
        liveCameras = snapshot.cameras.filter { $0.integrity > 0 }.compactMap { sprite in
            guard let socket = arena.cameraSockets.first(where: {
                $0.position.x == sprite.x && $0.position.y == sprite.y && $0.headingMilliDegrees == sprite.headingMilli
            }) else { return nil }
            return LiveCamera(
                id: sprite.id,
                origin: CameraPlacement.fieldOrigin(socket: socket, geometry: arena.standardCameraGeometry),
                anchor: CameraPlacement.targetAnchor(socket: socket, geometry: arena.standardCameraGeometry),
                headingMilli: sprite.headingMilli,
                halfFieldMilli: sprite.fieldAngleMilli / 2,
                range: sprite.range
            )
        }
        guard profile.cameraStyle == .stealth else { return }
        let key = liveCameras.map(\.id)
        guard key != fieldKey || walkableSolids != fieldSolids else { return }
        fieldKey = key
        fieldSolids = walkableSolids
        inField = Array(repeating: false, count: cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols where walkable[gy * cols + gx] {
                inField[gy * cols + gx] = seen(point(gx, gy))
            }
        }
    }

    /// True when some live Camera's field covers `p`, by the rules' own cone
    /// and line-of-sight test.
    private func seen(_ p: VecI) -> Bool {
        let q = p.asQ8
        return liveCameras.contains { camera in
            Collision.pointInCone(
                origin: camera.origin,
                point: q,
                headingMilli: camera.headingMilli,
                halfFieldMilli: camera.halfFieldMilli,
                rangeUnits: camera.range
            ) && Collision.lineOfFireClear(from: camera.origin, to: q, solids: solidPairs)
        }
    }

    /// Loud: the nearest live Camera within reach with a clear line of fire.
    private func cameraToDestroy(from position: VecI) -> VecI? {
        let q = position.asQ8
        let reach = Int64(Self.loudReach) * Q8.scale
        return liveCameras
            .filter {
                q.distanceSquared(to: $0.anchor) <= reach * reach
                    && Collision.lineOfFireClear(from: q, to: $0.anchor, solids: solidPairs)
            }
            .min { q.distanceSquared(to: $0.anchor) < q.distanceSquared(to: $1.anchor) }
            .map { VecI(x: $0.anchor.x.unitsTruncated, y: $0.anchor.y.unitsTruncated) }
    }

    /// Stealth: walk to the nearest cell no field covers, then stand still
    /// until Exposure recovers.
    private mutating func hide(from position: VecI) -> Command {
        let (cx, cy) = cell(position)
        if !inField[cy * cols + cx], !seen(position) { return Command() }
        guard let s = nearestWalkable(position) else { return Command() }
        var parent = Array(repeating: -1, count: cols * rows)
        parent[s] = s
        var queue = [s]
        var head = 0
        var goal: Int?
        while head < queue.count {
            let current = queue[head]
            head += 1
            if !inField[current], !inHazard(point(current % cols, current / cols)) {
                goal = current
                break
            }
            for n in neighbours(current) where parent[n] == -1 {
                parent[n] = current
                queue.append(n)
            }
        }
        guard let goal else { return Command() }
        return navigate(from: position, to: point(goal % cols, goal / cols))
    }

    /// Stealth: when no enemy is within the close-enemy range, the weapon
    /// would choose any Camera the Player walks at (D-082). Keep the heading
    /// closest to the intended one that chooses none, or stand.
    private func withoutChosenCamera(_ command: Command, snapshot: PresentationSnapshot) -> Command {
        guard command.moveX != 0 || command.moveY != 0 else { return command }
        let position = VecI(x: snapshot.player.x, y: snapshot.player.y)
        let close = Int64(Targeting.closeEnemyRange)
        let enemyClose = snapshot.enemies.contains {
            let dx = Int64($0.x - position.x)
            let dy = Int64($0.y - position.y)
            return dx * dx + dy * dy <= close * close
        }
        if enemyClose || !choosesCamera(command, at: position) { return command }
        let want = (x: Double(command.moveX), y: Double(command.moveY))
        var best: (score: Double, command: Command)?
        for (dx, dy) in Self.headings {
            let candidate = vector(dx: dx, dy: dy)
            let probe = VecI(x: position.x + dx * 3, y: position.y + dy * 3)
            guard ArenaReachability.isWalkable(
                probe, radius: PlayerBody.radiusUnits, bounds: bounds, solids: walkableSolids
            ), !choosesCamera(candidate, at: position) else { continue }
            let score = Double(dx) * want.x + Double(dy) * want.y
            if best == nil || score > best!.score { best = (score, candidate) }
        }
        guard let best, best.score > 0 else { return Command(dodge: command.dodge) }
        var result = best.command
        result.dodge = command.dodge
        return result
    }

    /// Whether this command's velocity makes some live Camera in range and
    /// in line of fire a chosen Camera, by the rules' own integer test.
    private func choosesCamera(_ command: Command, at position: VecI) -> Bool {
        let velocity = Movement.displacement(
            from: PlayerCommand(tick: 1, moveX: command.moveX, moveY: command.moveY, dodgePressed: false),
            dodgeActive: false,
            ghostStep: false
        )
        let q = position.asQ8
        return liveCameras.contains { camera in
            Targeting.isChosen(velocity: velocity, from: q, to: camera.anchor)
                && Targeting.inRange(q.distanceSquared(to: camera.anchor))
                && Collision.lineOfFireClear(from: q, to: camera.anchor, solids: solidPairs)
        }
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
    ///
    /// Within the first ring that has any, it takes the closest cell with no
    /// solid between it and `p`: the first cell in scan order can lie across
    /// a thin wall, and a path planned from there pins the Player against
    /// that wall (seen at M-A under ss-rules-002).
    private func nearestWalkable(_ p: VecI) -> Int? {
        let (cx, cy) = cell(p)
        for r in 0..<8 {
            var best: (clear: Bool, d: Int, index: Int)?
            for gy in max(0, cy - r)...min(rows - 1, cy + r) {
                for gx in max(0, cx - r)...min(cols - 1, cx + r) where walkable[gy * cols + gx] {
                    let q = point(gx, gy)
                    let clear = solidPairs.isEmpty
                        || Collision.lineOfFireClear(from: p.asQ8, to: q.asQ8, solids: solidPairs)
                    let candidate = (clear: clear, d: distance(p, q), index: gy * cols + gx)
                    if let current = best {
                        if (candidate.clear && !current.clear)
                            || (candidate.clear == current.clear && candidate.d < current.d)
                        {
                            best = candidate
                        }
                    } else {
                        best = candidate
                    }
                }
            }
            if let best { return best.index }
        }
        return nil
    }

    /// Walkable, hazard-free eight-connected neighbours; diagonal moves need
    /// both side cells open.
    private func neighbours(_ current: Int) -> [Int] {
        let cx = current % cols
        let cy = current / cols
        var result: [Int] = []
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
            let nx = cx + dx
            let ny = cy + dy
            guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
            let n = ny * cols + nx
            guard walkable[n], !inHazard(point(nx, ny)) else { continue }
            if dx != 0, dy != 0, !walkable[cy * cols + nx] || !walkable[ny * cols + cx] { continue }
            result.append(n)
        }
        return result
    }

    /// Eight-connected shortest path. Every step costs one, except that the
    /// stealth pilot pays `fieldStepCost` to step into a Camera field, so it
    /// goes around a field wherever a detour exists and through it only
    /// where none does (Dial's bucket queue over integer costs).
    private func plan(from start: VecI, to goal: VecI) -> [VecI] {
        guard let s = nearestWalkable(start), let g = nearestWalkable(goal) else { return [] }
        let avoid = profile.cameraStyle == .stealth && inField.count == cols * rows
        if !avoid { return breadthFirst(from: s, to: g) }
        var parent = Array(repeating: -1, count: cols * rows)
        var cost = Array(repeating: Int.max, count: cols * rows)
        parent[s] = s
        cost[s] = 0
        var buckets: [[Int]] = [[s]]
        var d = 0
        search: while d < buckets.count {
            var i = 0
            while i < buckets[d].count {
                let current = buckets[d][i]
                i += 1
                if cost[current] != d { continue }
                if current == g { break search }
                for n in neighbours(current) {
                    let step = avoid && inField[n] ? Self.fieldStepCost : 1
                    let next = d + step
                    guard next < cost[n] else { continue }
                    cost[n] = next
                    parent[n] = current
                    while buckets.count <= next { buckets.append([]) }
                    buckets[next].append(n)
                }
            }
            d += 1
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

    /// The T305 planner, unchanged: eight-connected BFS.
    private func breadthFirst(from s: Int, to g: Int) -> [VecI] {
        var parent = Array(repeating: -1, count: cols * rows)
        parent[s] = s
        var queue = [s]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == g { break }
            for n in neighbours(current) where parent[n] == -1 {
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
