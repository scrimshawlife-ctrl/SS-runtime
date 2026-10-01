import Foundation
import Testing
@testable import SurveillanceCore

/// D-091 Transit Patrol (`enemies-and-encounters.md` § Transit Patrol,
/// EN-024 to EN-030), D-090 drift (EN-031), and the D-090 damage-taken
/// remainder (`player-controller.md` § Damage response).
@Suite(.serialized)
struct TransitPatrolTests {
    // MARK: - Helpers

    /// A run whose only patrol is `route`, with the weapon kept quiet and the
    /// Player parked at the spawn unless moved.
    private static func sim(route: PatrolRoute, content: CombatContent = .bundled()) throws -> Simulation {
        var arena = try ArenaManifest.bundled()
        arena.patrols = [route]
        var sim = try Simulation(seed: 1, arena: arena, content: content)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        return sim
    }

    private static func route(_ points: [VecI], archetype: ArchetypeID = .fogAnalyticsCloud) -> PatrolRoute {
        PatrolRoute(id: "test", zoneId: "Z-05", archetype: archetype, waypoints: points)
    }

    private static func step(_ sim: inout Simulation) -> TickResult {
        sim.step(command: .neutral(tick: sim.state.tick + 1))
    }

    private static func member(_ sim: Simulation) -> EnemyBody? {
        sim.state.enemies.first { $0.patrol != nil }
    }

    // MARK: - EN-024 spawn

    /// EN-024: at run start every `patrols` member spawns unaware at its first
    /// waypoint, heading for the second, facing from the first to the second,
    /// in the first tick's spawn phase and in route order.
    @Test func patrolEN024MembersSpawnUnawareAtTheirFirstWaypoint() throws {
        var sim = try Simulation.make(seed: 1)
        #expect(sim.state.enemies.isEmpty, "nothing exists before the first tick")
        _ = Self.step(&sim)
        let routes = sim.state.arena.patrols
        #expect(routes.count == 3)
        let members = sim.state.enemies.filter { $0.patrol != nil }.sorted { $0.id < $1.id }
        #expect(members.count == routes.count)
        for (index, (member, route)) in zip(members, routes).enumerated() {
            let first = route.waypoints[0]
            let second = route.waypoints[1]
            #expect(member.archetype == route.archetype)
            #expect(member.awareness == .unaware)
            #expect(member.position == first.asQ8)
            #expect(member.patrol == PatrolState(
                route: index, target: 1, dwellRemaining: 0,
                facing: VecI(x: second.x - first.x, y: second.y - first.y).asQ8
            ))
            // D-093: 200% of the archetype Integrity.
            #expect(member.integrity == (sim.state.content.standardEnemies[route.archetype]?.hp ?? 0) * sim.state.content.patrol.integrityPercent / 100)
            #expect(member.spawnTick == 1)
        }
        #expect(sim.state.encounters.values.allSatisfy { !$0.activated && $0.living == 0 && $0.spawned == 0 })
    }

    // MARK: - EN-025 patrolling

    /// EN-025: a member walks at 40% of its archetype speed, holds 30 ticks on
    /// reaching a waypoint (within 4 units), then heads for the next,
    /// wrapping from the last to the first.
    @Test func patrolEN025HoldsThirtyTicksThenHeadsForTheNextAndWraps() throws {
        let a = VecI(x: 1500, y: 300)
        let b = VecI(x: 1540, y: 300)
        var sim = try Self.sim(route: Self.route([a, b]))
        _ = Self.step(&sim)
        let speed = PatrolSystem.scaledSpeedQ8(unitsPerSecond: 84, percent: 40)
        var targets: [Int] = []
        var holds: [Int] = []
        var run = 0
        var previous = try #require(Self.member(sim))
        for _ in 0..<400 {
            _ = Self.step(&sim)
            let now = try #require(Self.member(sim))
            #expect(now.awareness == .unaware)
            let moved = IntMath.isqrt(now.position.distanceSquared(to: previous.position))
            #expect(moved <= speed, "never faster than 40%")
            if moved == 0 {
                run += 1
            } else if run > 0 {
                holds.append(run)
                run = 0
            }
            if targets.last != now.patrol?.target { targets.append(now.patrol!.target) }
            previous = now
        }
        #expect(speed == IntMath.mulDivHalfAway(84 * 40, Q8.scale, 6000))
        #expect(holds.count >= 3)
        #expect(holds.allSatisfy { $0 == 30 }, "\(holds)")
        #expect(targets.starts(with: [1, 0, 1, 0]), "wraps: \(targets)")
    }

    /// Facing is the last non-zero travel direction: it holds through a
    /// dwell and turns with the next leg.
    @Test func facingIsTheLastTravelDirection() throws {
        var sim = try Self.sim(route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1540, y: 300)]))
        _ = Self.step(&sim)
        var sawEast = false
        var sawWest = false
        for _ in 0..<300 {
            _ = Self.step(&sim)
            let member = try #require(Self.member(sim))
            let facing = try #require(member.patrol?.facing)
            #expect(facing != .zero)
            if member.patrol?.dwellRemaining ?? 0 > 0 {
                // Holding: the facing is the leg just walked.
                #expect(member.velocity == .zero)
            }
            if facing.x.raw > 0 { sawEast = true }
            if facing.x.raw < 0 { sawWest = true }
        }
        #expect(sawEast && sawWest)
    }

    // MARK: - EN-026 to EN-028 cone sight

    /// A member at (1500, 300) facing +x, and the Player placed at `offset`
    /// from it before the first alert check (tick 2).
    private static func coneCase(_ offset: VecI) throws -> (alerts: [AuthoritativeEvent], member: EnemyBody) {
        var sim = try Self.sim(route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1900, y: 300)]))
        sim.testing_setPlayerPosition(VecI(x: 1500 + offset.x, y: 300 + offset.y))
        _ = Self.step(&sim)
        let result = Self.step(&sim)
        return (result.events.filter { $0.type == .enemyAlerted }, try #require(Self.member(sim)))
    }

    /// EN-026: the Player 200 units away inside the 45° cone with a clear line
    /// alerts the member, cause `sight`.
    @Test func patrolEN026PlayerInsideTheConeIsSeen() throws {
        for offset in [VecI(x: 200, y: 0), VecI(x: 150, y: 132)] { // on axis; 41.3° off
            let (alerts, member) = try Self.coneCase(offset)
            #expect(alerts.count == 1, "\(offset)")
            #expect(alerts.first?.payload["cause"] == .string("sight"))
            #expect(member.awareness == .aware)
        }
    }

    /// EN-027: at 200 units but 60° off the facing, the member stays unaware,
    /// although all-round sight (320) would have seen it.
    @Test func patrolEN027PlayerOutsideTheAngleIsNotSeen() throws {
        for offset in [VecI(x: 100, y: 173), VecI(x: -200, y: 0), VecI(x: 0, y: -200)] {
            let (alerts, member) = try Self.coneCase(offset)
            #expect(alerts.isEmpty, "\(offset)")
            #expect(member.awareness == .unaware)
        }
    }

    /// EN-028: at 300 units, inside the angle but beyond 240, unaware; the
    /// range is inclusive at 240.
    @Test func patrolEN028PlayerBeyondTheRangeIsNotSeen() throws {
        let (far, farMember) = try Self.coneCase(VecI(x: 300, y: 0))
        #expect(far.isEmpty)
        #expect(farMember.awareness == .unaware)
        let (edge, _) = try Self.coneCase(VecI(x: 240, y: 0))
        #expect(edge.count == 1)
        let (past, _) = try Self.coneCase(VecI(x: 241, y: 0))
        #expect(past.isEmpty)
    }

    /// The angle test is the D-082 integer test at 45°: exactly on the edge
    /// is inside, one unit past it is not.
    @Test func coneAngleIsTheExactIntegerTest() {
        let spec = CombatContent.bundled().patrol
        let origin = VecI(x: 0, y: 0).asQ8
        let facing = VecI(x: 1, y: 0).asQ8
        #expect(PatrolSystem.inCone(origin: origin, facing: facing, point: VecI(x: 100, y: 100).asQ8, spec: spec))
        #expect(!PatrolSystem.inCone(origin: origin, facing: facing, point: VecI(x: 100, y: 101).asQ8, spec: spec))
        #expect(!PatrolSystem.inCone(origin: origin, facing: .zero, point: VecI(x: 100, y: 0).asQ8, spec: spec))
        #expect(!PatrolSystem.inCone(origin: origin, facing: facing, point: origin, spec: spec))
    }

    /// A solid between blocks cone sight.
    @Test func coneSightNeedsAClearLine() throws {
        // solid-09-grid-island-a spans x 1536...1664, y 640...768.
        var sim = try Self.sim(route: Self.route([VecI(x: 1480, y: 704), VecI(x: 1900, y: 704)]))
        sim.testing_setPlayerPosition(VecI(x: 1700, y: 704))
        _ = Self.step(&sim)
        let result = Self.step(&sim)
        #expect(!result.events.contains { $0.type == .enemyAlerted })
    }

    /// D-089 causes apply with the cone in place of sight: surveillance
    /// alerts a member anywhere, and damage alerts it.
    @Test func surveillanceAndDamageAlertPatrolMembers() throws {
        var sim = try Self.sim(route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1900, y: 300)]))
        _ = Self.step(&sim)
        sim.testing_setExposure(500)
        let result = Self.step(&sim)
        #expect(result.events.first { $0.type == .enemyAlerted }?.payload["cause"] == .string("surveillance"))

        var hit = try Self.sim(route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1900, y: 300)], archetype: .victorianVendor))
        _ = Self.step(&hit)
        hit.testing_emptyCivicPool()
        hit.testing_injectPulseHitting(position: try #require(Self.member(hit)).position)
        _ = Self.step(&hit)
        #expect(Self.member(hit)?.awareness == .struck)
        // D-093: the patrol Vendor spawns at 200% (180); the ambush (x3) takes 30.
        #expect(Self.member(hit)?.integrity == 180 - 30, "the ambush multiplier applies")
        let next = Self.step(&hit)
        #expect(next.events.first { $0.type == .enemyAlerted }?.payload["cause"] == .string("damage"))
    }

    /// Once alerted a member runs its archetype's state machine and pursues
    /// the Player anywhere; it never resumes patrol, and its cone is gone.
    @Test func alertedMemberPursuesAndLosesItsCone() throws {
        var sim = try Self.sim(
            route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1900, y: 300)], archetype: .autonomousInformant)
        )
        _ = Self.step(&sim)
        #expect(PresentationSnapshot(sim.state).patrolCones.count == 1)
        sim.testing_setExposure(500)
        _ = Self.step(&sim)
        let start = try #require(Self.member(sim))
        #expect(start.awareness == .aware)
        #expect(PresentationSnapshot(sim.state).patrolCones.isEmpty)
        for _ in 0..<60 {
            sim.testing_setExposure(500)
            _ = Self.step(&sim)
        }
        let later = try #require(Self.member(sim))
        let player = sim.state.player.position
        #expect(later.position.distanceSquared(to: player) < start.position.distanceSquared(to: player))
        #expect(later.awareness == .aware)
    }

    // MARK: - EN-032 / EN-033 targeting (D-092)

    /// A member at (1500, 300) facing +x and the Player `offset` behind it
    /// (outside the cone, so it stays unaware), with only the weapon's first
    /// opportunity (tick 30) to look at.
    /// The Player's held direction: toward the member (+x), sideways (+y), or none.
    private enum Heading { case toward, sideways, still }

    private static func targetingCase(distance: Int, heading: Heading = .toward) throws -> (fired: [AuthoritativeEvent], damage: [AuthoritativeEvent], member: EnemyBody) {
        var sim = try Self.sim(route: Self.route([VecI(x: 1500, y: 300), VecI(x: 1900, y: 300)]))
        sim.testing_emptyCivicPool()
        _ = Self.step(&sim)
        let id = try #require(Self.member(sim)).id
        var fired: [AuthoritativeEvent] = []
        var damage: [AuthoritativeEvent] = []
        while sim.state.tick < 75 {
            // Hold the Player a fixed distance behind the walking member.
            let member = try #require(sim.state.enemies.first { $0.id == id })
            sim.testing_setPlayerPosition(VecI(x: member.position.x.unitsTruncated - distance, y: 300))
            // D-093: a patrol member is chosen only while the Player moves
            // toward it; the command sets this tick's velocity.
            let (mx, my): (Int16, Int16) = heading == .toward ? (32767, 0) : heading == .sideways ? (0, 32767) : (0, 0)
            let result = sim.step(command: PlayerCommand(tick: sim.state.tick + 1, moveX: mx, moveY: my, dodgePressed: false))
            fired += result.events.filter { $0.type == .weaponFired }
            damage += result.events.filter { $0.type == .entityDamaged && $0.primaryEntityId == id }
        }
        return (fired, damage, try #require(sim.state.enemies.first { $0.id == id }))
    }

    /// EN-032: an unaware patrol member 300 units away, nothing else in
    /// range: not targeted, no projectile, still unaware.
    @Test func patrolEN032UnawareMemberBeyond240IsNotATarget() throws {
        let (fired, damage, member) = try Self.targetingCase(distance: 300)
        #expect(fired.isEmpty)
        #expect(damage.isEmpty)
        #expect(member.awareness == .unaware)
    }

    /// EN-033 / EN-034: the same member at 230 units, the Player moving
    /// toward it, is targeted and ambushed: ×3 is 30 damage, and the patrol
    /// Fog Cloud's 200% Integrity (60) survives it, alerted by the hit.
    @Test func patrolEN033UnawareMemberWithin240IsTargetedAndAmbushed() throws {
        let (fired, damage, member) = try Self.targetingCase(distance: 230)
        #expect(fired.count >= 1)
        #expect(fired.first?.secondaryEntityId == member.id)
        #expect(damage.first?.payload["amount"] == .integer(30))
        #expect(member.alive)
        #expect(member.awareness != .unaware)
    }

    /// EN-035: at 230 units but moving sideways, the weapon holds fire.
    @Test func patrolEN035MovingPastHoldsFire() throws {
        for heading in [Heading.sideways, .still] {
            let (fired, damage, member) = try Self.targetingCase(distance: 230, heading: heading)
            #expect(fired.isEmpty, "\(heading)")
            #expect(damage.isEmpty, "\(heading)")
            #expect(member.awareness == .unaware, "\(heading)")
        }
    }

    /// D-093: a patrol member spawns with 200% of its archetype Integrity.
    @Test func patrolMembersSpawnAtDoubleIntegrity() throws {
        var sim = try Simulation.make(seed: 1)
        _ = Self.step(&sim) // members spawn in the first tick's spawn phase
        let stats = sim.state.content.standardEnemies
        let members = sim.state.enemies.filter { $0.patrol != nil }
        #expect(!members.isEmpty)
        for m in members { #expect(m.integrity == stats[m.archetype]!.hp * 2, "\(m.archetype)") }
    }

    /// The limit is inclusive at 240, applies only while unaware, and only to
    /// patrol members.
    @Test func patrolTargetingLimitIsInclusiveAndUnawareOnly() throws {
        var player = PlayerBody(id: EntityID(1), spawn: VecI(x: 0, y: 0), integrity: 150)
        // D-093: moving toward the member (+x); a standing Player chooses none.
        player.velocity = VecI(x: 4, y: 0).asQ8
        func body(_ x: Int, awareness: EnemyAwareness, patrol: Bool) -> EnemyBody {
            var e = EnemyBody(
                id: EntityID(9), archetype: .fogAnalyticsCloud, position: VecI(x: x, y: 0).asQ8, velocity: .zero,
                integrity: 30, radius: 18, speedUnitsPerSecond: 84, contactDps: 4, state: .pursue, stateTicks: 0,
                spawnTick: 0, nextSpecialTick: 0, lockPosition: nil, encounterId: "t", awareness: awareness
            )
            if patrol { e.patrol = PatrolState(route: 0, target: 1, dwellRemaining: 0, facing: VecI(x: 1, y: 0).asQ8) }
            return e
        }
        func chosen(_ e: EnemyBody) -> Bool {
            Targeting.select(player: player, enemies: [e], cameras: [], solids: [], unawarePatrolRange: 240) != nil
        }
        #expect(chosen(body(240, awareness: .unaware, patrol: true)))
        #expect(!chosen(body(241, awareness: .unaware, patrol: true)))
        #expect(chosen(body(400, awareness: .aware, patrol: true)), "an alerted member is a normal target")
        #expect(chosen(body(400, awareness: .unaware, patrol: false)), "encounter enemies keep the 512 reach")
        player.velocity = .zero
        #expect(!chosen(body(200, awareness: .unaware, patrol: true)), "a standing Player does not choose a patrol member")
        #expect(chosen(body(200, awareness: .unaware, patrol: false)), "encounter enemies need no heading")
    }

    // MARK: - Integrity (D-092)

    /// The Player spawns with `player.integrity` (150) and clamps there; the
    /// snapshot carries the bar's full value, and the receipt the Integrity
    /// actually removed.
    @Test func playerIntegrityComesFromContent() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        #expect(sim.state.content.player.integrity == 150)
        #expect(sim.state.player.integrity == 150)
        #expect(sim.state.player.maxIntegrity == 150)
        #expect(PresentationSnapshot(sim.state).playerMaxIntegrity == 150)
        sim.testing_setPlayerIntegrity(999)
        #expect(sim.state.player.integrity == 150, "clamps to 0...player.integrity")

        var content = CombatContent.bundled()
        content.player.integrity = 60
        let other = try Simulation.withoutPatrol(seed: 1, content: content)
        #expect(other.state.player.integrity == 60)
        let standard = try Simulation.withoutPatrol(seed: 1)
        #expect(other.state.digest() != standard.state.digest())

        // A lethal run: 300 bolt damage at 50% is exactly the 150 pool.
        var lethal = try Simulation.withoutPatrol(seed: 1)
        lethal.testing_fillCivicPool(count: Targeting.activeCeiling)
        lethal.testing_injectHostileBolt(damage: 299)
        _ = Self.step(&lethal)
        #expect(lethal.state.player.integrity == 1)
        #expect(lethal.state.outcome == .playing)
        lethal.testing_injectHostileBolt(damage: 1)
        _ = Self.step(&lethal)
        #expect(lethal.state.player.integrity == 0)
        #expect(lethal.state.outcome == .failure)
        #expect(RunReceipt(lethal.state).damageTaken == 150)
    }

    // MARK: - EN-029 scope

    /// EN-029: a member's death counts in the receipt, completes no
    /// encounter, starts no wave, and adds no heat.
    @Test func patrolEN029DeathCountsInTheReceiptOnly() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        _ = Self.step(&sim)
        let members = sim.state.enemies.filter { $0.patrol != nil }
        #expect(members.count == 3)
        sim.testing_emptyCivicPool()
        // D-093: members spawn at 200% (60). The ambush (x3) is 30 and the next
        // hit in the same tick 10, so three pulses each (30 + 10 + 10) leave 10;
        // a fourth (10) kills. Four pulses per member, one tick.
        for member in members { for _ in 0..<4 { sim.testing_injectPulseHitting(position: member.position) } }
        let before = sim.state.encounters
        let result = Self.step(&sim)
        #expect(result.events.filter { $0.type == .entityDied }.count == 3)
        #expect(!result.events.contains { $0.type == .mobEncounterCompleted || $0.type == .waveStarted })
        #expect(sim.state.encounters == before)
        #expect(sim.state.exposure.exposure == 0)
        let receipt = RunReceipt(sim.state)
        #expect(receipt.defeatsByArchetype["fogAnalyticsCloud"] == 2)
        #expect(receipt.defeatsByArchetype["autonomousInformant"] == 1)
    }

    /// Patrol members never join a wave's queue, even at heat.
    @Test func patrolIsOutsideHeat() throws {
        var sim = try Simulation.make(seed: 1)
        _ = Self.step(&sim)
        sim.testing_setExposure(500)
        let trigger = sim.state.arena.encounterTriggers.first { $0.encounterId == "M-A" }!
        sim.testing_setPlayerPosition(trigger.center)
        _ = Self.step(&sim)
        let authored = HeatReinforcementTests.authored("M-A", wave: 0, content: sim.state.content).count
        let heat = sim.state.content.heat.reinforcements(encounter: "M-A", state: .tracked)
        #expect(sim.state.encounters["M-A"]?.spawnQueue.count == authored + heat)
        #expect(sim.state.enemies.filter { $0.patrol != nil }.allSatisfy { $0.encounterId.hasPrefix("patrol:") })
    }

    // MARK: - EN-030 fairness

    /// EN-030 and the § Transit Patrol fairness bullets, over the bundled
    /// arena, for every Z-02 and Z-03 Camera subset: no waypoint in a solid,
    /// outside its zone, or in a trigger; every member walks its whole loop;
    /// no cone reaches the spawn or Z-01; and at every tick of the joint
    /// patrol cycle a walkable, uncovered route runs from the spawn into the
    /// M-A trigger.
    ///
    /// The members' joint state never repeats (separation couples them), so
    /// the proof checks a prefix of ticks: here the first 3,600 (one minute,
    /// about two laps of the longest loop and past every member's spawn
    /// transient), to keep the debug suite fast. `patrolEN030FullCap` checks
    /// 216,000 (an hour) on demand; SS-specs D-091 records both passing.
    @Test func patrolEN030FairnessHoldsAtEveryTickOfTheCycle() throws {
        let report = PatrolFairness.evaluate(try ArenaManifest.bundled(), content: .bundled(), tickCap: 3_600)
        #expect(report.waypointViolations.isEmpty, "\(report.waypointViolations)")
        #expect(report.unreachedWaypoints.isEmpty, "\(report.unreachedWaypoints)")
        #expect(report.unproven.isEmpty, "\(report.unproven)")
        #expect(report.protectedCoverage.isEmpty, "\(report.protectedCoverage)")
        #expect(report.blockedTicks.isEmpty, "\(report.blockedTicks)")
        #expect(report.cycles.count == 3, "one per legal Z-02 Camera pair")
        #expect(report.passes)
    }

    /// EN-030 over an hour of patrol (216,000 ticks). Opt-in, release:
    /// `SS_PATROL_FULL=1 swift test -c release -Xswiftc -enable-testing --filter patrolEN030FullCap`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SS_PATROL_FULL"] != nil))
    func patrolEN030FullCap() throws {
        let report = PatrolFairness.evaluate(try ArenaManifest.bundled(), content: .bundled(), tickCap: 216_000)
        #expect(report.passes, "\(report)")
        #expect(report.cycles.values.allSatisfy { $0[0] == 216_000 || $0[1] > 0 })
    }

    /// The proof is not inert: the spec's first-cut waypoints, which walk
    /// into Camera mounts and look into Z-01, fail it.
    @Test func fairnessProofRejectsTheFirstCutWaypoints() throws {
        var arena = try ArenaManifest.bundled()
        arena.patrols = [
            PatrolRoute(id: "p02-a", zoneId: "Z-02", archetype: .fogAnalyticsCloud, waypoints: [
                VecI(x: 480, y: 400), VecI(x: 760, y: 400), VecI(x: 760, y: 600), VecI(x: 480, y: 600)
            ]),
            PatrolRoute(id: "p02-b", zoneId: "Z-02", archetype: .autonomousInformant, waypoints: [
                VecI(x: 620, y: 240), VecI(x: 620, y: 380)
            ]),
            PatrolRoute(id: "p02-c", zoneId: "Z-02", archetype: .fogAnalyticsCloud, waypoints: [
                VecI(x: 760, y: 600), VecI(x: 480, y: 600), VecI(x: 480, y: 400), VecI(x: 760, y: 400)
            ]),
        ]
        let report = PatrolFairness.evaluate(arena, content: .bundled(), tickCap: 2_000)
        #expect(!report.passes)
        #expect(!report.unreachedWaypoints.isEmpty, "p02-b is pinned by cam-z02-b's mount")
        #expect(!report.protectedCoverage.isEmpty, "p02-a looks into Z-01")
    }

    // MARK: - Arena decoding

    /// `patrols` decodes strictly: missing or unknown keys, a non-integer
    /// coordinate, an unknown archetype, the elite, one waypoint, or a
    /// waypoint in a solid or trigger or outside its zone all fail closed.
    @Test func patrolsBlockFailsClosed() throws {
        let data = BundledResource.data(name: "civic-seam-arena-003", subdirectory: "contracts")
        let bundled = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func load(_ edit: (inout [[String: Any]]) -> Void, drop: Bool = false) -> Error? {
            var root = bundled
            if drop {
                root["patrols"] = nil
            } else {
                var list = root["patrols"] as! [[String: Any]]
                edit(&list)
                root["patrols"] = list
            }
            do {
                _ = try ArenaLoader.decodeAndValidate(try JSONSerialization.data(withJSONObject: root))
                return nil
            } catch {
                return error
            }
        }
        #expect(load({ _ in }) == nil)
        #expect(load({ _ in }, drop: true) as? ArenaValidationError == .schema)
        #expect(load { $0[0]["speed"] = 1 } as? ArenaValidationError == .schema)
        #expect(load { $0[0]["zoneId"] = nil } as? ArenaValidationError == .schema)
        #expect(load { $0[0]["archetype"] = "phantomCritic" } as? ArenaValidationError == .schema)
        #expect(load { $0[0]["waypoints"] = [["x": 600, "y": 500.5], ["x": 700, "y": 500]] } as? ArenaValidationError == .schema)
        #expect(load { $0[0]["waypoints"] = [["x": 600, "y": 500, "z": 0], ["x": 700, "y": 500]] } as? ArenaValidationError == .schema)
        let id = try #require(bundled["patrols"] as? [[String: Any]])[0]["id"] as! String
        #expect(load { $0[0]["archetype"] = "improperSearchDaemon" } as? ArenaValidationError == .patrol(id))
        #expect(load { $0[0]["waypoints"] = [["x": 600, "y": 500]] } as? ArenaValidationError == .patrol(id))
        #expect(load { $0[0]["zoneId"] = "Z-09" } as? ArenaValidationError == .patrol(id))
        // Inside solid-03-transit-kiosk; outside Z-02; inside trigger-M-A.
        for point in [["x": 576, "y": 704], ["x": 1500, "y": 300], ["x": 960, "y": 576]] {
            #expect(load { $0[0]["waypoints"] = [point, ["x": 700, "y": 500]] } as? ArenaValidationError == .patrol(id), "\(point)")
        }
        #expect(load { $0[1]["id"] = $0[0]["id"] } as? ArenaValidationError == .duplicateID(id))
    }

    // MARK: - EN-031 drift

    /// EN-031: an unaware M-A enemy 400 units from the trigger centre drifts
    /// toward it at 25% of its speed and stops within 48 units.
    @Test func encounterEN031UnawareEnemyDriftsToItsTriggerAndStops() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        let centre = sim.state.arena.encounterTriggers.first { $0.encounterId == "M-A" }!.center
        let start = VecI(x: centre.x - 400, y: centre.y)
        let id = sim.testing_spawnStandard(.fogAnalyticsCloud, at: start, awareness: .unaware, encounter: "M-A")
        let speed = PatrolSystem.scaledSpeedQ8(unitsPerSecond: 84, percent: 25)
        let stop = Int64(48) * Q8.scale
        var previous = start.asQ8
        var stoppedAt: UInt64?
        for _ in 0..<1_300 {
            sim.testing_setExposure(0)
            _ = Self.step(&sim)
            let enemy = try #require(sim.state.enemies.first { $0.id == id })
            #expect(enemy.awareness == .unaware)
            let moved = IntMath.isqrt(enemy.position.distanceSquared(to: previous))
            #expect(moved <= speed, "25% of 84 units per second")
            if moved > 0 {
                #expect(enemy.position.distanceSquared(to: centre.asQ8) < previous.distanceSquared(to: centre.asQ8))
            } else if stoppedAt == nil {
                stoppedAt = sim.state.tick
                #expect(enemy.position.distanceSquared(to: centre.asQ8) <= stop * stop)
            }
            previous = enemy.position
        }
        // 352 units at 21 units per second is about 1006 ticks.
        let tick = try #require(stoppedAt)
        #expect(tick > 950 && tick < 1_100, "\(tick)")
        let final = try #require(sim.state.enemies.first { $0.id == id })
        #expect(final.position.distanceSquared(to: centre.asQ8) <= stop * stop)
        #expect(final.position.distanceSquared(to: centre.asQ8) > Int64(40) * Q8.scale * Int64(40) * Q8.scale)
    }

    /// Only unaware encounter enemies drift: an aware one pursues instead,
    /// and one with no trigger (a test spawn) holds.
    @Test func driftNeedsAnEncounterTrigger() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        let id = sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 1500, y: 300), awareness: .unaware)
        for _ in 0..<60 { _ = Self.step(&sim) }
        #expect(sim.state.enemies.first { $0.id == id }?.position == VecI(x: 1500, y: 300).asQ8)
    }

    // MARK: - Damage taken (D-090)

    /// Over many hits of every size, exactly 50% lands: the Integrity removed
    /// is the running total's hundredths divided by 100, with nothing lost to
    /// rounding, and the remainder is always 0...99.
    @Test func damageRemainderIsExactOverManyHits() {
        var remainder = 0
        var removed = 0
        var total = 0
        var amount = 1
        for i in 0..<10_000 {
            amount = (amount * 37 + i) % 23 // 0...22, deterministic
            total += amount
            removed += Simulation.scaleDamageTaken(amount, percent: 50, remainder: &remainder)
            #expect(removed * 100 + remainder == total * 50)
            #expect((0...99).contains(remainder))
        }
        for percent in [0, 33, 50, 67, 100] {
            var carry = 0
            var sum = 0
            for _ in 0..<999 { sum += Simulation.scaleDamageTaken(7, percent: percent, remainder: &carry) }
            #expect(sum == 999 * 7 * percent / 100, "\(percent)")
            #expect(carry == 999 * 7 * percent % 100)
        }
    }

    /// Through the simulation: 1-damage contact ticks and bolts land half,
    /// and a 1-point loss that removes nothing publishes nothing.
    @Test func damageTakenAppliesToEveryLossInTheSimulation() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        sim.testing_fillCivicPool(count: Targeting.activeCeiling)
        sim.testing_injectHostileBolt(damage: 1)
        let first = Self.step(&sim)
        #expect(!first.events.contains { $0.type == .playerDamaged }, "0.5 removes no whole point")
        #expect(sim.state.player.integrity == 150)
        #expect(sim.state.player.damageRemainderHundredths == 50)
        sim.testing_injectHostileBolt(damage: 1)
        let second = Self.step(&sim)
        #expect(second.events.first { $0.type == .playerDamaged }?.payload["amount"] == .integer(1))
        #expect(sim.state.player.integrity == 149)
        #expect(sim.state.player.damageRemainderHundredths == 0)
        sim.testing_injectHostileBolt(damage: 9)
        _ = Self.step(&sim)
        #expect(sim.state.player.integrity == 145)
        #expect(sim.state.player.damageRemainderHundredths == 50)
        #expect(sim.state.player.damageTaken == 5, "receipts record Integrity actually removed")

        // Contact: an aware Vendor (10 DPS) on the Player for 60 ticks removes
        // 5, not 10.
        var contact = try Simulation.withoutPatrol(seed: 1)
        contact.testing_fillCivicPool(count: Targeting.activeCeiling)
        contact.testing_spawnStandard(.victorianVendor, at: VecI(x: 170, y: 192), speed: 0, nextSpecialTick: 10_000)
        for _ in 0..<60 { _ = Self.step(&contact) }
        #expect(contact.state.player.integrity == 145)
    }

    /// The remainder is authoritative, so it is in the state digest.
    @Test func damageRemainderIsDigested() throws {
        var a = try Simulation.withoutPatrol(seed: 1)
        var b = try Simulation.withoutPatrol(seed: 1)
        a.testing_injectHostileBolt(damage: 1)
        b.testing_injectHostileBolt(damage: 0)
        _ = Self.step(&a)
        _ = Self.step(&b)
        #expect(a.state.player.integrity == b.state.player.integrity)
        #expect(a.state.player.damageRemainderHundredths != b.state.player.damageRemainderHundredths)
        #expect(a.state.digest() != b.state.digest())
        #expect(StateDigest.canonical(a.state).serialize().contains("damageRemainderHundredths"))
    }

    /// The patrol state is authoritative, so it is in the digest.
    @Test func patrolStateIsDigested() throws {
        var a = try Simulation.make(seed: 1)
        _ = Self.step(&a)
        let serialized = StateDigest.canonical(a.state).serialize()
        #expect(serialized.contains("\"patrol\""))
        #expect(serialized.contains("dwellRemaining"))
    }
}
