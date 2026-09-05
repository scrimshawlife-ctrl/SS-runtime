public struct Simulation: Equatable, Sendable {
    public private(set) var state: WorldState
    private var events = EventBuffer()

    public init(seed: UInt64, arena: ArenaManifest, content: CombatContent) throws {
        var allocator = EntityAllocator()
        let playerID = allocator.next()
        guard let cameras = CameraPlacement.select(
            sockets: arena.cameraSockets,
            geometry: arena.standardCameraGeometry,
            runSeed: seed,
            allocator: &allocator
        ), CameraPlacement.selectedSetPassesRuntimeAsserts(cameras) else {
            throw ArenaValidationError.cameraPlacement
        }
        var encounters: [String: EncounterRuntime] = [:]
        for id in EncounterDirector.encounterOrder {
            encounters[id] = EncounterRuntime(
                id: id,
                activated: false,
                completed: false,
                waveIndex: 0,
                spawnQueue: [],
                nextSpawnTick: 0,
                deferTicks: 0,
                living: 0,
                spawned: 0,
                cleanupTick: nil
            )
        }
        let gates = arena.gates.map {
            GateState(id: $0.id, closed: $0.initiallyClosed ?? false, box: $0.aabb)
        }
        state = WorldState(
            identity: .current,
            seed: seed,
            clock: SimulationClock(),
            combatRng: .combat(runSeed: seed),
            allocator: allocator,
            outcome: .playing,
            failureReason: nil,
            diagnostic: nil,
            terminalTick: nil,
            terminalDigest: nil,
            player: PlayerBody(
                id: playerID,
                spawn: VecI(x: arena.playerSpawn.x, y: arena.playerSpawn.y)
            ),
            cameras: cameras,
            enemies: [],
            projectiles: [],
            mines: [],
            exposure: ExposureState(),
            upgrade: UpgradeState(),
            extraction: ExtractionState(remaining: arena.extraction.countdownTicks),
            encounters: encounters,
            gates: gates,
            eliteDefeated: false,
            bossDefeated: false,
            bossPhase: nil,
            phasesReached: [],
            combat: CombatTotals(),
            destructions: [],
            lastPulseTick: 0,
            networkBlackout: false,
            arena: arena,
            content: content,
            tutorial: TutorialState(),
            bossRuntime: nil,
            handedness: .right,
            civicPool: ProjectilePool(),
            eliteGateOpenTick: nil
        )
        events.emit(
            tick: 0,
            phase: 18,
            type: .runStarted,
            payload: ["seed": .unsigned(seed)]
        )
        _ = events.publish()
    }

    public static func make(seed: UInt64) throws -> Simulation {
        try Simulation(seed: seed, arena: ArenaManifest.bundled(), content: .bundled())
    }

    public mutating func restart() {
        self = try! Simulation(seed: state.seed, arena: state.arena, content: state.content)
    }

    public var isTerminal: Bool {
        switch state.outcome {
        case .success, .failure, .invalid: true
        default: false
        }
    }

    @discardableResult
    public mutating func step(command incoming: PlayerCommand?) -> TickResult {
        if isTerminal {
            return TickResult(tick: state.tick, events: [], digest: state.digest(), outcome: state.outcome)
        }

        if state.upgrade.pending {
            guard let command = incoming,
                  let index = command.upgradeChoiceIndex,
                  UpgradeID.from(index: index) != nil,
                  command.moveX == 0,
                  command.moveY == 0,
                  command.dodgePressed == false
            else {
                return TickResult(tick: state.tick, events: [], digest: state.digest(), outcome: .upgradeSelectionPending)
            }
            applyUpgrade(index)
        }

        state.clock.advance()
        let tick = state.tick
        let command: PlayerCommand
        if let incoming {
            if incoming.tick != tick {
                invalidate(.lateOrFutureCommand)
                return finishTick()
            }
            command = incoming
        } else {
            command = .neutral(tick: tick)
        }

        if state.upgrade.pending {
            return TickResult(tick: state.tick, events: [], digest: state.digest(), outcome: .upgradeSelectionPending)
        }

        let previousPosition = state.player.position
        Movement.apply(
            player: &state.player,
            command: command,
            tick: tick,
            ghostStep: state.upgrade.ghostStep,
            bounds: state.arena.boundsUnits.aabb,
            solids: state.liveSolids,
            events: &events
        )
        let displacement = IsolatedKernel.distanceUnits(previousPosition, state.player.position)
        state.player.movedUnitsLastTick = displacement
        state.tutorial.noteDisplacement(displacement)

        var fogPulses: [Int] = []
        var enemyPlayerDamage: [(EntityID, Int)] = []
        EnemySystem.step(
            enemies: &state.enemies,
            player: state.player,
            tick: tick,
            content: state.content,
            bounds: state.arena.boundsUnits.aabb,
            solids: state.liveSolids,
            allocator: &state.allocator,
            projectiles: &state.projectiles,
            mines: &state.mines,
            exposurePulses: &fogPulses,
            playerDamage: &enemyPlayerDamage
        )
        for (source, amount) in enemyPlayerDamage {
            applyPlayerDamage(source, amount: amount, tick: tick)
        }
        var observationPulses: [Int] = []
        if var runtime = state.bossRuntime,
           let index = state.enemies.firstIndex(where: { $0.archetype == .algorithmicModerate && $0.alive })
        {
            var pulse: Int?
            var playerDamage = 0
            BossSystem.step(
                boss: &state.enemies[index],
                runtime: &runtime,
                player: state.player,
                tick: tick,
                emitters: state.arena.captainCameraEmitters,
                solids: state.liveSolids,
                allocator: &state.allocator,
                projectiles: &state.projectiles,
                exposurePulse: &pulse,
                playerDamage: &playerDamage,
                events: &events,
                baseSpeed: state.content.bossSpeed,
                baseContact: state.content.bossContactDps
            )
            state.bossRuntime = runtime
            state.bossPhase = runtime.phase.rawValue
            if !state.phasesReached.contains(runtime.phase.rawValue) {
                state.phasesReached.append(runtime.phase.rawValue)
            }
            if let pulse {
                observationPulses.append(
                    BossSystem.observationAmount(
                        base: pulse,
                        numerator: runtime.observationNumerator,
                        signalJammer: state.upgrade.signalJammer
                    )
                )
            }
            if playerDamage > 0 {
                applyPlayerDamage(state.enemies[index].id, amount: playerDamage, tick: tick)
            }
        }

        let contacts = Detection.sampleContacts(
            cameras: &state.cameras,
            player: state.player,
            tick: tick,
            solids: state.liveSolids
        )
        state.tutorial.noteContact(!contacts.isEmpty)
        state.tutorial.lockdownPreempts = state.exposure.lockdownEntered && state.tutorial.phase != .complete
        let view = PresentationCamera.follow(
            player: VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated),
            heading: state.player.facing,
            bounds: state.arena.boundsUnits
        )
        let viewBox = AABB(
            center: view.center,
            halfSize: VecI(x: PresentationCamera.visibleWidth / 2, y: PresentationCamera.visibleHeight / 2)
        )
        if state.cameras.contains(where: { viewBox.contains($0.position) }) {
            state.tutorial.noteCameraInViewport()
        }

        fireCivicPulseIfNeeded(tick: tick)

        moveProjectilesAndCollectHits(tick: tick)

        let destroyedThisTick = resolveDamage(tick: tick)
        let survivingContacts = contacts.filter { id in
            !destroyedThisTick.contains(id) && state.cameras.contains { $0.entityId == id && $0.isDamageable }
        }

        resolvePlayerDeathAndContact(tick: tick)

        var forceLockdown = false
        if state.outcome != .failure {
            advanceEncounters(tick: tick, forceLockdown: &forceLockdown)
        }

        // T410 / camera-destruction-001 §9: surviving contacts, then ordered Tamper, even on the death tick.
        let tamper = state.destructions.filter { $0.tick == tick }.sorted { $0.cameraId < $1.cameraId }.map { _ in 100 }
        let resolution = state.exposure.resolveTick(
            survivingContactCount: survivingContacts.count,
            tamperAmounts: tamper,
            signalJammer: state.upgrade.signalJammer,
            forceLockdown: forceLockdown
        )
        emitExposure(resolution, tick: tick)

        if state.outcome == .failure {
            return finishTick()
        }

        applyNamedPulses(fogPulses, reason: .fogPulse, tick: tick)
        applyNamedPulses(observationPulses, reason: .observationPulse, tick: tick)
        openEliteGateIfDue(tick: tick)

        resolveObjectives(tick: tick)
        resolveExtraction(tick: tick)
        return finishTick()
    }

    public mutating func run(commands: [PlayerCommand], untilTick: UInt64? = nil) -> TickResult {
        var last = TickResult(tick: 0, events: [], digest: state.digest(), outcome: state.outcome)
        var index = 0
        let limit = untilTick ?? (commands.last?.tick ?? 0)
        while !isTerminal && state.tick < limit {
            let nextTick = state.tick + 1
            var command: PlayerCommand?
            if index < commands.count, commands[index].tick == nextTick {
                command = commands[index]
                index += 1
            }
            last = step(command: command)
        }
        return last
    }

    public static func execute(_ envelope: ReplayEnvelope) -> Result<TickResult, ReplayLoadError> {
        switch envelope.identity.compatibility() {
        case .compatible:
            break
        case .incompatible(let expected, let received):
            return .failure(.incompatibleIdentity(expected: expected, received: received))
        }
        do {
            var sim = try Simulation.make(seed: envelope.seed)
            let last = sim.run(commands: envelope.commands, untilTick: envelope.commands.last?.tick)
            if let expected = envelope.expectedFinalDigest, expected != last.digest {
                return .success(
                    TickResult(
                        tick: last.tick,
                        events: last.events,
                        digest: last.digest,
                        outcome: .invalid
                    )
                )
            }
            return .success(last)
        } catch {
            return .failure(.invalidJSON)
        }
    }

    private mutating func applyUpgrade(_ index: UInt8) {
        guard let upgrade = UpgradeID.from(index: index) else { return }
        state.upgrade.selected = upgrade
        state.upgrade.pending = false
        state.outcome = .playing
        state.tutorial.noteUpgradeSelected()
        events.emit(
            tick: state.tick,
            phase: 2,
            type: .upgradeSelected,
            payload: [
                "upgradeId": .string(upgrade.rawValue),
                "selectionIndex": .integer(Int64(index))
            ]
        )
    }

    private mutating func fireCivicPulseIfNeeded(tick: UInt64) {
        guard tick >= Targeting.firstOpportunity, tick % UInt64(Targeting.cadence) == 0 else { return }
        guard state.civicPool.liveCount < Targeting.activeCeiling else { return }
        guard let target = Targeting.select(
            player: state.player,
            enemies: state.enemies,
            cameras: state.cameras,
            solids: state.liveSolids
        ) else { return }

        if state.cameras.contains(where: { $0.entityId == target.0 && $0.isDamageable }) {
            state.tutorial.noteCameraTargetable()
        }

        let targetVelocity: VecQ8
        if let enemy = state.enemies.first(where: { $0.id == target.0 }) {
            targetVelocity = enemy.velocity
        } else {
            targetVelocity = .zero
        }
        let velocity = Targeting.aimVelocity(from: state.player.position, to: target.1, targetVelocity: targetVelocity)
        let id = state.allocator.next()
        let projectile = ProjectileBody(
            id: id,
            ownerId: state.player.id,
            kind: .civicPulse,
            position: state.player.position + velocity,
            previous: state.player.position,
            velocity: velocity,
            radius: Targeting.projectileRadius,
            damage: Targeting.enemyDamage,
            cameraDamage: Targeting.cameraDamage,
            age: 1,
            lifetime: Targeting.projectileLifetime,
            distanceTravelledQ8: IntMath.isqrt(velocity.lengthSquaredRaw),
            maxTravelQ8: Int64(Targeting.maxTravel) * Q8.scale,
            hitEntityIds: [],
            alive: true
        )
        guard state.civicPool.checkout(projectile) else { return }
        state.projectiles.append(projectile)
        events.emit(
            tick: tick,
            phase: 7,
            type: .weaponFired,
            primary: id,
            secondary: target.0,
            payload: [
                "weaponId": .string("civicPulse"),
                "targetEntityId": .string(target.0.decimalString)
            ]
        )
        state.lastPulseTick = tick
    }

    private mutating func moveProjectilesAndCollectHits(tick: UInt64) {
        for i in state.projectiles.indices where state.projectiles[i].alive {
            if state.projectiles[i].age > 1 {
                state.projectiles[i].previous = state.projectiles[i].position
                state.projectiles[i].position = state.projectiles[i].position + state.projectiles[i].velocity
                state.projectiles[i].distanceTravelledQ8 += IntMath.isqrt(state.projectiles[i].velocity.lengthSquaredRaw)
            }
            state.projectiles[i].age += 1
            let pos = state.projectiles[i].position
            if pos.x.raw < 0 || pos.y.raw < 0
                || pos.x.raw > Int64(state.arena.boundsUnits.maxX) * Q8.scale
                || pos.y.raw > Int64(state.arena.boundsUnits.maxY) * Q8.scale
                || state.projectiles[i].age > state.projectiles[i].lifetime
                || state.projectiles[i].distanceTravelledQ8 > state.projectiles[i].maxTravelQ8
            {
                retireProjectile(at: i)
            }
        }
        _ = tick
    }

    private mutating func resolveDamage(tick: UInt64) -> Set<EntityID> {
        struct Hit: Equatable {
            var t: Int64
            var target: EntityID
            var projectile: EntityID
            var isCamera: Bool
            var isWall: Bool
            var index: Int
        }
        var hits: [Hit] = []
        for (pIndex, projectile) in state.projectiles.enumerated() where projectile.alive {
            var wallT: Int64?
            for solid in state.liveSolids {
                if Collision.segmentIntersects(projectile.previous, projectile.position, box: solid.box) {
                    wallT = 0
                }
            }
            if let wallT {
                hits.append(Hit(t: wallT, target: EntityID(0), projectile: projectile.id, isCamera: false, isWall: true, index: pIndex))
            }
            if projectile.kind == .civicPulse || projectile.kind == .ricochet {
                for enemy in state.enemies where enemy.alive && !projectile.hitEntityIds.contains(enemy.id) {
                    if let t = Collision.sweepCircleTime(
                        from: projectile.previous,
                        to: projectile.position,
                        radius: projectile.radius,
                        target: enemy.position,
                        targetRadius: enemy.radius
                    ) {
                        hits.append(Hit(t: t, target: enemy.id, projectile: projectile.id, isCamera: false, isWall: false, index: pIndex))
                    }
                }
                for camera in state.cameras where camera.isDamageable && !projectile.hitEntityIds.contains(camera.entityId) {
                    if let t = Collision.sweepCircleTime(
                        from: projectile.previous,
                        to: projectile.position,
                        radius: projectile.radius,
                        target: camera.targetAnchor,
                        targetRadius: camera.hitRadius
                    ) {
                        hits.append(Hit(t: t, target: camera.entityId, projectile: projectile.id, isCamera: true, isWall: false, index: pIndex))
                    }
                }
            } else if projectile.kind == .sutroBolt || projectile.kind == .bossBolt {
                if let t = Collision.sweepCircleTime(
                    from: projectile.previous,
                    to: projectile.position,
                    radius: projectile.radius,
                    target: state.player.position,
                    targetRadius: PlayerBody.radiusUnits
                ) {
                    hits.append(Hit(t: t, target: state.player.id, projectile: projectile.id, isCamera: false, isWall: false, index: pIndex))
                }
            }
        }

        hits.sort {
            if $0.t != $1.t { return $0.t < $1.t }
            if $0.isWall != $1.isWall { return $0.isWall && !$1.isWall }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.projectile < $1.projectile
        }

        var consumed = Set<EntityID>()
        var destroyed = Set<EntityID>()
        var ricochetFrom: [(ProjectileBody, VecQ8, EntityID)] = []

        for hit in hits {
            guard state.projectiles[hit.index].alive, !consumed.contains(hit.projectile) else { continue }
            if hit.isWall {
                retireProjectile(at: hit.index)
                consumed.insert(hit.projectile)
                continue
            }
            if hit.target == state.player.id {
                applyPlayerDamage(hit.projectile, amount: state.projectiles[hit.index].damage, tick: tick)
                retireProjectile(at: hit.index)
                consumed.insert(hit.projectile)
                continue
            }
            if let eIndex = state.enemies.firstIndex(where: { $0.id == hit.target }) {
                guard state.enemies[eIndex].alive else { continue }
                let amount = min(state.projectiles[hit.index].damage, state.enemies[eIndex].integrity)
                state.enemies[eIndex].integrity -= amount
                state.combat.damageDealt += amount
                events.emit(
                    tick: tick,
                    phase: 9,
                    type: .projectileHit,
                    primary: hit.projectile,
                    secondary: hit.target,
                    payload: [
                        "projectileId": .string(hit.projectile.decimalString),
                        "targetEntityId": .string(hit.target.decimalString),
                        "appliedDamage": .integer(Int64(amount))
                    ]
                )
                events.emit(
                    tick: tick,
                    phase: 9,
                    type: .entityDamaged,
                    primary: hit.target,
                    payload: [
                        "entityId": .string(hit.target.decimalString),
                        "amount": .integer(Int64(amount)),
                        "remainingIntegrity": .integer(Int64(state.enemies[eIndex].integrity))
                    ]
                )
                state.projectiles[hit.index].hitEntityIds.append(hit.target)
                if state.enemies[eIndex].integrity <= 0 {
                    killEnemy(at: eIndex, tick: tick)
                }
                if state.upgrade.ricochetPulse && state.projectiles[hit.index].kind == .civicPulse {
                    ricochetFrom.append((state.projectiles[hit.index], state.enemies[eIndex].position, hit.target))
                    consumed.insert(hit.projectile)
                    continue
                }
                retireProjectile(at: hit.index)
                consumed.insert(hit.projectile)
                continue
            }
            if let cIndex = state.cameras.firstIndex(where: { $0.entityId == hit.target }) {
                guard state.cameras[cIndex].isDamageable else {
                    retireProjectile(at: hit.index)
                    consumed.insert(hit.projectile)
                    continue
                }
                let before = state.cameras[cIndex].integrity
                state.cameras[cIndex].integrity -= 1
                state.tutorial.noteCameraImpact()
                events.emit(
                    tick: tick,
                    phase: 9,
                    type: .cameraIntegrityChanged,
                    primary: hit.target,
                    payload: [
                        "cameraId": .string(hit.target.decimalString),
                        "before": .integer(Int64(before)),
                        "after": .integer(Int64(state.cameras[cIndex].integrity))
                    ]
                )
                events.emit(
                    tick: tick,
                    phase: 9,
                    type: .projectileHit,
                    primary: hit.projectile,
                    secondary: hit.target,
                    payload: [
                        "projectileId": .string(hit.projectile.decimalString),
                        "targetEntityId": .string(hit.target.decimalString),
                        "appliedDamage": .integer(1)
                    ]
                )
                // camera-destruction.md §7 / upgrades.md: one projectile damages a Camera at most once.
                state.projectiles[hit.index].hitEntityIds.append(hit.target)
                if state.cameras[cIndex].integrity == 0 {
                    destroyed.insert(hit.target)
                    destroyCamera(
                        at: cIndex,
                        projectileKind: state.projectiles[hit.index].kind,
                        projectile: hit.projectile,
                        tick: tick
                    )
                }
                if state.upgrade.ricochetPulse && state.projectiles[hit.index].kind == .civicPulse {
                    ricochetFrom.append((state.projectiles[hit.index], state.cameras[cIndex].targetAnchor, hit.target))
                    consumed.insert(hit.projectile)
                    continue
                }
                retireProjectile(at: hit.index)
                consumed.insert(hit.projectile)
            }
        }

        for (source, origin, excluded) in ricochetFrom {
            spawnRicochet(from: source, origin: origin, excluding: excluded, tick: tick)
        }
        // upgrades.md: continuation resolves after the first hit in the same damage phase.
        if !ricochetFrom.isEmpty {
            destroyed.formUnion(resolveDamage(tick: tick))
        }
        return destroyed
    }

    private mutating func spawnRicochet(from source: ProjectileBody, origin: VecQ8, excluding: EntityID, tick: UInt64) {
        let solids = state.liveSolids
        guard let next = Targeting.ricochetTarget(
            origin: origin,
            excluding: excluding,
            enemies: state.enemies,
            cameras: state.cameras,
            solids: solids
        ) else {
            if let index = state.projectiles.firstIndex(where: { $0.id == source.id }) {
                retireProjectile(at: index)
            }
            return
        }
        var hitEntityIds = source.hitEntityIds
        if !hitEntityIds.contains(excluding) {
            hitEntityIds.append(excluding)
        }
        let range = Int64(Targeting.ricochetRange) * Q8.scale
        let velocity = Targeting.direct(from: origin, to: next.1, speed: Int64(Targeting.projectileSpeedPerTick) * Q8.scale)
        let ricochet = ProjectileBody(
            id: source.id,
            ownerId: source.ownerId,
            kind: .ricochet,
            position: next.1,
            previous: origin,
            velocity: velocity,
            radius: source.radius,
            damage: source.damage,
            cameraDamage: source.cameraDamage,
            age: 1,
            lifetime: Targeting.projectileLifetime,
            distanceTravelledQ8: 0,
            maxTravelQ8: range,
            hitEntityIds: hitEntityIds,
            alive: true
        )
        if let index = state.projectiles.firstIndex(where: { $0.id == source.id }) {
            state.projectiles[index] = ricochet
            state.civicPool.replace(id: source.id, with: ricochet)
        } else if state.civicPool.checkout(ricochet) {
            state.projectiles.append(ricochet)
        }
        _ = tick
    }

    private mutating func retireProjectile(at index: Int) {
        guard state.projectiles.indices.contains(index), state.projectiles[index].alive else { return }
        let projectile = state.projectiles[index]
        state.projectiles[index].alive = false
        if projectile.kind == .civicPulse || projectile.kind == .ricochet {
            state.civicPool.release(id: projectile.id)
        }
    }

    private mutating func destroyCamera(
        at index: Int,
        projectileKind: ProjectileKind,
        projectile: EntityID,
        tick: UInt64
    ) {
        let camera = state.cameras[index]
        let before = state.exposure.exposure
        let source = projectileKind == .ricochet ? "ricochet" : "baseProjectile"
        events.emit(
            tick: tick,
            phase: 10,
            type: .cameraDestroyed,
            primary: camera.entityId,
            payload: [
                "cameraId": .string(camera.entityId.decimalString),
                "socketId": .string(camera.socketId),
                "projectileId": .string(projectile.decimalString),
                "wasDetecting": .bool(camera.wasDetecting)
            ]
        )
        state.destructions.append(
            CameraDestructionRecord(
                cameraId: camera.entityId,
                tick: tick,
                housingFamily: camera.housingFamily,
                wasDetectingPlayer: camera.wasDetecting,
                source: source,
                exposureBefore: before,
                exposureAfter: min(1000, before + 100),
                triggeredLockdown: before + 100 >= 1000 && !state.exposure.lockdownEntered
            )
        )
        if state.destructions.count == 8 && !state.networkBlackout {
            state.networkBlackout = true
            events.emit(
                tick: tick,
                phase: 10,
                type: .allCamerasDestroyed,
                payload: ["destroyedCount": .integer(8), "totalCount": .integer(8)]
            )
        }
    }

    private mutating func killEnemy(at index: Int, tick: UInt64) {
        let enemy = state.enemies[index]
        events.emit(
            tick: tick,
            phase: 10,
            type: .entityDied,
            primary: enemy.id,
            payload: [
                "entityId": .string(enemy.id.decimalString),
                "archetypeId": .string(enemy.archetype.rawValue)
            ]
        )
        state.combat.defeatsByArchetype[enemy.archetype.rawValue, default: 0] += 1
        if let encounter = state.encounters[enemy.encounterId] {
            var updated = encounter
            updated.living = max(0, updated.living - 1)
            state.encounters[enemy.encounterId] = updated
        }
        if enemy.archetype == .improperSearchDaemon {
            state.eliteDefeated = true
            state.eliteGateOpenTick = tick + 60
            events.emit(
                tick: tick,
                phase: 16,
                type: .eliteDefeated,
                payload: ["eliteId": .string(enemy.archetype.rawValue)]
            )
        }
        if enemy.archetype == .algorithmicModerate {
            state.bossDefeated = true
            state.bossRuntime?.retireField()
            BossSystem.retireBossProjectiles(&state.projectiles)
            events.emit(
                tick: tick,
                phase: 16,
                type: .bossDefeated,
                payload: ["bossId": .string(enemy.archetype.rawValue)]
            )
            if let gate = state.gates.firstIndex(where: { $0.id == "gate-boss-extraction" }) {
                state.gates[gate].closed = false
            }
        }
    }

    private mutating func openEliteGateIfDue(tick: UInt64) {
        guard let openTick = state.eliteGateOpenTick, tick >= openTick else { return }
        if let gate = state.gates.firstIndex(where: { $0.id == "gate-elite-forward" }) {
            state.gates[gate].closed = false
        }
        state.eliteGateOpenTick = nil
    }

    private mutating func applyNamedPulses(_ pulses: [Int], reason: ExposureReason, tick: UInt64) {
        for pulse in pulses {
            let amount = reason == .fogPulse && state.upgrade.signalJammer
                ? Int(IntMath.divHalfAway(Int64(pulse) * 75, 100))
                : pulse
            let before = state.exposure.exposure
            if !state.exposure.lockdownEntered {
                state.exposure.exposure = min(1000, state.exposure.exposure + amount)
                if state.exposure.exposure > state.exposure.peak {
                    state.exposure.peak = state.exposure.exposure
                }
                state.exposure.detectionState = DetectionState.projected(state.exposure.exposure)
                if state.exposure.exposure >= 1000 && !state.exposure.lockdownEntered {
                    state.exposure.lockdownEntered = true
                    state.exposure.detectionState = .lockdown
                    events.emit(
                        tick: tick,
                        phase: 13,
                        type: .lockdownEntered,
                        payload: ["reason": .string(reason.rawValue)]
                    )
                }
                events.emit(
                    tick: tick,
                    phase: 13,
                    type: .exposureChanged,
                    payload: [
                        "before": .integer(Int64(before)),
                        "after": .integer(Int64(state.exposure.exposure)),
                        "reason": .string(reason.rawValue)
                    ]
                )
            }
        }
    }

    private mutating func applyPlayerDamage(_ source: EntityID, amount: Int, tick: UInt64) {
        let applied = min(amount, state.player.integrity)
        state.player.integrity -= applied
        state.player.damageTaken += applied
        events.emit(
            tick: tick,
            phase: 12,
            type: .playerDamaged,
            primary: state.player.id,
            secondary: source,
            payload: [
                "amount": .integer(Int64(applied)),
                "remainingIntegrity": .integer(Int64(state.player.integrity)),
                "sourceEntityId": .string(source.decimalString)
            ]
        )
        if state.player.integrity <= 0 {
            fail(.playerDeath, tick: tick)
        }
    }

    private mutating func resolvePlayerDeathAndContact(tick: UInt64) {
        var threats: [(dps: Int, id: EntityID)] = []
        for enemy in state.enemies where enemy.alive {
            let combined = Int64(PlayerBody.radiusUnits + enemy.radius) * Q8.scale
            if state.player.position.distanceSquared(to: enemy.position) <= combined * combined {
                threats.append((enemy.contactDps, enemy.id))
            }
        }
        threats.sort {
            if $0.dps != $1.dps { return $0.dps > $1.dps }
            return $0.id < $1.id
        }
        let applied = threats.prefix(3)
        var dps = 0
        for threat in applied { dps += threat.dps }
        state.player.contactAccumulator += dps
        let points = state.player.contactAccumulator / 60
        state.player.contactAccumulator %= 60
        if points > 0 {
            applyPlayerDamage(applied.first?.id ?? state.player.id, amount: points, tick: tick)
        }
        if state.player.integrity <= 0 && state.outcome != .failure && state.outcome != .invalid {
            fail(.playerDeath, tick: tick)
        }

        for i in state.mines.indices {
            state.mines[i].armRemaining = max(0, state.mines[i].armRemaining - 1)
            state.mines[i].lifeRemaining -= 1
        }
        var remainingMines: [MineBody] = []
        for mine in state.mines where mine.lifeRemaining > 0 {
            if mine.armed {
                let r = Int64(mine.radius) * Q8.scale
                if state.player.position.distanceSquared(to: mine.position) <= r * r {
                    applyPlayerDamage(mine.ownerId, amount: mine.damage, tick: tick)
                    continue
                }
            }
            remainingMines.append(mine)
        }
        state.mines = remainingMines
    }

    private mutating func advanceEncounters(tick: UInt64, forceLockdown: inout Bool) {
        for trigger in state.arena.encounterTriggers {
            let id = trigger.encounterId ?? trigger.id
            if id == "improperSearchDaemon" {
                if state.encounters["M-A"]?.completed == true,
                   state.encounters["M-B"]?.completed == true,
                   state.encounters["M-C"]?.completed == true,
                   !state.eliteDefeated,
                   !state.enemies.contains(where: { $0.archetype == .improperSearchDaemon }),
                   trigger.aabb.contains(VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated))
                {
                    spawnElite(tick: tick)
                }
                continue
            }
            if id == "algorithmicModerate" {
                if state.eliteDefeated,
                   !state.bossDefeated,
                   !state.enemies.contains(where: { $0.archetype == .algorithmicModerate }),
                   trigger.aabb.contains(VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated))
                {
                    spawnBoss(tick: tick)
                }
                continue
            }
            guard var runtime = state.encounters[id], !runtime.activated else { continue }
            if trigger.aabb.contains(VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated)) {
                runtime.activated = true
                if id == "M-C" { forceLockdown = true }
                if let spec = state.content.encounters[id], let first = spec.waves.first {
                    runtime.spawnQueue = flatten(first.members)
                    runtime.nextSpawnTick = tick + UInt64(first.delay)
                    events.emit(
                        tick: tick,
                        phase: 15,
                        type: .waveStarted,
                        payload: ["encounterId": .string(id), "waveId": .string(first.id)]
                    )
                }
                closeForwardGate(for: id)
                state.encounters[id] = runtime
            }
        }

        for id in EncounterDirector.encounterOrder {
            guard var runtime = state.encounters[id], runtime.activated, !runtime.completed else { continue }
            if !runtime.spawnQueue.isEmpty, tick >= runtime.nextSpawnTick {
                if runtime.deferTicks >= SpawnFairness.timeoutTicks {
                    invalidate(.spawnFairnessTimeout)
                } else {
                    let archetype = runtime.spawnQueue.removeFirst()
                    if spawnEnemy(archetype, encounter: id, tick: tick) {
                        runtime.spawned += 1
                        runtime.living += 1
                        runtime.deferTicks = 0
                        let interval = state.content.encounters[id]?.waves[runtime.waveIndex].interval ?? 30
                        runtime.nextSpawnTick = tick + UInt64(interval)
                    } else {
                        runtime.spawnQueue.insert(archetype, at: 0)
                        runtime.deferTicks += SpawnFairness.retryIntervalTicks
                        runtime.nextSpawnTick = tick + UInt64(SpawnFairness.retryIntervalTicks)
                    }
                }
            }
            if runtime.spawnQueue.isEmpty, runtime.living == 0, let spec = state.content.encounters[id] {
                if runtime.waveIndex + 1 < spec.waves.count {
                    runtime.waveIndex += 1
                    let wave = spec.waves[runtime.waveIndex]
                    runtime.spawnQueue = flatten(wave.members)
                    runtime.nextSpawnTick = tick + UInt64(wave.delay)
                    events.emit(
                        tick: tick,
                        phase: 15,
                        type: .waveStarted,
                        payload: ["encounterId": .string(id), "waveId": .string(wave.id)]
                    )
                } else if runtime.spawned >= spec.totals {
                    runtime.completed = true
                    events.emit(
                        tick: tick,
                        phase: 15,
                        type: .mobEncounterCompleted,
                        payload: ["encounterId": .string(id)]
                    )
                    if id == "M-A" {
                        state.upgrade.pending = true
                        state.outcome = .upgradeSelectionPending
                        state.tutorial.noteMobAComplete()
                    }
                }
            }
            state.encounters[id] = runtime
        }
    }

    private func flatten(_ members: [WaveMember]) -> [ArchetypeID] {
        var result: [ArchetypeID] = []
        for member in members {
            result.append(contentsOf: repeatElement(member.archetype, count: member.count))
        }
        return result
    }

    private mutating func spawnEnemy(_ archetype: ArchetypeID, encounter: String, tick: UInt64) -> Bool {
        guard let stats = state.content.standardEnemies[archetype] else { return false }
        guard let sockets = state.arena.enemySpawnSockets[encounter] else { return false }
        let closed = Set(state.gates.filter(\.closed).map(\.id))
        let mounts = state.cameras.map { camera in
            AABB(
                center: camera.position,
                halfSize: VecI(x: camera.mountCollisionRadius, y: camera.mountCollisionRadius)
            )
        }
        guard let socket = SpawnFairness.select(
            sockets: sockets,
            player: state.player.position,
            heading: state.player.facing,
            archetypeRadius: stats.radius,
            manifest: state.arena,
            closedGateIDs: closed,
            extraSolids: mounts,
            lethalVolumes: lethalVolumes()
        ) else { return false }
        let id = state.allocator.next()
        var nextSpecial = tick
        switch archetype {
        case .fogAnalyticsCloud: nextSpecial = tick + 120
        case .cableCarCorrelator: nextSpecial = tick + 90
        case .sutroSignalWitch: nextSpecial = tick + 60
        case .victorianVendor: nextSpecial = tick + 90
        default: break
        }
        state.enemies.append(
            EnemyBody(
                id: id,
                archetype: archetype,
                position: VecI(x: socket.x, y: socket.y).asQ8,
                velocity: .zero,
                integrity: stats.hp,
                radius: stats.radius,
                speedUnitsPerSecond: stats.speed,
                contactDps: stats.contactDps,
                state: .pursue,
                stateTicks: 0,
                spawnTick: tick,
                nextSpecialTick: nextSpecial,
                lockPosition: nil,
                encounterId: encounter
            )
        )
        return true
    }

    private func lethalVolumes() -> [SpawnFairness.LethalVolume] {
        var volumes: [SpawnFairness.LethalVolume] = []
        for mine in state.mines where mine.lifeRemaining > 0 {
            volumes.append(SpawnFairness.LethalVolume(center: mine.position, radius: mine.radius))
        }
        for enemy in state.enemies where enemy.alive {
            switch enemy.state {
            case .telegraph, .resolve, .charge, .fire, .throwMine,
                 .queryTelegraph, .queryResolve, .dashTelegraph, .dash:
                if let stats = state.content.standardEnemies[enemy.archetype] {
                    if let pulse = stats.pulse {
                        volumes.append(SpawnFairness.LethalVolume(center: enemy.position, radius: pulse.range))
                    }
                    if stats.charge != nil {
                        volumes.append(
                            SpawnFairness.LethalVolume(
                                center: enemy.lockPosition ?? enemy.position,
                                radius: enemy.radius
                            )
                        )
                    }
                    if let mine = stats.mine, let mark = enemy.lockPosition {
                        volumes.append(SpawnFairness.LethalVolume(center: mark, radius: mine.radius))
                    }
                }
                for marker in enemy.queryMarkers {
                    volumes.append(
                        SpawnFairness.LethalVolume(center: marker, radius: DaemonQuery.circleRadius)
                    )
                }
            default:
                break
            }
        }
        return volumes
    }

    private mutating func spawnElite(tick: UInt64) {
        let spawn = state.arena.eliteSpawn
        let id = state.allocator.next()
        state.enemies.append(
            EnemyBody(
                id: id,
                archetype: .improperSearchDaemon,
                position: VecI(x: spawn.x, y: spawn.y).asQ8,
                velocity: .zero,
                integrity: state.content.eliteHP,
                radius: state.content.eliteRadius,
                speedUnitsPerSecond: state.content.eliteSpeed,
                contactDps: state.content.eliteContactDps,
                state: .pursue,
                stateTicks: 120,
                spawnTick: tick,
                nextSpecialTick: tick + UInt64(state.content.eliteSpawnDelay),
                lockPosition: nil,
                encounterId: "elite"
            )
        )
        events.emit(tick: tick, phase: 16, type: .eliteActivated, payload: ["eliteId": .string(ArchetypeID.improperSearchDaemon.rawValue)])
    }

    private mutating func spawnBoss(tick: UInt64) {
        let spawn = state.arena.bossSpawn
        let id = state.allocator.next()
        state.enemies.append(
            EnemyBody(
                id: id,
                archetype: .algorithmicModerate,
                position: VecI(x: spawn.x, y: spawn.y).asQ8,
                velocity: .zero,
                integrity: state.content.bossHP,
                radius: state.content.bossRadius,
                speedUnitsPerSecond: state.content.bossSpeed,
                contactDps: state.content.bossContactDps,
                state: .pursue,
                stateTicks: 0,
                spawnTick: tick,
                nextSpecialTick: tick + UInt64(state.content.bossInitialDelay),
                lockPosition: nil,
                encounterId: "boss"
            )
        )
        state.bossPhase = "publicSafety"
        state.phasesReached = ["publicSafety"]
        state.bossRuntime = BossRuntime()
        events.emit(tick: tick, phase: 16, type: .bossActivated, payload: ["bossId": .string(ArchetypeID.algorithmicModerate.rawValue)])
        events.emit(
            tick: tick,
            phase: 16,
            type: .bossPhaseChanged,
            payload: [
                "before": .null,
                "after": .string("publicSafety"),
                "remainingIntegrity": .integer(Int64(state.content.bossHP))
            ]
        )
        if let gate = state.gates.firstIndex(where: { $0.id == "gate-mc-forward" }) {
            state.gates[gate].closed = true
        }
    }

    private mutating func closeForwardGate(for encounter: String) {
        let id: String?
        switch encounter {
        case "M-A": id = "gate-ma-forward"
        case "M-B": id = "gate-mb-forward"
        case "M-C": id = "gate-mc-forward"
        default: id = nil
        }
        guard let id, let index = state.gates.firstIndex(where: { $0.id == id }) else { return }
        let box = state.gates[index].box
        if Circle(center: state.player.position, radiusUnits: PlayerBody.radiusUnits).penetrates(box) {
            return
        }
        state.gates[index].closed = true
    }

    private mutating func resolveObjectives(tick: UInt64) {
        if !state.extraction.armed,
           EncounterDirector.extractionArmed(
            mobAComplete: state.encounters["M-A"]?.completed == true,
            mobBComplete: state.encounters["M-B"]?.completed == true,
            mobCComplete: state.encounters["M-C"]?.completed == true,
            eliteDefeated: state.eliteDefeated,
            bossDefeated: state.bossDefeated,
            playerAlive: state.player.isAlive,
            runFailed: state.outcome == .failure
           )
        {
            state.extraction.armed = true
            events.emit(tick: tick, phase: 16, type: .extractionArmed)
        }
    }

    private mutating func resolveExtraction(tick: UInt64) {
        guard state.extraction.armed, state.outcome == .playing || state.outcome == .upgradeSelectionPending else { return }
        let inside = state.arena.extraction.aabb.contains(
            VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated)
        )
        if inside {
            if state.extraction.remaining > 0 {
                state.extraction.remaining -= 1
                events.emit(
                    tick: tick,
                    phase: 17,
                    type: .extractionCountdownChanged,
                    payload: ["remainingTicks": .integer(Int64(state.extraction.remaining))]
                )
            }
            if state.extraction.remaining == 0 && state.player.isAlive {
                succeed(tick: tick)
            }
            state.extraction.wasInside = true
        } else if state.extraction.wasInside {
            let previous = state.extraction.remaining
            state.extraction.remaining = state.arena.extraction.countdownTicks
            state.extraction.wasInside = false
            events.emit(
                tick: tick,
                phase: 17,
                type: .extractionReset,
                payload: ["previousRemainingTicks": .integer(Int64(previous))]
            )
        }
    }

    private mutating func emitExposure(_ resolution: ExposureState.Resolution, tick: UInt64) {
        if resolution.after != resolution.before {
            events.emit(
                tick: tick,
                phase: 13,
                type: .exposureChanged,
                payload: [
                    "before": .integer(Int64(resolution.before)),
                    "after": .integer(Int64(resolution.after)),
                    "reason": .string(resolution.reason.rawValue)
                ]
            )
        }
        if resolution.stateAfter != resolution.stateBefore {
            events.emit(
                tick: tick,
                phase: 14,
                type: .detectionStateChanged,
                payload: [
                    "before": .string(resolution.stateBefore.rawValue),
                    "after": .string(resolution.stateAfter.rawValue)
                ]
            )
        }
        if resolution.lockdownEnteredThisTick {
            events.emit(
                tick: tick,
                phase: 14,
                type: .lockdownEntered,
                payload: ["reason": .string(resolution.reason.rawValue)]
            )
        }
    }

    private mutating func sealTerminal(tick: UInt64) {
        guard state.terminalDigest == nil else { return }
        state.terminalTick = tick
        state.terminalDigest = state.digest()
    }

    private mutating func succeed(tick: UInt64) {
        guard state.outcome != .failure, state.outcome != .invalid else { return }
        guard state.outcome != .success else { return }
        state.outcome = .success
        sealTerminal(tick: tick)
        events.emit(
            tick: tick,
            phase: 18,
            type: .runSucceeded,
            payload: ["finalDigest": .string(state.terminalDigest!)]
        )
    }

    private mutating func fail(_ reason: FailureReason, tick: UInt64) {
        guard state.outcome != .invalid else { return }
        if state.outcome == .failure { return }
        state.outcome = .failure
        state.failureReason = reason
        sealTerminal(tick: tick)
        events.emit(
            tick: tick,
            phase: 18,
            type: .runFailed,
            payload: ["reason": .string(reason.rawValue)]
        )
    }

    private mutating func invalidate(_ code: DiagnosticCode) {
        guard state.outcome == .playing || state.outcome == .upgradeSelectionPending else { return }
        state.outcome = .invalid
        state.diagnostic = code
        sealTerminal(tick: state.tick)
        events.emit(
            tick: state.tick,
            phase: 18,
            type: .diagnosticFailure,
            payload: ["code": .string(code.rawValue)]
        )
    }

    private mutating func finishTick() -> TickResult {
        let published = events.publish()
        return TickResult(tick: state.tick, events: published, digest: state.digest(), outcome: state.outcome)
    }

    mutating func testing_armUpgradeSelection() {
        state.upgrade.pending = true
        state.outcome = .upgradeSelectionPending
    }

    mutating func testing_selectUpgrade(_ upgrade: UpgradeID) {
        state.upgrade.selected = upgrade
        state.upgrade.pending = false
        state.outcome = .playing
    }

    mutating func testing_setPlayerIntegrity(_ value: Int) {
        state.player.integrity = max(0, value)
    }

    mutating func testing_keepOnlyCamera(at index: Int, integrity: Int) {
        for i in state.cameras.indices {
            state.cameras[i].integrity = i == index ? integrity : 0
        }
    }

    mutating func testing_injectHostileBolt(kind: ProjectileKind = .sutroBolt, damage: Int = 10) {
        let pos = state.player.position
        let projectile = ProjectileBody(
            id: state.allocator.next(),
            ownerId: EntityID(0),
            kind: kind,
            position: pos,
            previous: pos,
            velocity: .zero,
            radius: 6,
            damage: damage,
            cameraDamage: 0,
            age: 2,
            lifetime: 90,
            distanceTravelledQ8: 0,
            maxTravelQ8: Int64(10_000) * Q8.scale,
            hitEntityIds: [],
            alive: true
        )
        state.projectiles.append(projectile)
    }

    mutating func testing_installBoss(integrity: Int = 800) {
        guard !state.enemies.contains(where: { $0.archetype == .algorithmicModerate }) else { return }
        let spawn = state.arena.bossSpawn
        let id = state.allocator.next()
        state.enemies.append(
            EnemyBody(
                id: id,
                archetype: .algorithmicModerate,
                position: VecI(x: spawn.x, y: spawn.y).asQ8,
                velocity: .zero,
                integrity: integrity,
                radius: state.content.bossRadius,
                speedUnitsPerSecond: state.content.bossSpeed,
                contactDps: state.content.bossContactDps,
                state: .pursue,
                stateTicks: 0,
                spawnTick: state.tick,
                nextSpecialTick: state.tick + UInt64(state.content.bossInitialDelay),
                lockPosition: nil,
                encounterId: "boss"
            )
        )
        state.bossPhase = BossPhase.publicSafety.rawValue
        state.phasesReached = [BossPhase.publicSafety.rawValue]
        state.bossRuntime = BossRuntime()
    }

    mutating func testing_insertMine(at position: VecI, armRemaining: Int, radius: Int = 40) {
        state.mines.append(
            MineBody(
                id: state.allocator.next(),
                ownerId: EntityID(1),
                position: position.asQ8,
                armRemaining: armRemaining,
                lifeRemaining: 300,
                radius: radius,
                damage: 15
            )
        )
    }

    mutating func testing_beginBossTelegraph(_ attack: BossAttackID, remaining: Int) {
        guard var runtime = state.bossRuntime else { return }
        runtime.currentAttack = attack
        runtime.telegraphRemaining = remaining
        runtime.recoveryRemaining = 0
        runtime.attackRemaining = 0
        runtime.cooldownRemaining = 0
        state.bossRuntime = runtime
    }

    mutating func testing_activateBossField(remaining: Int = 180) {
        guard var runtime = state.bossRuntime, let emitter = state.arena.captainCameraEmitters.first else { return }
        runtime.fieldRemaining = remaining
        runtime.activeEmitter = emitter
        runtime.currentAttack = .temporaryOrder
        state.bossRuntime = runtime
    }

    mutating func testing_injectBossBolt() {
        guard let boss = state.enemies.first(where: { $0.archetype == .algorithmicModerate }) else { return }
        let pos = boss.position
        state.projectiles.append(
            ProjectileBody(
                id: state.allocator.next(),
                ownerId: boss.id,
                kind: .bossBolt,
                position: pos,
                previous: pos,
                velocity: .zero,
                radius: 7,
                damage: 8,
                cameraDamage: 0,
                age: 2,
                lifetime: 90,
                distanceTravelledQ8: 0,
                maxTravelQ8: Int64(10_000) * Q8.scale,
                hitEntityIds: [],
                alive: true
            )
        )
    }

    mutating func testing_injectPulseHitting(position: VecQ8) {
        let id = state.allocator.next()
        let projectile = ProjectileBody(
            id: id,
            ownerId: state.player.id,
            kind: .civicPulse,
            position: position,
            previous: position,
            velocity: .zero,
            radius: Targeting.projectileRadius,
            damage: Targeting.enemyDamage,
            cameraDamage: Targeting.cameraDamage,
            age: 2,
            lifetime: 10,
            distanceTravelledQ8: 0,
            maxTravelQ8: Int64(Targeting.maxTravel) * Q8.scale,
            hitEntityIds: [],
            alive: true
        )
        guard state.civicPool.checkout(projectile) else { return }
        state.projectiles.append(projectile)
    }

    mutating func testing_completeEncounter(_ id: String) {
        var runtime = state.encounters[id] ?? EncounterRuntime(
            id: id,
            activated: true,
            completed: true,
            waveIndex: 0,
            spawnQueue: [],
            nextSpawnTick: 0,
            deferTicks: 0,
            living: 0,
            spawned: state.content.encounters[id]?.totals ?? 0,
            cleanupTick: nil
        )
        runtime.activated = true
        runtime.completed = true
        runtime.spawned = state.content.encounters[id]?.totals ?? runtime.spawned
        state.encounters[id] = runtime
    }

    mutating func testing_completeMobAndEliteGraph() {
        for id in EncounterDirector.encounterOrder {
            testing_completeEncounter(id)
        }
        state.eliteDefeated = true
    }

    mutating func testing_defeatBoss() {
        guard let index = state.enemies.firstIndex(where: { $0.archetype == .algorithmicModerate && $0.alive }) else {
            return
        }
        state.enemies[index].integrity = 0
        killEnemy(at: index, tick: state.tick)
    }

    mutating func testing_injectPulseHitting(camera: SelectedCamera) {
        let pos = camera.position.asQ8
        let anchor = camera.targetAnchor
        let dx = anchor.x.raw - pos.x.raw
        let dy = anchor.y.raw - pos.y.raw
        let standOff = VecQ8(
            x: Q8(raw: pos.x.raw + dx + dx / 2),
            y: Q8(raw: pos.y.raw + dy + dy / 2)
        )
        let id = state.allocator.next()
        let projectile = ProjectileBody(
            id: id,
            ownerId: state.player.id,
            kind: .civicPulse,
            position: standOff,
            previous: standOff,
            velocity: .zero,
            radius: Targeting.projectileRadius,
            damage: Targeting.enemyDamage,
            cameraDamage: Targeting.cameraDamage,
            age: 2,
            lifetime: 10,
            distanceTravelledQ8: 0,
            maxTravelQ8: Int64(Targeting.maxTravel) * Q8.scale,
            hitEntityIds: [],
            alive: true
        )
        guard state.civicPool.checkout(projectile) else { return }
        state.projectiles.append(projectile)
    }

    mutating func testing_keepCameras(_ indices: Set<Int>, integrity: Int) {
        for i in state.cameras.indices {
            state.cameras[i].integrity = indices.contains(i) ? integrity : 0
        }
    }

    mutating func testing_relocateCamera(at index: Int, position: VecI, headingMilli: Int) {
        guard state.cameras.indices.contains(index) else { return }
        guard var socket = state.arena.cameraSockets.first(where: { $0.socketId == state.cameras[index].socketId }) else {
            return
        }
        socket.position = position
        socket.headingMilliDegrees = headingMilli
        let geometry = state.arena.standardCameraGeometry
        state.cameras[index].position = position
        state.cameras[index].headingMilliDegrees = headingMilli
        state.cameras[index].fieldOrigin = CameraPlacement.fieldOrigin(socket: socket, geometry: geometry)
        state.cameras[index].targetAnchor = CameraPlacement.targetAnchor(socket: socket, geometry: geometry)
    }

    mutating func testing_destroyCameras() {
        for i in state.cameras.indices {
            state.cameras[i].integrity = 0
        }
    }

    mutating func testing_destroyCameraAtIndex(_ index: Int) {
        guard state.cameras.indices.contains(index), state.cameras[index].isDamageable else { return }
        state.cameras[index].integrity = 0
        destroyCamera(at: index, projectileKind: .civicPulse, projectile: EntityID(0), tick: state.tick + 1)
    }

    mutating func testing_setExtractionRemaining(_ value: Int) {
        state.extraction.remaining = max(0, value)
    }

    mutating func testing_armExtraction() {
        state.extraction.armed = true
    }

    mutating func testing_setExtractionWasInside(_ value: Bool) {
        state.extraction.wasInside = value
    }

    mutating func testing_setPhasesReached(_ phases: [String]) {
        state.phasesReached = phases
    }

    mutating func testing_setExposure(_ value: Int) {
        state.exposure.exposure = value
        state.exposure.peak = max(state.exposure.peak, value)
        state.exposure.detectionState = DetectionState.projected(value)
    }

    mutating func testing_insertEnemy(_ enemy: EnemyBody) {
        state.enemies.append(enemy)
    }

    mutating func testing_completeCombatGraph() {
        for id in EncounterDirector.encounterOrder {
            var runtime = state.encounters[id] ?? EncounterRuntime(
                id: id,
                activated: true,
                completed: true,
                waveIndex: 0,
                spawnQueue: [],
                nextSpawnTick: 0,
                deferTicks: 0,
                living: 0,
                spawned: state.content.encounters[id]?.totals ?? 0,
                cleanupTick: nil
            )
            runtime.activated = true
            runtime.completed = true
            runtime.spawned = state.content.encounters[id]?.totals ?? runtime.spawned
            state.encounters[id] = runtime
        }
        state.eliteDefeated = true
        state.bossDefeated = true
    }

    mutating func testing_spawnInformant(at position: VecI, integrity: Int? = nil, speed: Int? = nil) {
        let stats = state.content.standardEnemies[.autonomousInformant]!
        state.enemies.append(
            EnemyBody(
                id: state.allocator.next(),
                archetype: .autonomousInformant,
                position: position.asQ8,
                velocity: .zero,
                integrity: integrity ?? stats.hp,
                radius: stats.radius,
                speedUnitsPerSecond: speed ?? stats.speed,
                contactDps: stats.contactDps,
                state: .pursue,
                stateTicks: 0,
                spawnTick: state.tick,
                nextSpecialTick: 0,
                lockPosition: nil,
                encounterId: "test"
            )
        )
    }

    mutating func testing_setPlayerPosition(_ position: VecI) {
        state.player.position = position.asQ8
    }

    mutating func testing_activateEncounter(_ id: String, spawnQueue: [ArchetypeID]? = nil) {
        guard var runtime = state.encounters[id] else { return }
        runtime.activated = true
        runtime.completed = false
        runtime.waveIndex = 0
        runtime.deferTicks = 0
        runtime.living = 0
        runtime.spawned = 0
        if let queue = spawnQueue {
            runtime.spawnQueue = queue
            runtime.nextSpawnTick = state.tick
        } else if let spec = state.content.encounters[id], let first = spec.waves.first {
            runtime.spawnQueue = flatten(first.members)
            runtime.nextSpawnTick = state.tick
        }
        state.encounters[id] = runtime
    }

    mutating func testing_setEncounterSockets(_ id: String, sockets: [ArenaPoint]) {
        state.arena.enemySpawnSockets[id] = sockets
    }

    mutating func testing_obstructEncounterSockets(_ id: String) {
        guard let sockets = state.arena.enemySpawnSockets[id] else { return }
        for socket in sockets {
            let sid = socket.id ?? "\(socket.x)-\(socket.y)"
            state.arena.permanentSolids.append(
                NamedRect(
                    id: "test-obstruct-\(sid)",
                    name: nil,
                    owner: nil,
                    encounterId: nil,
                    center: VecI(x: socket.x, y: socket.y),
                    halfSize: VecI(x: 48, y: 48),
                    initiallyClosed: nil
                )
            )
        }
    }

    mutating func testing_fillCivicPool(count: Int) {
        for _ in 0..<count {
            let projectile = ProjectileBody(
                id: state.allocator.next(),
                ownerId: state.player.id,
                kind: .civicPulse,
                position: state.player.position,
                previous: state.player.position,
                velocity: .zero,
                radius: Targeting.projectileRadius,
                damage: Targeting.enemyDamage,
                cameraDamage: Targeting.cameraDamage,
                age: 1,
                lifetime: 10_000,
                distanceTravelledQ8: 0,
                maxTravelQ8: Int64(10_000) * Q8.scale,
                hitEntityIds: [],
                alive: true
            )
            guard state.civicPool.checkout(projectile) else { return }
        }
    }

    /// T705: canonical post-M-A upgrade selection through Extraction success with zero Camera destruction.
    @discardableResult
    mutating func testing_completeRunSuccess(upgrade: UpgradeID) -> TickResult {
        testing_completeEncounter("M-A")
        testing_armUpgradeSelection()
        let selectTick = state.tick + 1
        _ = step(
            command: PlayerCommand(
                tick: selectTick,
                moveX: 0,
                moveY: 0,
                dodgePressed: false,
                upgradeChoiceIndex: upgrade.selectionIndex
            )
        )
        testing_completeCombatGraph()
        _ = step(command: .neutral(tick: state.tick + 1))
        let extract = state.arena.extraction.center
        testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        var result = TickResult(tick: state.tick, events: [], digest: state.digest(), outcome: state.outcome)
        let countdown = state.arena.extraction.countdownTicks
        for _ in 0..<countdown {
            result = step(command: .neutral(tick: state.tick + 1))
        }
        return result
    }
}

#if DEBUG
extension Simulation {
    /// DEBUG-only scenario seeding for the runtime's own verification harness.
    ///
    /// The objective graph gates the boss behind the elite, and the elite
    /// behind three encounters, so a late-game presentation path cannot be
    /// reached by playing unless the pilot is good enough to clear them. This
    /// puts the simulation into a named legal state so the *renderer* can be
    /// observed there.
    ///
    /// It seeds authoritative state directly, so a run seeded this way is
    /// evidence about presentation only — never about balance, pacing, or the
    /// acceptance gates, which require an actually-played run. Never compiled
    /// into a release build.
    public mutating func debug_seedScenario(_ scenario: String) -> Bool {
        switch scenario {
        case "elite":
            testing_completeEncounter("M-A")
            testing_completeEncounter("M-B")
            testing_completeEncounter("M-C")
            return true
        case "boss":
            testing_completeMobAndEliteGraph()
            testing_installBoss()
            return true
        case "extraction":
            testing_completeCombatGraph()
            testing_armExtraction()
            return true
        default:
            return false
        }
    }
}
#endif
