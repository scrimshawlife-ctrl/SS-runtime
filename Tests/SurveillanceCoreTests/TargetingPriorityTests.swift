import Testing
@testable import SurveillanceCore

/// `camera-destruction.md` § 6 automatic targeting after D-082: close enemy,
/// then the chosen Camera the Player is moving toward, then other enemy. No
/// other Camera is ever an automatic target.
@Suite(.serialized)
struct TargetingPriorityTests {
    /// Q8 velocity of a full-deflection command along +x (4 units per tick).
    private static let east = VecQ8(unitsX: 4, unitsY: 0)

    @Test func combatCB002EqualDistanceEnemiesPreferLowerID() {
        let player = PlayerBody(id: EntityID(1), spawn: VecI(x: 0, y: 0), integrity: 150)
        let a = enemy(id: 11, at: VecI(x: 64, y: 0))
        let b = enemy(id: 7, at: VecI(x: 0, y: 64))
        let chosen = Targeting.select(player: player, enemies: [a, b], cameras: [], solids: [])
        let id = chosen?.0.raw
        #expect(id == 7)
    }

    /// CD-011 under D-082: two chosen Cameras at equal distance, lower ID.
    @Test func cameraCD011EqualDistanceChosenCamerasPreferLowerID() {
        let player = moving(Self.east)
        let high = camera(id: 11, anchor: VecI(x: 64, y: 8), detecting: false)
        let low = camera(id: 7, anchor: VecI(x: 64, y: -8), detecting: false)
        let chosen = Targeting.select(player: player, enemies: [], cameras: [high, low], solids: [])
        let id = chosen?.0.raw
        #expect(id == 7)
    }

    /// CD-015: standing still, a detecting Camera in range is not a target.
    @Test func cameraCD015StandingPlayerChoosesNoCamera() {
        let player = PlayerBody(id: EntityID(1), spawn: VecI(x: 0, y: 0), integrity: 150)
        #expect(player.velocity == .zero)
        let detecting = camera(id: 5, anchor: VecI(x: 40, y: 0), detecting: true)
        let chosen = Targeting.select(player: player, enemies: [], cameras: [detecting], solids: [])
        #expect(chosen == nil)
    }

    /// CD-016: moving toward a Camera with no enemy within 96 targets it.
    @Test func cameraCD016MovingTowardACameraTargetsIt() {
        let player = moving(Self.east)
        let ahead = camera(id: 5, anchor: VecI(x: 300, y: 20), detecting: false)
        let chosen = Targeting.select(player: player, enemies: [], cameras: [ahead], solids: [])
        #expect(chosen?.0.raw == 5)
    }

    /// CD-017: moving 45 degrees away from the only Camera fires nothing.
    @Test func cameraCD017MovingFortyFiveDegreesAwayChoosesNothing() {
        let player = moving(VecQ8(unitsX: 3, unitsY: 3))
        let side = camera(id: 5, anchor: VecI(x: 200, y: 0), detecting: true)
        let chosen = Targeting.select(player: player, enemies: [], cameras: [side], solids: [])
        #expect(chosen == nil)
    }

    /// CD-018: a chosen Camera outranks an enemy beyond 96 units.
    @Test func cameraCD018ChosenCameraBeatsFarEnemy() {
        let player = moving(Self.east)
        let far = enemy(id: 20, at: VecI(x: 200, y: 0))
        let ahead = camera(id: 5, anchor: VecI(x: 400, y: 0), detecting: false)
        let chosen = Targeting.select(player: player, enemies: [far], cameras: [ahead], solids: [])
        #expect(chosen?.0.raw == 5)
    }

    @Test func targetingT409CloseEnemyBeatsChosenCamera() {
        let player = moving(Self.east)
        let close = enemy(id: 20, at: VecI(x: 80, y: 0))
        let ahead = camera(id: 5, anchor: VecI(x: 20, y: 0), detecting: true)
        let chosen = Targeting.select(player: player, enemies: [close], cameras: [ahead], solids: [])
        #expect(chosen?.0.raw == 20)
    }

    /// A Camera the Player is not moving toward is never a target, detecting
    /// or not, even with nothing else to shoot at.
    @Test func targetingD082UnchosenCameraIsNeverATarget() {
        let behind = moving(VecQ8(unitsX: -4, unitsY: 0))
        let far = enemy(id: 20, at: VecI(x: 200, y: 0))
        let detecting = camera(id: 5, anchor: VecI(x: 40, y: 0), detecting: true)
        let other = camera(id: 6, anchor: VecI(x: 60, y: 0), detecting: false)
        #expect(Targeting.select(player: behind, enemies: [far], cameras: [detecting, other], solids: [])?.0.raw == 20)
        #expect(Targeting.select(player: behind, enemies: [], cameras: [detecting, other], solids: []) == nil)
    }

    @Test func targetingT409InclusiveCloseRangeIsNinetySix() {
        let player = moving(Self.east)
        let atRange = enemy(id: 20, at: VecI(x: 96, y: 0))
        let ahead = camera(id: 5, anchor: VecI(x: 10, y: 0), detecting: true)
        let chosenClose = Targeting.select(player: player, enemies: [atRange], cameras: [ahead], solids: [])
        let beyond = enemy(id: 21, at: VecI(x: 97, y: 0))
        let chosenBeyond = Targeting.select(player: player, enemies: [beyond], cameras: [ahead], solids: [])
        #expect(chosenClose?.0.raw == 20)
        #expect(chosenBeyond?.0.raw == 5)
    }

    @Test func targetingT409DestroyedAndBlockedCamerasAreSkipped() {
        let player = moving(Self.east)
        let destroyed = camera(id: 5, anchor: VecI(x: 40, y: 0), detecting: true, integrity: 0)
        let blocked = camera(id: 6, anchor: VecI(x: 200, y: 0), detecting: true)
        let far = enemy(id: 20, at: VecI(x: 0, y: 180))
        let wall = [(id: "wall", box: AABB(center: VecI(x: 100, y: 0), halfSize: VecI(x: 8, y: 40)))]
        let chosen = Targeting.select(
            player: player,
            enemies: [far],
            cameras: [destroyed, blocked],
            solids: wall
        )
        #expect(chosen?.0.raw == 20)
    }

    /// The 30-degree integer test on either side of the boundary.
    @Test func targetingD082ThirtyDegreeBoundary() {
        let origin = VecI(x: 0, y: 0).asQ8
        let v = VecQ8(unitsX: 4, unitsY: 0)
        // atan(485 / 875) ≈ 29.0°; atan(515 / 857) ≈ 31.0°.
        #expect(Targeting.isChosen(velocity: v, from: origin, to: VecI(x: 875, y: 485).asQ8))
        #expect(Targeting.isChosen(velocity: v, from: origin, to: VecI(x: 875, y: -485).asQ8))
        #expect(!Targeting.isChosen(velocity: v, from: origin, to: VecI(x: 857, y: 515).asQ8))
        // Straight behind and exactly perpendicular: dot(v, d) ≤ 0.
        #expect(!Targeting.isChosen(velocity: v, from: origin, to: VecI(x: -100, y: 0).asQ8))
        #expect(!Targeting.isChosen(velocity: v, from: origin, to: VecI(x: 0, y: 100).asQ8))
        #expect(!Targeting.isChosen(velocity: .zero, from: origin, to: VecI(x: 100, y: 0).asQ8))
    }

    /// Both sides of the inequality exceed 64 bits at arena scale with a
    /// Dodge-speed velocity; the comparison is exact and does not trap.
    @Test func targetingD082IntegerTestIsOverflowSafe() {
        let dodge = VecQ8(unitsX: 9, unitsY: 0)
        let origin = VecI(x: 0, y: 0).asQ8
        let farAhead = VecI(x: 60_000, y: 34_000).asQ8 // ≈ 29.5°
        let farWide = VecI(x: 60_000, y: 35_000).asQ8 // ≈ 30.3°
        #expect(Targeting.isChosen(velocity: dodge, from: origin, to: farAhead))
        #expect(!Targeting.isChosen(velocity: dodge, from: origin, to: farWide))
    }

    /// CD-015 and CD-016 through the whole tick: standing in a Camera's field
    /// at the first attack opportunity fires nothing; walking at the same
    /// Camera fires at it.
    @Test(arguments: [false, true])
    func cameraCD015CD016ThroughTheSimulation(movingToward: Bool) throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        func start(_ camera: SelectedCamera) -> VecI {
            let unit = Cordic.headingUnit(milliDegrees: camera.headingMilliDegrees)
            return VecI(
                x: camera.position.x + Int(unit.x) * 160 / Int(Cordic.q15),
                y: camera.position.y + Int(unit.y) * 160 / Int(Cordic.q15)
            )
        }
        // An off-diagonal socket, where no mount is in the way at all;
        // CD-019 covers the diagonal sockets, whose own mount would block
        // without D-085.
        let index = try #require(sim.state.cameras.indices.first { i in
            let camera = sim.state.cameras[i]
            return Collision.lineOfFireClear(
                from: start(camera).asQ8, to: camera.targetAnchor, solids: sim.state.liveSolids
            )
        })
        sim.testing_keepOnlyCamera(at: index, integrity: 3)
        let camera = sim.state.cameras[index]
        sim.testing_setPlayerPosition(start(camera))
        var fired: [AuthoritativeEvent] = []
        for tick in 1...Targeting.firstOpportunity {
            let anchor = sim.state.cameras[index].targetAnchor
            let dx = anchor.x.raw - sim.state.player.position.x.raw
            let dy = anchor.y.raw - sim.state.player.position.y.raw
            let scale = Double(PlayerCommand.axisMaximum) / max(1, (Double(dx * dx + dy * dy)).squareRoot())
            let command = movingToward
                ? PlayerCommand(tick: tick, moveX: Int16(Double(dx) * scale), moveY: Int16(Double(dy) * scale), dodgePressed: false)
                : .neutral(tick: tick)
            fired += sim.step(command: command).events.filter { $0.type == .weaponFired }
        }
        #expect(sim.state.cameras[index].wasDetecting || movingToward, "precondition: the standing Player is in the field")
        if movingToward {
            #expect(fired.count == 1)
            #expect(fired.first?.secondaryEntityId == camera.entityId)
        } else {
            #expect(fired.isEmpty)
        }
    }
}

extension TargetingPriorityTests {
    /// CD-019 through the whole simulation, on a real diagonal socket: its
    /// anchor lies inside its own mount box, which would block every shot
    /// without D-085. Walking at it targets it, and three hits destroy it.
    @Test func cameraCD019DiagonalSocketIsTargetedAndDestroyed() throws {
        var sim = try Simulation.withoutPatrol(seed: 1)
        let index = try #require(sim.state.cameras.indices.first {
            sim.state.cameras[$0].headingMilliDegrees % 90_000 == 45_000
        }, "seed 1 selects a diagonal socket")
        let camera = sim.state.cameras[index]
        sim.testing_keepOnlyCamera(at: index, integrity: 3)
        let unit = Cordic.headingUnit(milliDegrees: camera.headingMilliDegrees)
        let start = VecI(
            x: camera.position.x + Int(unit.x) * 160 / Int(Cordic.q15),
            y: camera.position.y + Int(unit.y) * 160 / Int(Cordic.q15)
        )
        sim.testing_setPlayerPosition(start)
        // The precondition the vector is about: the own mount is in the way.
        #expect(!Collision.lineOfFireClear(from: start.asQ8, to: camera.targetAnchor, solids: sim.state.liveSolids))
        #expect(Targeting.lineOfFireClear(from: start.asQ8, to: camera, solids: sim.state.liveSolids))

        var shotsAtCamera = 0
        var destroyedEvents = 0
        for _ in 0..<(Targeting.firstOpportunity + UInt64(Targeting.cadence) * 3) {
            let tick = sim.state.tick + 1
            let anchor = camera.targetAnchor
            let dx = anchor.x.raw - sim.state.player.position.x.raw
            let dy = anchor.y.raw - sim.state.player.position.y.raw
            let scale = Double(PlayerCommand.axisMaximum) / max(1, (Double(dx * dx + dy * dy)).squareRoot())
            let events = sim.step(command: PlayerCommand(
                tick: tick, moveX: Int16(Double(dx) * scale), moveY: Int16(Double(dy) * scale), dodgePressed: false
            )).events
            shotsAtCamera += events.filter { $0.type == .weaponFired && $0.secondaryEntityId == camera.entityId }.count
            destroyedEvents += events.filter { $0.type == .cameraDestroyed }.count
        }
        #expect(shotsAtCamera >= 3)
        #expect(sim.state.cameras[index].integrity == 0)
        #expect(destroyedEvents == 1)
        #expect(sim.state.destructions.map(\.cameraId) == [camera.entityId])
    }

    /// CD-020: a shot at Camera B that passes through Camera A's mount is
    /// blocked; B's own mount (its anchor sits inside it) never is.
    @Test func cameraCD020AnotherCamerasMountBlocks() {
        let player = moving(Self.east)
        var b = camera(id: 8, anchor: VecI(x: 190, y: 0), detecting: false)
        b.position = VecI(x: 200, y: 0)
        let a = camera(id: 7, anchor: VecI(x: 90, y: 40), detecting: false)
        let bMount = (id: b.mountSolidId, box: AABB(center: b.position, halfSize: VecI(x: 12, y: 12)))
        let aMount = (id: a.mountSolidId, box: AABB(center: VecI(x: 100, y: 0), halfSize: VecI(x: 12, y: 12)))
        // Only B's own mount on the line: B is targeted.
        #expect(Targeting.select(player: player, enemies: [], cameras: [b], solids: [bMount])?.0.raw == 8)
        // A's mount also on the line: blocked.
        #expect(Targeting.select(player: player, enemies: [], cameras: [b], solids: [bMount, aMount]) == nil)
        #expect(!Targeting.lineOfFireClear(from: player.position, to: b, solids: [bMount, aMount]))
    }
}

private func moving(_ velocity: VecQ8) -> PlayerBody {
    var player = PlayerBody(id: EntityID(1), spawn: VecI(x: 0, y: 0), integrity: 150)
    player.velocity = velocity
    return player
}

private func enemy(id: UInt64, at position: VecI) -> EnemyBody {
    EnemyBody(
        id: EntityID(id),
        archetype: .autonomousInformant,
        position: position.asQ8,
        velocity: .zero,
        integrity: 20,
        radius: 16,
        speedUnitsPerSecond: 0,
        contactDps: 0,
        state: .pursue,
        stateTicks: 0,
        spawnTick: 0,
        nextSpecialTick: 0,
        lockPosition: nil,
        encounterId: "test"
    )
}

private func camera(id: UInt64, anchor: VecI, detecting: Bool, integrity: Int = 3) -> SelectedCamera {
    let q = anchor.asQ8
    return SelectedCamera(
        socketId: "test-\(id)",
        entityId: EntityID(id),
        housingFamily: .municipalDome,
        zoneId: "Z-03",
        position: anchor,
        headingMilliDegrees: 0,
        rangeUnits: 300,
        fieldAngleMilliDegrees: 60_000,
        tutorialEligible: false,
        returnVisible: true,
        integrity: integrity,
        mountCollisionRadius: 12,
        hitRadius: 16,
        fieldOrigin: q,
        targetAnchor: q,
        wasDetecting: detecting,
        incompatibleSocketIds: []
    )
}
