public enum BossPhase: String, Equatable, Sendable {
    case publicSafety
    case civilLiberties
    case temporarySafeguard
    case independentReview

    public static let receiptOrder: [BossPhase] = [
        .publicSafety,
        .civilLiberties,
        .temporarySafeguard,
        .independentReview
    ]

    public static func canonicalPhasesReached(_ visited: [String]) -> [String] {
        let seen = Set(visited)
        return receiptOrder.map(\.rawValue).filter { seen.contains($0) }
    }

    public static func from(hp: Int) -> BossPhase {
        switch hp {
        case 600...800: .publicSafety
        case 400..<600: .civilLiberties
        case 200..<400: .temporarySafeguard
        default: .independentReview
        }
    }

    public var sequence: [BossAttackID] {
        switch self {
        case .publicSafety: [.safetyRationale, .narrowTailoring]
        case .civilLiberties: [.narrowTailoring, .safetyRationale, .temporaryOrder]
        case .temporarySafeguard: [.temporaryOrder, .narrowTailoring, .safetyRationale]
        case .independentReview: [.independentReview, .narrowTailoring, .temporaryOrder]
        }
    }
}

public enum BossAttackID: String, Equatable, Sendable {
    case safetyRationale
    case narrowTailoring
    case temporaryOrder
    case independentReview
}

public struct BossRuntime: Equatable, Sendable {
    public var phase: BossPhase
    public var sequenceIndex: Int
    public var recoveryRemaining: Int
    public var telegraphRemaining: Int
    public var attackRemaining: Int
    public var cooldownRemaining: Int
    public var currentAttack: BossAttackID?
    public var emitterIndex: Int
    public var lockedHeadingMilli: Int?
    public var fieldRemaining: Int
    public var activeEmitter: CaptainEmitter?
    /// Research only (`research/pacing-search`): boss Integrity as a percent
    /// of the authored 800, so the phase bands scale with it. 100 is the
    /// shipped rule. Set only by `Simulation.testing_bossPhaseScalePercent`.
    var testing_phaseIntegrityScalePercent = 100

    public var observationNumerator: Int {
        switch phase {
        case .publicSafety: 105
        case .civilLiberties: 108
        case .temporarySafeguard: 112
        case .independentReview: 116
        }
    }

    public var speedNumerator: Int {
        switch phase {
        case .publicSafety: 100
        case .civilLiberties: 90
        case .temporarySafeguard: 118
        case .independentReview: 104
        }
    }

    public var contactNumerator: Int {
        switch phase {
        case .publicSafety: 100
        case .civilLiberties: 104
        case .temporarySafeguard: 110
        case .independentReview: 116
        }
    }

    public var orbitNumerator: Int {
        switch phase {
        case .publicSafety: 0
        case .civilLiberties: 72
        case .temporarySafeguard: 18
        case .independentReview: -55
        }
    }

    public init(phase: BossPhase = .publicSafety) {
        self.phase = phase
        sequenceIndex = 0
        recoveryRemaining = 90
        telegraphRemaining = 0
        attackRemaining = 0
        cooldownRemaining = 0
        currentAttack = nil
        emitterIndex = 0
        lockedHeadingMilli = nil
        fieldRemaining = 0
        activeEmitter = nil
    }

    public mutating func syncPhase(hp: Int) -> (before: BossPhase, after: BossPhase)? {
        let before = phase
        let next = BossPhase.from(hp: hp * 100 / testing_phaseIntegrityScalePercent)
        guard next != before else { return nil }
        phase = next
        sequenceIndex = 0
        recoveryRemaining = 45
        telegraphRemaining = 0
        attackRemaining = 0
        cooldownRemaining = 0
        currentAttack = nil
        lockedHeadingMilli = nil
        fieldRemaining = 0
        activeEmitter = nil
        return (before, next)
    }

    public mutating func retireField() {
        fieldRemaining = 0
        activeEmitter = nil
        currentAttack = nil
        telegraphRemaining = 0
        attackRemaining = 0
    }
}

public enum BossSystem {
    public static func step(
        boss: inout EnemyBody,
        runtime: inout BossRuntime,
        player: PlayerBody,
        tick: UInt64,
        emitters: [CaptainEmitter],
        solids: [(id: String, box: AABB)],
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody],
        exposurePulse: inout Int?,
        playerDamage: inout Int,
        events: inout EventBuffer,
        baseSpeed: Int,
        baseContact: Int
    ) {
        if let transition = runtime.syncPhase(hp: boss.integrity), boss.alive {
            retireBossProjectiles(&projectiles)
            events.emit(
                tick: tick,
                phase: 16,
                type: .bossPhaseChanged,
                primary: boss.id,
                payload: [
                    "before": .string(transition.before.rawValue),
                    "after": .string(transition.after.rawValue),
                    "remainingIntegrity": .integer(Int64(boss.integrity))
                ]
            )
        }

        applyLocomotion(boss: &boss, runtime: runtime, player: player, baseSpeed: baseSpeed)
        boss.contactDps = Int(IntMath.divHalfAway(Int64(baseContact) * Int64(runtime.contactNumerator), 100))

        if runtime.fieldRemaining > 0 {
            runtime.fieldRemaining -= 1
            if runtime.fieldRemaining % 30 == 0, let emitter = runtime.activeEmitter,
               playerInField(emitter, player: player, solids: solids)
            {
                exposurePulse = 10
            }
            if runtime.fieldRemaining == 0 {
                runtime.activeEmitter = nil
            }
        }

        if runtime.recoveryRemaining > 0 {
            runtime.recoveryRemaining -= 1
            return
        }
        if runtime.attackRemaining > 0 {
            runtime.attackRemaining -= 1
            if runtime.attackRemaining == 0 {
                runtime.currentAttack = nil
            }
        }
        if runtime.telegraphRemaining > 0 {
            runtime.telegraphRemaining -= 1
            if runtime.telegraphRemaining == 0, let attack = runtime.currentAttack {
                resolve(
                    attack,
                    boss: boss,
                    runtime: &runtime,
                    player: player,
                    emitters: emitters,
                    solids: solids,
                    allocator: &allocator,
                    projectiles: &projectiles,
                    exposurePulse: &exposurePulse,
                    playerDamage: &playerDamage
                )
                events.emit(
                    tick: tick,
                    phase: 16,
                    type: .bossAttackStarted,
                    primary: boss.id,
                    payload: [
                        "attackId": .string(attack.rawValue),
                        "phaseId": .string(runtime.phase.rawValue)
                    ]
                )
            }
            return
        }
        if runtime.cooldownRemaining > 0 {
            runtime.cooldownRemaining -= 1
            return
        }
        let sequence = runtime.phase.sequence
        let attack = sequence[runtime.sequenceIndex % sequence.count]
        runtime.currentAttack = attack
        runtime.sequenceIndex += 1
        switch attack {
        case .safetyRationale:
            runtime.telegraphRemaining = 45
        case .narrowTailoring:
            runtime.telegraphRemaining = 30
        case .temporaryOrder:
            runtime.telegraphRemaining = 48
        case .independentReview:
            runtime.telegraphRemaining = 60
        }
    }

    public static func observationAmount(base: Int, numerator: Int, signalJammer: Bool) -> Int {
        var amount = IntMath.divHalfAway(Int64(base) * Int64(numerator), 100)
        if signalJammer {
            amount = IntMath.divHalfAway(amount * 75, 100)
        }
        return Int(amount)
    }

    public static func independentReviewLanes(toPlayerMilli: Int) -> [Int] {
        var lanes = (0..<6).map { MilliDeg.normalize($0 * 60_000) }
        let nearest = lanes.enumerated().min { lhs, rhs in
            let ld = MilliDeg.absDelta(lhs.element, toPlayerMilli)
            let rd = MilliDeg.absDelta(rhs.element, toPlayerMilli)
            if ld != rd { return ld < rd }
            return lhs.offset < rhs.offset
        }!.offset
        lanes.remove(at: nearest)
        return lanes
    }

    public static func playerInField(
        _ emitter: CaptainEmitter,
        player: PlayerBody,
        solids: [(id: String, box: AABB)]
    ) -> Bool {
        Collision.pointInCone(
            origin: emitter.position.asQ8,
            point: player.position,
            headingMilli: emitter.headingMilliDegrees,
            halfFieldMilli: emitter.fieldAngleMilliDegrees / 2,
            rangeUnits: emitter.rangeUnits
        ) && Collision.lineOfFireClear(from: emitter.position.asQ8, to: player.position, solids: solids)
    }

    public static func retireBossProjectiles(_ projectiles: inout [ProjectileBody]) {
        for i in projectiles.indices where projectiles[i].kind == .bossBolt {
            projectiles[i].alive = false
        }
    }

    private static func applyLocomotion(
        boss: inout EnemyBody,
        runtime: BossRuntime,
        player: PlayerBody,
        baseSpeed: Int
    ) {
        let speedUnits = Int(IntMath.divHalfAway(Int64(baseSpeed) * Int64(runtime.speedNumerator), 100))
        let speed = Steering.speedQ8(speedUnits)
        let dx = player.position.x.raw - boss.position.x.raw
        let dy = player.position.y.raw - boss.position.y.raw
        let mag = IntMath.isqrt(dx * dx + dy * dy)
        if mag == 0 {
            boss.velocity = .zero
            return
        }
        var cx = IntMath.mulDivHalfAway(dx, Q8.scale, mag)
        var cy = IntMath.mulDivHalfAway(dy, Q8.scale, mag)
        let orbit = runtime.orbitNumerator
        if orbit != 0 {
            let even = boss.id.raw.isMultiple(of: 2)
            var px = even ? cy : 0 &- cy
            var py = even ? 0 &- cx : cx
            if orbit < 0 {
                px = 0 &- px
                py = 0 &- py
            }
            let ratio = Int64(orbit < 0 ? -orbit : orbit)
            cx += IntMath.divHalfAway(px * ratio, 100)
            cy += IntMath.divHalfAway(py * ratio, 100)
        }
        let combined = IntMath.isqrt(cx * cx + cy * cy)
        if combined == 0 {
            boss.velocity = .zero
            return
        }
        boss.velocity = VecQ8(
            x: Q8(raw: IntMath.mulDivHalfAway(cx, speed, combined)),
            y: Q8(raw: IntMath.mulDivHalfAway(cy, speed, combined))
        )
    }

    private static func resolve(
        _ attack: BossAttackID,
        boss: EnemyBody,
        runtime: inout BossRuntime,
        player: PlayerBody,
        emitters: [CaptainEmitter],
        solids: [(id: String, box: AABB)],
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody],
        exposurePulse: inout Int?,
        playerDamage: inout Int
    ) {
        switch attack {
        case .safetyRationale:
            let heading = Cordic.atan2Milli(
                y: player.position.y.raw - boss.position.y.raw,
                x: player.position.x.raw - boss.position.x.raw
            )
            runtime.lockedHeadingMilli = heading
            runtime.cooldownRemaining = 90
            if Collision.pointInCone(
                origin: boss.position,
                point: player.position,
                headingMilli: heading,
                halfFieldMilli: 35_000,
                rangeUnits: 260
            ) && Collision.lineOfFireClear(from: boss.position, to: player.position, solids: solids) {
                playerDamage = 18
            }
        case .narrowTailoring:
            let heading = Cordic.atan2Milli(
                y: player.position.y.raw - boss.position.y.raw,
                x: player.position.x.raw - boss.position.x.raw
            )
            for offset in [-12_000, 0, 12_000] {
                fire(
                    from: boss.position,
                    headingMilli: MilliDeg.normalize(heading + offset),
                    speed: 420,
                    radius: 7,
                    lifetime: 72,
                    damage: 9,
                    owner: boss.id,
                    allocator: &allocator,
                    projectiles: &projectiles
                )
            }
            runtime.cooldownRemaining = 75
        case .temporaryOrder:
            if !emitters.isEmpty {
                let emitter = emitters[runtime.emitterIndex % emitters.count]
                runtime.emitterIndex = (runtime.emitterIndex + 1) % emitters.count
                runtime.activeEmitter = emitter
                runtime.fieldRemaining = 180
            }
            runtime.cooldownRemaining = 120
        case .independentReview:
            let toPlayer = Cordic.atan2Milli(
                y: player.position.y.raw - boss.position.y.raw,
                x: player.position.x.raw - boss.position.x.raw
            )
            for lane in independentReviewLanes(toPlayerMilli: toPlayer) {
                fire(
                    from: boss.position,
                    headingMilli: lane,
                    speed: 360,
                    radius: 7,
                    lifetime: 90,
                    damage: 8,
                    owner: boss.id,
                    allocator: &allocator,
                    projectiles: &projectiles
                )
            }
            runtime.cooldownRemaining = 105
        }
    }

    private static func fire(
        from: VecQ8,
        headingMilli: Int,
        speed: Int,
        radius: Int,
        lifetime: Int,
        damage: Int,
        owner: EntityID,
        allocator: inout EntityAllocator,
        projectiles: inout [ProjectileBody]
    ) {
        let unit = Cordic.headingUnit(milliDegrees: headingMilli)
        let speedQ8 = Steering.speedQ8(speed)
        let velocity = VecQ8(
            x: Q8(raw: IntMath.mulDivHalfAway(Int64(unit.x), speedQ8, Int64(Cordic.q15))),
            y: Q8(raw: IntMath.mulDivHalfAway(Int64(unit.y), speedQ8, Int64(Cordic.q15)))
        )
        projectiles.append(
            ProjectileBody(
                id: allocator.next(),
                ownerId: owner,
                kind: .bossBolt,
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
