public enum Steering {
    public static func toward(_ from: VecQ8, _ to: VecQ8, speedPerTickQ8: Int64) -> VecQ8 {
        Targeting.direct(from: from, to: to, speed: speedPerTickQ8)
    }

    public static func speedQ8(_ unitsPerSecond: Int) -> Int64 {
        IntMath.mulDivHalfAway(Int64(unitsPerSecond), Q8.scale, 60)
    }

    public static func applySeparation(
        enemies: inout [EnemyBody],
        index: Int
    ) {
        let selfID = enemies[index].id
        let selfPos = enemies[index].position
        let selfR = enemies[index].radius
        var sep = VecQ8.zero
        for other in enemies where other.alive && other.id != selfID {
            let combined = Int64(selfR + other.radius + 8) * Q8.scale
            let dx = selfPos.x.raw - other.position.x.raw
            let dy = selfPos.y.raw - other.position.y.raw
            let distSq = dx * dx + dy * dy
            if distSq == 0 || distSq >= combined * combined { continue }
            if other.id < selfID { continue }
            sep.x.raw += dx
            sep.y.raw += dy
        }
        if sep != .zero {
            let mag = IntMath.isqrt(sep.lengthSquaredRaw)
            let max = speedQ8(enemies[index].speedUnitsPerSecond)
            enemies[index].velocity.x.raw += IntMath.mulDivHalfAway(sep.x.raw, max / 4, mag)
            enemies[index].velocity.y.raw += IntMath.mulDivHalfAway(sep.y.raw, max / 4, mag)
            clampSpeed(&enemies[index].velocity, max: max)
        }
    }

    public static func clampSpeed(_ velocity: inout VecQ8, max: Int64) {
        let mag = IntMath.isqrt(velocity.lengthSquaredRaw)
        if mag > max && mag > 0 {
            velocity.x.raw = IntMath.mulDivHalfAway(velocity.x.raw, max, mag)
            velocity.y.raw = IntMath.mulDivHalfAway(velocity.y.raw, max, mag)
        }
    }

    public static func orbitVelocity(
        from: VecQ8,
        around: VecQ8,
        clockwise: Bool,
        speedPerTickQ8: Int64
    ) -> VecQ8 {
        let dx = around.x.raw - from.x.raw
        let dy = around.y.raw - from.y.raw
        let px = clockwise ? dy : -dy
        let py = clockwise ? -dx : dx
        let mag = IntMath.isqrt(px * px + py * py)
        if mag == 0 { return .zero }
        return VecQ8(
            x: Q8(raw: IntMath.mulDivHalfAway(px, speedPerTickQ8, mag)),
            y: Q8(raw: IntMath.mulDivHalfAway(py, speedPerTickQ8, mag))
        )
    }
}

public enum EnemySystem {
    public static func step(
        enemies: inout [EnemyBody],
        player: PlayerBody,
        tick: UInt64,
        content: CombatContent,
        bounds: AABB,
        solids: [(id: String, box: AABB)],
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody],
        mines: inout [MineBody],
        exposurePulses: inout [Int],
        playerDamage: inout [(EntityID, Int)],
        alertedThisTick: Set<EntityID> = []
    ) {
        let ordered = enemies.indices.sorted { enemies[$0].id < enemies[$1].id }
        for index in ordered {
            guard enemies[index].alive else { continue }
            // D-089: an unaware enemy holds its spawn position with zero
            // velocity and runs no state machine, so it never telegraphs,
            // attacks, pulses, charges, throws, or mines. One alerted this
            // tick begins its state machine on the next tick.
            if enemies[index].isUnaware || alertedThisTick.contains(enemies[index].id) {
                enemies[index].velocity = .zero
                continue
            }
            var damage = 0
            think(
                &enemies[index],
                player: player,
                tick: tick,
                content: content,
                allocator: &allocator,
                projectiles: &projectiles,
                mines: &mines,
                exposurePulses: &exposurePulses,
                solids: solids,
                playerDamage: &damage
            )
            if damage > 0 {
                playerDamage.append((enemies[index].id, damage))
            }
            Steering.applySeparation(enemies: &enemies, index: index)
            let moved = Collision.slideCircle(
                from: enemies[index].position,
                delta: enemies[index].velocity,
                radius: enemies[index].radius,
                bounds: bounds,
                solids: solids
            )
            if enemies[index].state == .charge, moved == enemies[index].position, enemies[index].velocity != .zero {
                enemies[index].state = .recover
                enemies[index].stateTicks = content.standardEnemies[enemies[index].archetype]?.charge?.recover ?? 45
                enemies[index].velocity = .zero
            }
            enemies[index].position = moved
        }
    }

    private static func think(
        _ enemy: inout EnemyBody,
        player: PlayerBody,
        tick: UInt64,
        content: CombatContent,
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody],
        mines: inout [MineBody],
        exposurePulses: inout [Int],
        solids: [(id: String, box: AABB)],
        playerDamage: inout Int
    ) {
        let speed = Steering.speedQ8(enemy.speedUnitsPerSecond)
        let distSq = enemy.position.distanceSquared(to: player.position)
        enemy.stateTicks = max(0, enemy.stateTicks - 1)
        if enemy.state == .telegraph && enemy.stateTicks > 0 {
            enemy.velocity = .zero
            return
        }

        switch enemy.archetype {
        case .autonomousInformant:
            enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)

        case .fogAnalyticsCloud:
            let stats = content.standardEnemies[.fogAnalyticsCloud]!
            let pulse = stats.pulse!
            if enemy.state == .telegraph && enemy.stateTicks == 0 {
                let range = Int64(pulse.range) * Q8.scale
                if distSq <= range * range, Collision.lineOfFireClear(from: enemy.position, to: player.position, solids: solids) {
                    exposurePulses.append(pulse.exposure)
                }
                enemy.state = .cooldown
                enemy.stateTicks = pulse.cooldown
                enemy.nextSpecialTick = tick + UInt64(pulse.cooldown)
            } else if tick >= enemy.nextSpecialTick && enemy.state != .telegraph {
                enemy.state = .telegraph
                enemy.stateTicks = pulse.telegraph
            } else if distSq > Int64(210) * Int64(210) * Q8.scale * Q8.scale {
                enemy.state = .pursue
                enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
            } else {
                enemy.state = .orbit
                enemy.velocity = Steering.orbitVelocity(
                    from: enemy.position,
                    around: player.position,
                    clockwise: enemy.id.raw.isMultiple(of: 2),
                    speedPerTickQ8: speed
                )
            }

        case .cableCarCorrelator:
            let charge = content.standardEnemies[.cableCarCorrelator]!.charge!
            if enemy.state == .telegraph && enemy.stateTicks == 0 {
                enemy.lockPosition = player.position
                enemy.state = .charge
                enemy.stateTicks = charge.ticks
                enemy.velocity = Steering.toward(
                    enemy.position,
                    player.position,
                    speedPerTickQ8: Steering.speedQ8(charge.speed)
                )
            } else if enemy.state == .charge && enemy.stateTicks == 0 {
                enemy.state = .recover
                enemy.stateTicks = charge.recover
                enemy.velocity = .zero
            } else if enemy.state == .recover && enemy.stateTicks == 0 {
                enemy.state = .pursue
                enemy.nextSpecialTick = tick + UInt64(charge.cooldown)
            } else if enemy.state == .charge {
                break
            } else if tick >= enemy.nextSpecialTick, distSq <= Int64(240) * Int64(240) * Q8.scale * Q8.scale {
                enemy.state = .telegraph
                enemy.stateTicks = charge.telegraph
                enemy.velocity = .zero
            } else {
                enemy.state = .pursue
                enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
            }

        case .sutroSignalWitch:
            let stats = content.standardEnemies[.sutroSignalWitch]!
            let shot = stats.shot!
            let minR = Int64(stats.range![0]) * Q8.scale
            let maxR = Int64(stats.range![1]) * Q8.scale
            let dist = IntMath.isqrt(distSq)
            if enemy.state == .telegraph && enemy.stateTicks == 0 {
                let vel = Targeting.direct(from: enemy.position, to: player.position, speed: Steering.speedQ8(shot.speed))
                spawnProjectile(
                    kind: .sutroBolt,
                    from: enemy.position,
                    velocity: vel,
                    owner: enemy.id,
                    radius: shot.radius,
                    damage: shot.damage,
                    lifetime: shot.lifetime,
                    allocator: &allocator,
                    projectiles: &projectiles
                )
                enemy.state = .cooldown
                enemy.nextSpecialTick = tick + UInt64(shot.cooldown)
            } else if tick >= enemy.nextSpecialTick && enemy.state != .telegraph {
                enemy.state = .telegraph
                enemy.stateTicks = shot.telegraph
                enemy.velocity = .zero
            } else if dist > maxR {
                enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
            } else if dist < minR {
                enemy.velocity = Steering.toward(player.position, enemy.position, speedPerTickQ8: speed)
            } else {
                enemy.velocity = Steering.orbitVelocity(
                    from: enemy.position,
                    around: player.position,
                    clockwise: enemy.id.raw.isMultiple(of: 2),
                    speedPerTickQ8: speed
                )
            }

        case .victorianVendor:
            let stats = content.standardEnemies[.victorianVendor]!
            let mine = stats.mine!
            let minR = Int64(stats.range![0]) * Q8.scale
            let maxR = Int64(stats.range![1]) * Q8.scale
            let dist = IntMath.isqrt(distSq)
            if enemy.state == .telegraph && enemy.stateTicks == 0 {
                if mines.filter({ $0.ownerId == enemy.id }).count >= mine.maximum {
                    if let oldest = mines.indices.filter({ mines[$0].ownerId == enemy.id }).min(by: { mines[$0].id < mines[$1].id }) {
                        mines.remove(at: oldest)
                    }
                }
                mines.append(
                    MineBody(
                        id: allocator.next(),
                        ownerId: enemy.id,
                        position: player.position,
                        armRemaining: mine.arm,
                        lifeRemaining: mine.lifetime,
                        radius: mine.radius,
                        damage: mine.damage
                    )
                )
                enemy.state = .cooldown
                enemy.nextSpecialTick = tick + UInt64(mine.cooldown)
            } else if tick >= enemy.nextSpecialTick && enemy.state != .telegraph {
                enemy.state = .telegraph
                enemy.stateTicks = mine.telegraph
                enemy.velocity = .zero
            } else if dist > maxR {
                enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
            } else if dist < minR {
                enemy.velocity = Steering.toward(player.position, enemy.position, speedPerTickQ8: speed)
            } else {
                enemy.velocity = .zero
            }

        case .improperSearchDaemon:
            stepDaemon(&enemy, player: player, speed: speed, playerDamage: &playerDamage)

        case .algorithmicModerate:
            break
        }
    }

    private static func stepDaemon(
        _ enemy: inout EnemyBody,
        player: PlayerBody,
        speed: Int64,
        playerDamage: inout Int
    ) {
        if enemy.stateTicks > 0 {
            switch enemy.state {
            case .pursue:
                enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
            case .dash:
                break
            default:
                enemy.velocity = .zero
            }
            return
        }
        switch enemy.state {
        case .pursue:
            enemy.queryMarkers = DaemonQuery.markers(playerPosition: player.position, facing: player.facing)
            enemy.state = .queryTelegraph
            enemy.stateTicks = 45
            enemy.velocity = .zero
        case .queryTelegraph:
            enemy.state = .queryResolve
            enemy.stateTicks = 0
            stepDaemon(&enemy, player: player, speed: speed, playerDamage: &playerDamage)
        case .queryResolve:
            playerDamage += DaemonQuery.damage(playerPosition: player.position, markers: enemy.queryMarkers)
            enemy.state = .dashTelegraph
            enemy.stateTicks = 36
            enemy.velocity = .zero
        case .dashTelegraph:
            enemy.state = .dash
            enemy.stateTicks = 30
            enemy.velocity = Steering.toward(
                enemy.position,
                player.position,
                speedPerTickQ8: Steering.speedQ8(288)
            )
        case .dash:
            enemy.state = .recover
            enemy.stateTicks = 60
            enemy.velocity = .zero
        default:
            enemy.state = .pursue
            enemy.stateTicks = 120
            enemy.velocity = Steering.toward(enemy.position, player.position, speedPerTickQ8: speed)
        }
    }

    private static func spawnProjectile(
        kind: ProjectileKind,
        from: VecQ8,
        velocity: VecQ8,
        owner: EntityID,
        radius: Int,
        damage: Int,
        lifetime: Int,
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody]
    ) {
        let id = allocator.next()
        projectiles.append(
            ProjectileBody(
                id: id,
                ownerId: owner,
                kind: kind,
                position: from + velocity,
                previous: from,
                velocity: velocity,
                radius: radius,
                damage: damage,
                cameraDamage: 0,
                age: 1,
                lifetime: lifetime,
                distanceTravelledQ8: IntMath.isqrt(velocity.lengthSquaredRaw),
                maxTravelQ8: Int64(10_000) * Q8.scale,
                hitEntityIds: [],
                alive: true
            )
        )
    }
}
