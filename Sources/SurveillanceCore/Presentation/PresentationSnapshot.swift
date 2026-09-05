/// Immutable presentation projection of authoritative state. Does not own rules.
public struct PresentationSnapshot: Equatable, Sendable {
    public struct CircleSprite: Equatable, Sendable {
        public var id: EntityID
        public var x: Int
        public var y: Int
        public var radius: Int
        public var role: String
        public var silhouette: ActorSilhouette
        /// clip-metadata-001 clip this actor is presenting, or nil when its
        /// authoritative state has no clip and it keeps its blockout.
        public var clipId: String?
        public var direction: String
    }

    public struct CameraSprite: Equatable, Sendable {
        public var id: EntityID
        public var x: Int
        public var y: Int
        public var headingMilli: Int
        public var range: Int
        public var fieldAngleMilli: Int
        public var integrity: Int
        public var detecting: Bool
        public var presentationState: CameraPresentationState
        public var fieldVisible: Bool
        public var clipId: String
    }

    /// combat-001 projectile, projected so the renderer never infers combat
    /// geometry from sprite bounds.
    public struct ProjectileSprite: Equatable, Sendable {
        public var id: EntityID
        public var x: Int
        public var y: Int
        /// Previous authoritative position, for swept presentation only.
        public var previousX: Int
        public var previousY: Int
        public var radius: Int
        public var hostile: Bool
        public var role: String
    }

    /// Victorian Vendor mine, projected with its authoritative arming state.
    public struct MineSprite: Equatable, Sendable {
        public var id: EntityID
        public var x: Int
        public var y: Int
        public var radius: Int
        public var armed: Bool
        public var armRemaining: Int
        public var lifeRemaining: Int
    }

    /// hud-tutorial-001 boss Integrity bar source.
    public struct BossHUD: Equatable, Sendable {
        public var id: EntityID
        public var integrity: Int
        public var maxIntegrity: Int
        public var phase: BossPhase
        public var inTransition: Bool
    }

    public var tick: UInt64
    public var outcome: RunOutcome
    public var player: CircleSprite
    public var playerIntegrity: Int
    public var exposure: Int
    public var detection: DetectionState
    public var solids: [AABB]
    public var cameras: [CameraSprite]
    public var enemies: [CircleSprite]
    public var extraction: AABB
    public var extractionArmed: Bool
    public var extractionRemaining: Int
    /// Current node of the combat authority graph. The HUD renders its copy;
    /// exposing the node itself lets a caller reason about progress without
    /// parsing display text.
    public var objectiveNode: CombatAuthorityNode
    public var combatObjectiveCopy: String
    public var camerasDestroyed: Int
    public var cameraObjectiveVisible: Bool
    public var cameraObjectiveCopy: String
    public var networkBlackout: Bool
    public var upgrade: UpgradeID?
    public var upgradePending: Bool
    public var tutorialCopy: String?
    public var camera: PresentationCamera
    public var handedness: Handedness
    public var extractionSeconds: Int
    public var queryMarkers: [CircleSprite]
    public var captainField: CameraSprite?
    public var spawnSockets: [VecI]
    public var debugSolids: [AABB]
    /// clip-metadata-001 clip the Player is presenting, and the compass
    /// direction it faces. Presentation only; no rule reads either.
    public var playerClipId: String
    public var playerDirection: String
    public var projectiles: [ProjectileSprite]
    public var mines: [MineSprite]
    public var boss: BossHUD?
    public var telegraphs: [TelegraphShape]

    /// Which Player clip the authoritative state calls for. Ordered by
    /// precedence: a terminal outcome outranks Extraction, which outranks
    /// motion.
    static func playerClip(_ state: WorldState) -> String {
        if state.outcome == .failure { return "player_defeat" }
        if state.outcome == .success { return "player_complete" }
        if state.player.dodgeActiveRemaining > 0 { return "player_dodge" }
        let inExtraction = state.arena.extraction.aabb.contains(
            VecI(
                x: state.player.position.x.unitsTruncated,
                y: state.player.position.y.unitsTruncated
            )
        )
        if state.extraction.armed, inExtraction { return "player_extraction" }
        return state.player.movedUnitsLastTick == 0 ? "player_idle" : "player_move"
    }

    public init(_ state: WorldState) {
        tick = state.tick
        outcome = state.outcome
        player = CircleSprite(
            id: state.player.id,
            x: state.player.position.x.unitsTruncated,
            y: state.player.position.y.unitsTruncated,
            radius: PlayerBody.radiusUnits,
            role: "player",
            silhouette: .playerRing,
            clipId: nil,
            direction: ClipFrameLibrary.direction(forFacing: state.player.facing)
        )
        playerIntegrity = state.player.integrity
        exposure = state.exposure.exposure
        detection = state.exposure.detectionState
        solids = state.liveSolids.map(\.box)
        cameras = state.cameras.map {
            let presentationState = CameraPresentation.persistentState(integrity: $0.integrity)
            return CameraSprite(
                id: $0.entityId,
                x: $0.position.x,
                y: $0.position.y,
                headingMilli: $0.headingMilliDegrees,
                range: $0.rangeUnits,
                fieldAngleMilli: $0.fieldAngleMilliDegrees,
                integrity: $0.integrity,
                detecting: $0.wasDetecting,
                presentationState: presentationState,
                fieldVisible: $0.integrity > 0,
                clipId: CameraPresentation.clipId(for: presentationState)
            )
        }
        enemies = state.enemies.filter(\.alive).map { enemy in
            CircleSprite(
                id: enemy.id,
                x: enemy.position.x.unitsTruncated,
                y: enemy.position.y.unitsTruncated,
                radius: enemy.radius,
                role: enemy.archetype.rawValue,
                silhouette: ActorSilhouette.enemy(enemy.archetype),
                clipId: ActorClipProjection.clipId(for: enemy, bossRuntime: state.bossRuntime),
                direction: ActorClipProjection.direction(for: enemy.velocity)
            )
        }
        extraction = state.arena.extraction.aabb
        extractionArmed = state.extraction.armed
        extractionRemaining = state.extraction.remaining
        let authority = CombatAuthoritySnapshot.project(state)
        objectiveNode = authority.currentNode
        let playerPoint = VecI(
            x: state.player.position.x.unitsTruncated,
            y: state.player.position.y.unitsTruncated
        )
        let insideExtraction = state.arena.extraction.aabb.contains(playerPoint)
        combatObjectiveCopy = HUDLayout.combatObjectiveCopy(
            node: authority.currentNode,
            extractionArmed: state.extraction.armed,
            insideLockedExtraction: insideExtraction && !state.extraction.armed
        )
        camerasDestroyed = state.destructions.count
        let damaged = camerasDestroyed > 0 || state.cameras.contains { $0.integrity < 3 }
        cameraObjectiveVisible = HUDLayout.cameraObjectiveVisible(
            destroyed: camerasDestroyed,
            damaged: damaged
        )
        networkBlackout = state.networkBlackout
        cameraObjectiveCopy = HUDLayout.cameraObjectiveCopy(
            destroyed: camerasDestroyed,
            complete: state.networkBlackout
        )
        upgrade = state.upgrade.selected
        upgradePending = state.upgrade.pending
        tutorialCopy = state.tutorial.copy.isEmpty ? nil : state.tutorial.copy
        camera = PresentationCamera.follow(
            player: VecI(x: state.player.position.x.unitsTruncated, y: state.player.position.y.unitsTruncated),
            heading: state.player.facing,
            bounds: state.arena.boundsUnits
        )
        handedness = state.handedness
        extractionSeconds = HUDLayout.extractionSeconds(state.extraction.remaining)
        queryMarkers = state.enemies.flatMap { enemy -> [CircleSprite] in
            guard enemy.archetype == .improperSearchDaemon,
                  enemy.state == .queryTelegraph || enemy.state == .queryResolve
            else { return [] }
            return enemy.queryMarkers.map { center in
                CircleSprite(
                    id: enemy.id,
                    x: center.x.unitsTruncated,
                    y: center.y.unitsTruncated,
                    radius: DaemonQuery.circleRadius,
                    role: "daemonQuery",
                    silhouette: .queryApertures,
                    clipId: nil,
                    direction: "s"
                )
            }
        }
        if let emitter = state.bossRuntime?.activeEmitter, (state.bossRuntime?.fieldRemaining ?? 0) > 0 {
            captainField = CameraSprite(
                id: EntityID(0),
                x: emitter.x,
                y: emitter.y,
                headingMilli: emitter.headingMilliDegrees,
                range: emitter.rangeUnits,
                fieldAngleMilli: emitter.fieldAngleMilliDegrees,
                integrity: 1,
                detecting: true,
                presentationState: .critical,
                fieldVisible: true,
                clipId: CameraPresentation.clipId(for: .critical)
            )
        } else {
            captainField = nil
        }
        spawnSockets = state.arena.enemySpawnSockets.values.flatMap { sockets in
            sockets.map { VecI(x: $0.x, y: $0.y) }
        } + [
            VecI(x: state.arena.eliteSpawn.x, y: state.arena.eliteSpawn.y),
            VecI(x: state.arena.bossSpawn.x, y: state.arena.bossSpawn.y)
        ]
        debugSolids = solids

        // combat-001: live projectiles are authoritative entities. Ordered by
        // stable ID so the renderer can reuse nodes deterministically.
        projectiles = state.projectiles
            .filter(\.alive)
            .sorted { $0.id.raw < $1.id.raw }
            .map { projectile in
                ProjectileSprite(
                    id: projectile.id,
                    x: projectile.position.x.unitsTruncated,
                    y: projectile.position.y.unitsTruncated,
                    previousX: projectile.previous.x.unitsTruncated,
                    previousY: projectile.previous.y.unitsTruncated,
                    radius: projectile.radius,
                    hostile: projectile.kind == .bossBolt || projectile.kind == .sutroBolt,
                    role: String(describing: projectile.kind)
                )
            }

        mines = state.mines
            .sorted { $0.id.raw < $1.id.raw }
            .map { mine in
                MineSprite(
                    id: mine.id,
                    x: mine.position.x.unitsTruncated,
                    y: mine.position.y.unitsTruncated,
                    radius: mine.radius,
                    armed: mine.armed,
                    armRemaining: mine.armRemaining,
                    lifeRemaining: mine.lifeRemaining
                )
            }

        if let bossBody = state.enemies.first(where: { $0.archetype == .algorithmicModerate && $0.alive }),
           let runtime = state.bossRuntime
        {
            boss = BossHUD(
                id: bossBody.id,
                integrity: bossBody.integrity,
                maxIntegrity: state.content.bossHP,
                phase: runtime.phase,
                inTransition: runtime.recoveryRemaining > 0
            )
        } else {
            boss = nil
        }

        playerDirection = ClipFrameLibrary.direction(forFacing: state.player.facing)
        playerClipId = Self.playerClip(state)
        telegraphs = TelegraphProjection.project(state)
    }
}
