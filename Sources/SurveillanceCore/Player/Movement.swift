public struct PlayerBody: Equatable, Sendable {
    public static let radiusUnits = 18
    public static let maxIntegrity = 100
    public static let maxSpeedUnitsPerTick = 4
    public static let dodgeSpeedUnitsPerTick = 8
    public static let dodgeDurationTicks = 12
    public static let dodgeCooldownTicks = 120
    public static let ghostDodgeSpeedUnitsPerTick = 9
    public static let ghostDodgeCooldownTicks = 90
    public static let ghostCameraImmunityTicks = 29

    public var id: EntityID
    public var position: VecQ8
    public var facing: VecQ8
    public var integrity: Int
    public var dodgeActiveRemaining: Int
    public var dodgeStartedAt: UInt64?
    public var dodgeReadyTick: UInt64
    public var lastDodgePressed: Bool
    public var cameraInvisibleUntilTick: UInt64
    public var rejectedDodges: Int
    public var damageTaken: Int
    public var contactAccumulator: Int
    /// D-090 (`player-controller.md` § Damage response): the carried part of
    /// every scaled Integrity loss, in hundredths of a point, always 0...99.
    /// Authoritative and in the state digest.
    public var damageRemainderHundredths: Int = 0
    /// World units travelled on the last simulated tick. Presentation-supporting
    /// bookkeeping, like `damageTaken`; it is not part of the state digest and
    /// no rule reads it.
    public var movedUnitsLastTick: Int = 0
    /// This tick's velocity, in Q8 units per tick: the analog command (or the
    /// Dodge heading) before solid collision, which is what
    /// `player-controller.md` calls velocity. Zero while standing. The
    /// chosen-Camera test (D-082) reads it in the same tick it is written, so
    /// it carries nothing across ticks and stays out of the digest.
    public var velocity: VecQ8 = .zero

    public init(id: EntityID, spawn: VecI) {
        self.id = id
        self.position = spawn.asQ8
        self.facing = VecQ8(unitsX: 1, unitsY: 0)
        self.integrity = Self.maxIntegrity
        self.dodgeActiveRemaining = 0
        self.dodgeStartedAt = nil
        self.dodgeReadyTick = 1
        self.lastDodgePressed = false
        self.cameraInvisibleUntilTick = 0
        self.rejectedDodges = 0
        self.damageTaken = 0
        self.contactAccumulator = 0
    }

    public var isAlive: Bool { integrity > 0 }

    public func isCameraInvisible(tick: UInt64) -> Bool {
        cameraInvisibleUntilTick != 0 && tick <= cameraInvisibleUntilTick
    }
}

public enum Movement {
    public static func displacement(from command: PlayerCommand, dodgeActive: Bool, ghostStep: Bool) -> VecQ8 {
        let maxAxis = Int64(PlayerCommand.axisMaximum)
        let speed = dodgeActive
            ? (ghostStep ? PlayerBody.ghostDodgeSpeedUnitsPerTick : PlayerBody.dodgeSpeedUnitsPerTick)
            : PlayerBody.maxSpeedUnitsPerTick
        let maxDisp = Int64(speed) * Q8.scale
        let mx = Int64(command.moveX)
        let my = Int64(command.moveY)
        if mx == 0 && my == 0 {
            return .zero
        }
        let magSq = mx * mx + my * my
        let limitSq = maxAxis * maxAxis
        if magSq <= limitSq {
            return VecQ8(
                x: Q8(raw: IntMath.mulDivHalfAway(mx, maxDisp, maxAxis)),
                y: Q8(raw: IntMath.mulDivHalfAway(my, maxDisp, maxAxis))
            )
        }
        let mag = IntMath.isqrt(magSq)
        return VecQ8(
            x: Q8(raw: IntMath.mulDivHalfAway(mx, maxDisp, mag)),
            y: Q8(raw: IntMath.mulDivHalfAway(my, maxDisp, mag))
        )
    }

    public static func apply(
        player: inout PlayerBody,
        command: PlayerCommand,
        tick: UInt64,
        ghostStep: Bool,
        bounds: AABB,
        solids: [(id: String, box: AABB)],
        events: inout EventBuffer
    ) {
        let risingDodge = command.dodgePressed && !player.lastDodgePressed
        player.lastDodgePressed = command.dodgePressed

        let cooldown = ghostStep ? PlayerBody.ghostDodgeCooldownTicks : PlayerBody.dodgeCooldownTicks
        let dodgeReady = tick >= player.dodgeReadyTick && player.dodgeActiveRemaining == 0

        if risingDodge {
            if dodgeReady {
                player.dodgeActiveRemaining = PlayerBody.dodgeDurationTicks
                player.dodgeStartedAt = tick
                player.dodgeReadyTick = tick + UInt64(cooldown)
                if ghostStep {
                    player.cameraInvisibleUntilTick = tick + UInt64(PlayerBody.ghostCameraImmunityTicks)
                }
                events.emit(
                    tick: tick,
                    phase: 4,
                    type: .dodgeStarted,
                    primary: player.id,
                    payload: ["cooldownReadyTick": .unsigned(player.dodgeReadyTick)]
                )
            } else {
                player.rejectedDodges += 1
            }
        }

        let dodgeActive = player.dodgeActiveRemaining > 0
        var delta = displacement(from: command, dodgeActive: dodgeActive, ghostStep: ghostStep)
        if dodgeActive && command.moveX == 0 && command.moveY == 0 {
            let scale = Int64(
                ghostStep ? PlayerBody.ghostDodgeSpeedUnitsPerTick : PlayerBody.dodgeSpeedUnitsPerTick
            ) * Q8.scale
            let len = IntMath.isqrt(player.facing.lengthSquaredRaw)
            if len > 0 {
                delta = VecQ8(
                    x: Q8(raw: IntMath.mulDivHalfAway(player.facing.x.raw, scale, len)),
                    y: Q8(raw: IntMath.mulDivHalfAway(player.facing.y.raw, scale, len))
                )
            }
        }

        player.velocity = delta
        if delta != .zero {
            player.facing = delta
        }

        player.position = Collision.slideCircle(
            from: player.position,
            delta: delta,
            radius: PlayerBody.radiusUnits,
            bounds: bounds,
            solids: solids
        )

        if player.dodgeActiveRemaining > 0 {
            player.dodgeActiveRemaining -= 1
        }
    }
}
