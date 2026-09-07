public struct WorldState: Equatable, Sendable {
    public var identity: ReplayIdentity
    public var seed: UInt64
    public var clock: SimulationClock
    public var combatRng: Xoshiro256StarStar
    public var allocator: EntityAllocator
    public var outcome: RunOutcome
    public var failureReason: FailureReason?
    public var diagnostic: DiagnosticCode?
    public var terminalTick: UInt64?
    public var terminalDigest: String?
    public var player: PlayerBody
    public var cameras: [SelectedCamera]
    public var enemies: [EnemyBody]
    public var projectiles: [ProjectileBody]
    public var mines: [MineBody]
    public var exposure: ExposureState
    public var upgrade: UpgradeState
    public var extraction: ExtractionState
    public var encounters: [String: EncounterRuntime]
    public var gates: [GateState]
    public var eliteDefeated: Bool
    public var bossDefeated: Bool
    public var bossPhase: String?
    public var phasesReached: [String]
    public var combat: CombatTotals
    public var destructions: [CameraDestructionRecord]
    public var lastPulseTick: UInt64
    public var networkBlackout: Bool
    public var arena: ArenaManifest
    public var content: CombatContent
    public var tutorial: TutorialState
    public var bossRuntime: BossRuntime?
    public var handedness: Handedness
    public var civicPool: ProjectilePool
    public var eliteGateOpenTick: UInt64?

    public var tick: UInt64 { clock.tick }

    public var liveSolids: [(id: String, box: AABB)] {
        var solids = arena.solidsForCollision
        // T411: destroyed Cameras keep the authored mount footprint; no extra debris.
        for camera in cameras {
            solids.append(
                (
                    camera.mountSolidId,
                    AABB(
                        center: camera.position,
                        halfSize: VecI(x: camera.mountCollisionRadius, y: camera.mountCollisionRadius)
                    )
                )
            )
        }
        for gate in gates where gate.closed {
            solids.append((gate.id, gate.box))
        }
        return solids
    }

    public func digest() -> String {
        StateDigest.hash(self)
    }
}

public enum StateDigest {
    public static func hash(_ state: WorldState) -> String {
        canonical(state).sha256Hex()
    }

    public static func canonical(_ state: WorldState) -> CanonicalJSON {
        .object([
            "rulesetVersion": .string(state.identity.rulesetVersion),
            "contentVersion": .string(state.identity.contentVersion),
            "arenaVersion": .string(state.identity.arenaVersion),
            "schemaVersion": .string(state.identity.replaySchemaVersion),
            "seed": .unsigned(state.seed),
            "tick": .unsigned(state.tick),
            "outcome": .string(state.outcome.rawValue),
            "player": .object([
                "id": .unsigned(state.player.id.raw),
                "x": .integer(state.player.position.x.raw),
                "y": .integer(state.player.position.y.raw),
                "integrity": .integer(Int64(state.player.integrity)),
                "dodgeActiveRemaining": .integer(Int64(state.player.dodgeActiveRemaining)),
                "dodgeReadyTick": .unsigned(state.player.dodgeReadyTick)
            ]),
            "cameras": .array(state.cameras.sorted { $0.entityId < $1.entityId }.map { camera in
                .object([
                    "id": .unsigned(camera.entityId.raw),
                    "socketId": .string(camera.socketId),
                    "integrity": .integer(Int64(camera.integrity)),
                    "housing": .string(camera.housingFamily.rawValue)
                ])
            }),
            "enemies": .array(state.enemies.filter(\.alive).sorted { $0.id < $1.id }.map { enemy in
                .object([
                    "id": .unsigned(enemy.id.raw),
                    "archetype": .string(enemy.archetype.rawValue),
                    "x": .integer(enemy.position.x.raw),
                    "y": .integer(enemy.position.y.raw),
                    "integrity": .integer(Int64(enemy.integrity))
                ])
            }),
            "exposure": .object([
                "value": .integer(Int64(state.exposure.exposure)),
                "state": .string(state.exposure.detectionState.rawValue),
                "noContactTicks": .integer(Int64(state.exposure.noContactTicks)),
                "lockdownEntered": .bool(state.exposure.lockdownEntered)
            ]),
            "upgrade": state.upgrade.selected.map { .string($0.rawValue) } ?? .null,
            "extraction": .object([
                "armed": .bool(state.extraction.armed),
                "remaining": .integer(Int64(state.extraction.remaining))
            ]),
            "eliteDefeated": .bool(state.eliteDefeated),
            "bossDefeated": .bool(state.bossDefeated),
            "allocatorNext": .unsigned(state.allocator.nextRaw),
            "rng": .object([
                "s0": .unsigned(state.combatRng.s0),
                "s1": .unsigned(state.combatRng.s1),
                "s2": .unsigned(state.combatRng.s2),
                "s3": .unsigned(state.combatRng.s3)
            ])
        ])
    }
}
