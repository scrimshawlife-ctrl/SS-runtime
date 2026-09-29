import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-088: every `procedural-vfx-002` recipe reaches the screen, shake moves
/// the world camera and never the HUD, hit-stop freezes the world, and the
/// Reduced Flash Blackout changes no luminance.
@Suite(.serialized)
@MainActor
struct VFXRendererTests {
    @MainActor
    private struct Stage {
        let scene = SKScene(size: CGSize(width: 896, height: 414))
        let camera = SKCameraNode()
        let world = SKNode()
        let hud = SKNode()
        let vfx = VFXRenderer()

        init() {
            scene.addChild(world)
            scene.addChild(camera)
            scene.camera = camera
            hud.zPosition = 1000
            camera.addChild(hud)
            vfx.install(in: scene, camera: camera, worldRoot: world)
        }
    }

    private static func snapshot() throws -> PresentationSnapshot {
        let sim = try Simulation.make(seed: 1)
        return PresentationSnapshot(sim.state)
    }

    /// One event per recipe, as the simulation would publish them.
    private static func everyRecipeEvents(_ snap: PresentationSnapshot) -> [AuthoritativeEvent] {
        let camera = snap.cameras[0].id
        var insertion = 0
        func event(_ type: EventType, _ primary: EntityID? = nil, _ payload: [String: CanonicalJSON] = [:]) -> AuthoritativeEvent {
            insertion += 1
            return AuthoritativeEvent(tick: 1, phase: 10, type: type, primary: primary, payload: payload, insertion: insertion)
        }
        let player = snap.player.id
        return [
            event(.detectionStateChanged, player, ["before": .string("hidden"), "after": .string("observed")]),
            event(.detectionStateChanged, player, ["before": .string("observed"), "after": .string("tracked")]),
            event(.playerDamaged, player, ["amount": .integer(4)]),
            event(.entityDamaged, EntityID(500)),
            event(.entityDied, EntityID(501)),
            event(.dodgeStarted, player),
            event(.projectileHit, EntityID(600), ["targetEntityId": .string("\(camera.raw)")]),
            event(.projectileHit, EntityID(601), ["targetEntityId": .string("\(player.raw)")]),
            event(.lockdownEntered, nil, ["reason": .string("exposure")]),
            event(.bossAttackStarted, EntityID(700)),
            event(.extractionArmed),
            event(.cameraDestroyed, camera),
            event(.allCamerasDestroyed),
            event(.bossPhaseChanged, EntityID(700), ["before": .string("publicSafety"), "after": .string("civilLiberties")]),
            event(.waveStarted, nil, ["encounterId": .string("M-A"), "waveId": .string("w1")])
        ]
    }

    @Test func everyRecipeDraws() throws {
        let stage = Stage()
        let snap = try Self.snapshot()
        stage.vfx.ingest(tick: 1, events: Self.everyRecipeEvents(snap), snapshot: snap, heatReinforcements: 1)
        stage.vfx.render(snap)
        let catalog = try ProceduralVFXCatalog.bundled()
        for recipe in catalog.recipes {
            #expect(stage.vfx.drawnByRecipe[recipe.id] == 1, "\(recipe.id) was not drawn")
        }
        #expect(stage.vfx.liveEffectCount <= catalog.maxConcurrentEmitters)
        #expect(!stage.vfx.worldLayer.children.isEmpty)
        #expect(!stage.vfx.screenLayer.children.isEmpty)
    }

    @Test func effectsLeaveWhenTheirLifetimeEnds() throws {
        let stage = Stage()
        let snap = try Self.snapshot()
        stage.vfx.ingest(tick: 1, events: Self.everyRecipeEvents(snap), snapshot: snap, heatReinforcements: 1)
        // The longest recipe is the Blackout's 1.5 s: 90 frames.
        for _ in 0..<91 { stage.vfx.render(snap) }
        #expect(stage.vfx.liveEffectCount == 0)
        #expect(stage.vfx.worldLayer.children.isEmpty)
        #expect(stage.vfx.screenLayer.children.isEmpty)
    }

    @Test func screenLayerSitsUnderTheHUDAndOnTheCamera() {
        let stage = Stage()
        #expect(stage.vfx.screenLayer.parent === stage.camera)
        #expect(stage.vfx.screenLayer.zPosition < stage.hud.zPosition)
        #expect(stage.vfx.worldLayer.parent === stage.scene)
        #expect(stage.vfx.worldLayer.zPosition > CGFloat(WorldRenderer.Layer.markers.rawValue))
    }

    /// § 9: the shake offsets the world camera. The HUD is its child, so the
    /// HUD's on-screen position does not move.
    @Test func shakeMovesTheCameraAndNotTheHUD() throws {
        let stage = Stage()
        let snap = try Self.snapshot()
        let base = CGPoint(x: 400, y: 300)
        let kill = [AuthoritativeEvent(tick: 1, phase: 10, type: .cameraDestroyed, primary: snap.cameras[0].id, insertion: 0)]
        stage.vfx.ingest(tick: 1, events: kill, snapshot: snap)
        var moved = false
        for _ in 0..<ScreenShake.durationFrames {
            let position = stage.vfx.cameraPosition(base: base)
            stage.camera.position = position
            if position != base { moved = true }
            let offset = hypot(position.x - base.x, position.y - base.y)
            #expect(offset <= ScreenShake.maxAmplitude + 0.001)
            #expect(stage.hud.position == .zero)
        }
        #expect(moved)
        #expect(stage.vfx.cameraPosition(base: base) == base)
    }

    @Test func noShakeUnderReducedMotion() throws {
        let stage = Stage()
        stage.vfx.settings = PresentationVFXSettings(reducedMotion: true, reducedFlash: false)
        let snap = try Self.snapshot()
        let base = CGPoint(x: 10, y: 10)
        let kill = [AuthoritativeEvent(tick: 1, phase: 10, type: .cameraDestroyed, primary: snap.cameras[0].id, insertion: 0)]
        stage.vfx.ingest(tick: 1, events: kill, snapshot: snap)
        for _ in 0..<ScreenShake.durationFrames {
            #expect(stage.vfx.cameraPosition(base: base) == base)
        }
    }

    @Test func hitStopFreezesTheWorldThenReleases() throws {
        let stage = Stage()
        let snap = try Self.snapshot()
        let kill = [AuthoritativeEvent(tick: 1, phase: 10, type: .cameraDestroyed, primary: snap.cameras[0].id, insertion: 0)]
        stage.vfx.ingest(tick: 1, events: kill, snapshot: snap)
        var frozen = 0
        while stage.vfx.consumeHitStopFrame() {
            frozen += 1
            #expect(stage.world.isPaused)
            #expect(stage.vfx.worldLayer.isPaused)
        }
        #expect(frozen == 3) // 50 ms at 60 Hz
        #expect(!stage.world.isPaused)
        #expect(!stage.vfx.worldLayer.isPaused)
    }

    /// hud-tutorial.md: Reduced Flash forbids full-screen luminance changes.
    /// The reduced Blackout is a banner; nothing covers the screen.
    @Test func reducedFlashBlackoutHasNoFullScreenNode() throws {
        let stage = Stage()
        stage.vfx.settings = PresentationVFXSettings(reducedMotion: false, reducedFlash: true)
        let snap = try Self.snapshot()
        let blackout = [AuthoritativeEvent(tick: 1, phase: 10, type: .allCamerasDestroyed, insertion: 0)]
        stage.vfx.ingest(tick: 1, events: blackout, snapshot: snap)
        #expect(stage.vfx.drawnByRecipe["networkBlackout"] == 1)
        let full = CGFloat(PresentationCamera.visibleWidth)
        var covering = 0
        stage.vfx.screenLayer.enumerateChildNodes(withName: "//*") { node, _ in
            if node.calculateAccumulatedFrame().width >= full { covering += 1 }
        }
        #expect(covering == 0)
        #expect(stage.vfx.worldLayer.children.allSatisfy { $0.children.isEmpty })
        // No hit-stop in the reduced Blackout.
        #expect(!stage.vfx.consumeHitStopFrame())
    }
}
