import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct SpawnFairnessTests {
    @Test func encounterEN003EqualDistanceSelectsLowerSocketID() {
        let player = VecI(x: 0, y: 0).asQ8
        let sockets = [
            ArenaPoint(id: "eq-b", x: 100, y: 0, headingMilliDegrees: nil),
            ArenaPoint(id: "eq-a", x: 0, y: 100, headingMilliDegrees: nil),
            ArenaPoint(id: "eq-c", x: 80, y: 0, headingMilliDegrees: nil)
        ]
        let ranked = SpawnFairness.rank(sockets, player: player)
        let ids = ranked.compactMap(\.id)
        #expect(ids == ["eq-a", "eq-b", "eq-c"])
    }

    @Test func encounterEN003SelectsLowerIDAmongEqualValidSockets() throws {
        let arena = try ArenaManifest.bundled()
        let player = VecI(x: 576, y: 448)
        let sockets = [
            ArenaPoint(id: "eq-b", x: 776, y: 448, headingMilliDegrees: nil),
            ArenaPoint(id: "eq-a", x: 576, y: 248, headingMilliDegrees: nil)
        ]
        let chosen = SpawnFairness.select(
            sockets: sockets,
            player: player.asQ8,
            heading: VecQ8(unitsX: 1, unitsY: 0),
            archetypeRadius: 16,
            manifest: arena,
            closedGateIDs: []
        )
        let id = chosen?.id
        #expect(id == "eq-a")
    }

    @Test func encounterEN002ObstructedSocketsReturnNil() throws {
        let arena = try ArenaManifest.bundled()
        let sockets = arena.enemySpawnSockets["M-A"] ?? []
        let extras = sockets.map {
            AABB(center: VecI(x: $0.x, y: $0.y), halfSize: VecI(x: 48, y: 48))
        }
        let chosen = SpawnFairness.select(
            sockets: sockets,
            player: VecI(x: arena.playerSpawn.x, y: arena.playerSpawn.y).asQ8,
            heading: VecQ8(unitsX: 1, unitsY: 0),
            archetypeRadius: 16,
            manifest: arena,
            closedGateIDs: [],
            extraSolids: extras
        )
        #expect(chosen == nil)
    }

    @Test func encounterEN002RetryEveryThirtyTicksThenTimeout() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        sim.testing_obstructEncounterSockets("M-A")
        sim.testing_activateEncounter("M-A", spawnQueue: [.autonomousInformant])

        _ = sim.step(command: .neutral(tick: 1))
        let afterFirstEnemies = sim.state.enemies.count
        let afterFirstDefer = sim.state.encounters["M-A"]?.deferTicks ?? -1
        let afterFirstNext = sim.state.encounters["M-A"]?.nextSpawnTick ?? 0
        let afterFirstOutcome = sim.state.outcome
        #expect(afterFirstEnemies == 0)
        #expect(afterFirstDefer == SpawnFairness.retryIntervalTicks)
        #expect(afterFirstNext == UInt64(1 + SpawnFairness.retryIntervalTicks))
        #expect(afterFirstOutcome == .playing)

        for tick in 2...SpawnFairness.retryIntervalTicks {
            _ = sim.step(command: .neutral(tick: UInt64(tick)))
        }
        let beforeRetryEnemies = sim.state.enemies.count
        let beforeRetryDefer = sim.state.encounters["M-A"]?.deferTicks ?? -1
        #expect(beforeRetryEnemies == 0)
        #expect(beforeRetryDefer == SpawnFairness.retryIntervalTicks)

        _ = sim.step(command: .neutral(tick: UInt64(1 + SpawnFairness.retryIntervalTicks)))
        let afterRetryEnemies = sim.state.enemies.count
        let afterRetryDefer = sim.state.encounters["M-A"]?.deferTicks ?? -1
        #expect(afterRetryEnemies == 0)
        #expect(afterRetryDefer == SpawnFairness.retryIntervalTicks * 2)

        var tick = UInt64(1 + SpawnFairness.retryIntervalTicks + 1)
        var stillPlayingAtTwoSeventy = false
        while sim.state.outcome == .playing, tick <= 400 {
            _ = sim.step(command: .neutral(tick: tick))
            if tick == 271 {
                stillPlayingAtTwoSeventy = sim.state.outcome == .playing
            }
            tick += 1
        }
        let enemies = sim.state.enemies.count
        let outcome = sim.state.outcome
        let diagnostic = sim.state.diagnostic
        let deferTicks = sim.state.encounters["M-A"]?.deferTicks ?? -1
        let timeoutTick = sim.state.tick
        #expect(stillPlayingAtTwoSeventy)
        #expect(enemies == 0)
        #expect(outcome == .invalid)
        #expect(diagnostic == .spawnFairnessTimeout)
        #expect(deferTicks == SpawnFairness.timeoutTicks)
        #expect(timeoutTick == 301)
    }

    @Test func encounterEN003SimulationUsesLowerSocketID() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        sim.testing_setPlayerPosition(VecI(x: 576, y: 448))
        sim.testing_setEncounterSockets(
            "M-A",
            sockets: [
                ArenaPoint(id: "eq-b", x: 776, y: 448, headingMilliDegrees: nil),
                ArenaPoint(id: "eq-a", x: 576, y: 248, headingMilliDegrees: nil)
            ]
        )
        sim.testing_activateEncounter("M-A", spawnQueue: [.autonomousInformant])
        _ = sim.step(command: .neutral(tick: 1))
        let count = sim.state.enemies.count
        let x = sim.state.enemies.first.map { $0.position.x.unitsTruncated }
        let y = sim.state.enemies.first.map { $0.position.y.unitsTruncated }
        #expect(count == 1)
        #expect(x == 576)
        #expect(y == 248)
    }

    @Test func spawnFairnessPrefersOffscreenOverVisibleDelivery() throws {
        let arena = try ArenaManifest.bundled()
        let player = VecI(x: 576, y: 448)
        let sockets = [
            ArenaPoint(id: "near-on", x: 776, y: 448, headingMilliDegrees: nil),
            ArenaPoint(id: "far-off", x: 576, y: 800, headingMilliDegrees: nil)
        ]
        let chosen = SpawnFairness.select(
            sockets: sockets,
            player: player.asQ8,
            heading: VecQ8(unitsX: 1, unitsY: 0),
            archetypeRadius: 16,
            manifest: arena,
            closedGateIDs: []
        )
        let id = chosen?.id
        #expect(id == "far-off")
    }

    @Test func spawnFairnessMountSolidsRejectOverlappingVendor() throws {
        let arena = try ArenaManifest.bundled()
        let sockets = arena.enemySpawnSockets["M-B"] ?? []
        let mount = AABB(center: VecI(x: 1152, y: 864), halfSize: VecI(x: 12, y: 12))
        let vendor = SpawnFairness.select(
            sockets: sockets.filter { $0.id == "mb-08" },
            player: VecI(x: 1360, y: 1136).asQ8,
            heading: VecQ8(unitsX: 1, unitsY: 0),
            archetypeRadius: 22,
            manifest: arena,
            closedGateIDs: [],
            extraSolids: [mount]
        )
        let withoutMount = SpawnFairness.select(
            sockets: sockets.filter { $0.id == "mb-08" },
            player: VecI(x: 1360, y: 1136).asQ8,
            heading: VecQ8(unitsX: 1, unitsY: 0),
            archetypeRadius: 22,
            manifest: arena,
            closedGateIDs: []
        )
        let blocked = vendor?.id
        let open = withoutMount?.id
        #expect(blocked == nil)
        #expect(open == "mb-08")
    }

    @Test func spawnFairnessDocumentsPinnedSocketDefects() throws {
        let arena = try ArenaManifest.bundled()
        let content = CombatContent.bundled()
        let blocked = SpawnFairness.socketsBlockedByPermanentSolids(arena)
        let leaked = SpawnFairness.socketsOutsideEncounterZone(arena, content: content)
        // Pinned civic-seam-arena-004.json; do not rewrite coordinates.
        #expect(blocked == ["ma-02", "mb-02", "mc-08"])
        #expect(leaked == ["mb-01"])
    }

    @Test func spawnFairnessEscapeAperturesRemainOpenAtPeakDensity() throws {
        let arena = try ArenaManifest.bundled()
        let ma = ArenaReachability.escapeApertureOpen(arena, encounter: "M-A")
        let mb = ArenaReachability.escapeApertureOpen(arena, encounter: "M-B")
        let mc = ArenaReachability.escapeApertureOpen(arena, encounter: "M-C")
        let maFromSpawn = ArenaReachability.maEscapeOpen(arena)
        #expect(ma)
        #expect(mb)
        #expect(mc)
        #expect(maFromSpawn)
    }
}
