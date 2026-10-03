import Foundation
import Testing
@testable import SurveillanceCore

/// D-093 / D-095 `SHADOW`: can the Transit Patrol be slipped at all?
///
/// A beam search over real `Simulation` copies, so every rule applies
/// exactly: cones and solids, auto-fire, Cameras, Tamper, surveillance
/// alerts. A branch dies when a patrol member stops being `unaware`, when the
/// Detection State reaches `tracked` (surveillance would alert everyone), or
/// when the Player dies. The goal is M-A activating with the whole patrol
/// still unaware: a `SHADOW` run.
///
/// Measurement, not a gate: it runs only with `SS_PATROL_SLIP=1`, takes
/// minutes, and writes what it finds to `SS_PATROL_SLIP_REPORT` (JSON lines).
@Suite(.serialized)
struct PatrolSlipSearch {
    /// One held input: a direction (or none) for `holdTicks` ticks.
    struct Move: Equatable, Sendable {
        var x: Int16
        var y: Int16
    }

    static let holdTicks: UInt64 = 6
    static let moves: [Move] = {
        let m: Int16 = PlayerCommand.axisMaximum
        let d: Int16 = 23_170 // m / √2, so diagonals move at full speed
        return [
            Move(x: 0, y: 0),
            Move(x: m, y: 0), Move(x: -m, y: 0), Move(x: 0, y: m), Move(x: 0, y: -m),
            Move(x: d, y: d), Move(x: d, y: -d), Move(x: -d, y: d), Move(x: -d, y: -d),
        ]
    }()

    struct Node {
        var sim: Simulation
        var path: [Int]
    }

    enum Outcome: String {
        case slipped, noPath
    }

    struct Result {
        var seed: UInt64
        var outcome: Outcome
        var ticks: UInt64
        var path: [Int]
        var expanded: Int
        var bestDistance: Int
    }

    static func patrolUnaware(_ state: WorldState) -> Bool {
        state.enemies.filter { $0.patrol != nil }.allSatisfy { $0.alive && $0.awareness == .unaware }
    }

    static func alive(_ state: WorldState) -> Bool {
        guard state.player.isAlive, patrolUnaware(state) else { return false }
        switch state.exposure.detectionState {
        case .hidden, .observed: return true
        case .tracked, .hunted, .lockdown: return false
        }
    }

    static func distanceToTrigger(_ state: WorldState, _ center: VecI) -> Int {
        let p = state.player.position
        let dx = p.x.unitsTruncated - center.x
        let dy = p.y.unitsTruncated - center.y
        return Int(Double(dx * dx + dy * dy).squareRoot())
    }

    static func search(seed: UInt64, beamWidth: Int, maxDepth: Int) throws -> Result {
        var start = try Simulation.make(seed: seed)
        start.step(command: .neutral(tick: 1))
        // Optionally stand at spawn first, so the search meets the patrol at
        // a later point of its loop (a human reaches the corridor later).
        let wait = UInt64(ProcessInfo.processInfo.environment["SS_PATROL_SLIP_WAIT"] ?? "") ?? 0
        while start.state.tick < 1 + wait { start.step(command: .neutral(tick: start.state.tick + 1)) }
        let trigger = try #require(start.state.arena.encounterTriggers.first { $0.encounterId == "M-A" })
        let center = trigger.aabb.center
        var beam = [Node(sim: start, path: [])]
        var expanded = 0
        var best = Int.max
        for _ in 0..<maxDepth {
            var next: [Node] = []
            var seen: Set<Int> = []
            for node in beam {
                for (index, move) in moves.enumerated() {
                    var sim = node.sim
                    var ok = true
                    for _ in 0..<holdTicks {
                        let tick = sim.state.tick + 1
                        let result = sim.step(command: PlayerCommand(tick: tick, moveX: move.x, moveY: move.y, dodgePressed: false))
                        expanded += 1
                        // An alert on the activation tick counts (`SHADOW`
                        // reads alerts before M-A's waveStarted, and the
                        // alert phase precedes the wave phase).
                        if result.events.contains(where: { $0.type == .enemyAlerted }), !patrolUnaware(sim.state) {
                            ok = false
                            break
                        }
                        if sim.state.encounters["M-A"]?.activated == true {
                            guard patrolUnaware(sim.state) else { ok = false; break }
                            return Result(seed: seed, outcome: .slipped, ticks: sim.state.tick,
                                          path: node.path + [index], expanded: expanded, bestDistance: 0)
                        }
                        if !alive(sim.state) { ok = false; break }
                    }
                    guard ok else { continue }
                    let p = sim.state.player.position
                    // One survivor per 16-unit cell per depth keeps the beam
                    // spread out instead of 400 copies of one route.
                    let cell = (p.x.unitsTruncated / 16) * 10_000 + p.y.unitsTruncated / 16
                    guard seen.insert(cell).inserted else { continue }
                    next.append(Node(sim: sim, path: node.path + [index]))
                }
            }
            guard !next.isEmpty else { break }
            next.sort { distanceToTrigger($0.sim.state, center) < distanceToTrigger($1.sim.state, center) }
            beam = Array(next.prefix(beamWidth))
            best = min(best, distanceToTrigger(beam[0].sim.state, center))
        }
        return Result(seed: seed, outcome: .noPath, ticks: beam.first?.sim.state.tick ?? 0,
                      path: beam.first?.path ?? [], expanded: expanded, bestDistance: best)
    }

    /// Replays a found path through a fresh run and the real `MedalTracker`:
    /// M-A started and no patrol member was alerted before it.
    static func replayEarnsShadow(seed: UInt64, path: [Int]) throws -> Bool {
        var sim = try Simulation.make(seed: seed)
        var tracker = MedalTracker()
        var result = sim.step(command: .neutral(tick: 1))
        tracker.notePatrol(sim.state)
        tracker.ingest(result.events)
        let wait = UInt64(ProcessInfo.processInfo.environment["SS_PATROL_SLIP_WAIT"] ?? "") ?? 0
        while sim.state.tick < 1 + wait {
            result = sim.step(command: .neutral(tick: sim.state.tick + 1))
            tracker.notePatrol(sim.state)
            tracker.ingest(result.events)
        }
        for index in path {
            let move = moves[index]
            for _ in 0..<holdTicks where !tracker.mobAStarted {
                result = sim.step(command: PlayerCommand(tick: sim.state.tick + 1, moveX: move.x, moveY: move.y, dodgePressed: false))
                tracker.notePatrol(sim.state)
                tracker.ingest(result.events)
            }
        }
        return tracker.mobAStarted && !tracker.patrolAlertedBeforeMobA
    }

    /// The naive line: steer straight at the M-A trigger every tick, no
    /// reading of the cones at all. If this slips too, slipping takes no skill.
    static func naiveDash(seed: UInt64) throws -> (slipped: Bool, ticks: UInt64) {
        var sim = try Simulation.make(seed: seed)
        var tracker = MedalTracker()
        var result = sim.step(command: .neutral(tick: 1))
        tracker.notePatrol(sim.state)
        tracker.ingest(result.events)
        let trigger = try #require(sim.state.arena.encounterTriggers.first { $0.encounterId == "M-A" })
        while !tracker.mobAStarted, sim.state.tick < 1_800, !sim.isTerminal {
            let p = sim.state.player.position
            let dx = Double(trigger.aabb.center.x - p.x.unitsTruncated)
            let dy = Double(trigger.aabb.center.y - p.y.unitsTruncated)
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            let mx = Int16(Double(PlayerCommand.axisMaximum) * dx / len)
            let my = Int16(Double(PlayerCommand.axisMaximum) * dy / len)
            result = sim.step(command: PlayerCommand(tick: sim.state.tick + 1, moveX: mx, moveY: my, dodgePressed: false))
            tracker.notePatrol(sim.state)
            tracker.ingest(result.events)
        }
        return (tracker.mobAStarted && !tracker.patrolAlertedBeforeMobA, sim.state.tick)
    }

    /// A route the search found on seed 1 (38 moves of 6 ticks, M-A at tick
    /// 229): it reaches M-A with the whole patrol unaware and earns `SHADOW`
    /// through the real `MedalTracker`. Evidence that the patrol can be
    /// slipped under the full rules; the probe pilot never does it. If a
    /// rules change breaks this route, re-run the search
    /// (`SS_PATROL_SLIP=1`) before concluding the patrol became unslippable.
    static let seedOneRoute = [5, 5, 5, 5, 1, 5, 5, 1, 1, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                               5, 5, 5, 5, 0, 3, 0, 5, 5, 5, 5, 5, 1, 5, 1, 5, 5, 1]

    @Test func aKnownRouteSlipsThePatrolAndEarnsShadow() throws {
        #expect(try Self.replayEarnsShadow(seed: 1, path: Self.seedOneRoute))
    }

    @Test func aStraightDashAtMobADoesNotSlipThePatrol() throws {
        #expect(try !Self.naiveDash(seed: 1).slipped, "slipping should take a deliberate line")
    }

    @Test func patrolSlipSearch() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SS_PATROL_SLIP"] == "1" else { return }
        let seeds = (env["SS_PATROL_SLIP_SEEDS"] ?? "1,2,3,4,5").split(separator: ",").compactMap { UInt64($0) }
        let beam = Int(env["SS_PATROL_SLIP_BEAM"] ?? "") ?? 150
        let depth = Int(env["SS_PATROL_SLIP_DEPTH"] ?? "") ?? 250
        var lines: [String] = []
        for seed in seeds {
            let r = try Self.search(seed: seed, beamWidth: beam, maxDepth: depth)
            let line = "{\"seed\":\(r.seed),\"outcome\":\"\(r.outcome.rawValue)\",\"ticks\":\(r.ticks),"
                + "\"bestDistance\":\(r.bestDistance),\"expanded\":\(r.expanded),"
                + "\"holdTicks\":\(Self.holdTicks),\"path\":[\(r.path.map(String.init).joined(separator: ","))]}"
            let replay = r.outcome == .slipped ? try Self.replayEarnsShadow(seed: seed, path: r.path) : false
            let dash = try Self.naiveDash(seed: seed)
            print("patrol slip \(line) replayShadow=\(replay) naiveDash=\(dash.slipped)@\(dash.ticks)")
            lines.append(line)
        }
        if let path = env["SS_PATROL_SLIP_REPORT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
