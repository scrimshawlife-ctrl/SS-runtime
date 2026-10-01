import Foundation
import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-095 and D-097–D-099 in the app: the session that carries them stays
/// presentation only, the intro holds the first tick back, and the new layers
/// sit where the readability floor needs them.
@Suite(.serialized)
@MainActor
struct FeelPassAppTests {
    private static func command(_ tick: UInt64) -> (x: Int16, y: Int16, dodge: Bool) {
        let phase = Double(tick) / 75
        return (Int16(cos(phase) * 24_000), Int16(sin(phase * 0.6) * 24_000), tick % 300 == 0)
    }

    /// The proof on the real session: `GameSession` (with the medal tracker,
    /// takedowns, tutorial queue, encounter gate, near miss, and decorated
    /// audio) against a bare simulation fed the same commands.
    @Test func sessionDigestAndReceiptMatchABareSimulation() throws {
        let session = GameSession(seed: 21)
        var bare = try Simulation.make(seed: 21)
        for tick in UInt64(1)...1_500 {
            let move = Self.command(tick)
            session.moveX = move.x
            session.moveY = move.y
            session.dodgePressed = move.dodge
            session.step()
            let result = bare.step(command: PlayerCommand(tick: tick, moveX: move.x, moveY: move.y, dodgePressed: move.dodge))
            #expect(session.simulation.state.digest() == result.digest)
            if bare.isTerminal { break }
        }
        #expect(RunReceipt(session.simulation.state) == RunReceipt(bare.state))
        #expect(session.commandLog.count == Int(bare.state.tick))
    }

    /// D-098: no tick runs during the intro; the run starts on the frame
    /// after it ends, from tick 0, and the digest matches a run that never
    /// had one. Driven through the same gate `GameScene.update` uses.
    @Test func introHoldsTheFirstTickForTwoSeconds() throws {
        let session = GameSession(seed: 31)
        var intro: IntroSequence? = IntroSequence(
            cameraIds: session.simulation.state.cameras.map(\.entityId),
            reducedMotion: false
        )
        var chirps: [EntityID] = []
        var frames = 0
        while session.simulation.state.tick < 60 {
            frames += 1
            let frame = GameScene.introFrame(&intro)
            chirps += frame.chirps
            if frame.mayStep { session.step() }
            if frames <= IntroSequence.totalFrames { #expect(session.simulation.state.tick == 0) }
        }
        #expect(frames == IntroSequence.totalFrames + 60)
        #expect(chirps == session.simulation.state.cameras.map(\.entityId).sorted())
        var bare = try Simulation.make(seed: 31)
        for tick in UInt64(1)...60 { bare.step(command: .neutral(tick: tick)) }
        #expect(session.simulation.state.digest() == bare.state.digest())
    }

    @Test func aTouchSkipsTheIntroAndAHoldFreezesIt() {
        var intro: IntroSequence? = IntroSequence(cameraIds: [EntityID(5), EntityID(3)], reducedMotion: false)
        #expect(!GameScene.introFrame(&intro).mayStep)
        intro?.skip()
        #expect(GameScene.introFrame(&intro).mayStep)
        #expect(intro == nil)
        var held: IntroSequence? = IntroSequence(cameraIds: [EntityID(5)], reducedMotion: false)
        for _ in 0..<200 { _ = GameScene.introFrame(&held, holdAt: 10) }
        #expect(held?.frame == 10)
    }

    /// § 10.3 limits: the grade sits above the ground and its dressing and
    /// under every layer that carries an actor, telegraph, or Camera field.
    @Test func gradeDarkensTheGroundOnly() {
        let grade = DailyGradeLayer()
        let z = grade.node.zPosition
        #expect(z > CGFloat(WorldRenderer.Layer.decorations.rawValue))
        for layer in [WorldRenderer.Layer.cameraFields, .telegraphs, .actorShadows, .actors, .projectiles, .markers, .extraction, .mines] {
            #expect(z < CGFloat(layer.rawValue), "\(layer) must never be graded")
        }
        grade.apply(.nightShift, arena: AABB(center: VecI(x: 1152, y: 768), halfSize: VecI(x: 1152, y: 768)))
        #expect(!grade.node.isHidden)
        #expect(grade.node.blendMode == .multiply)
        grade.apply(.clear, arena: AABB(center: VecI(x: 0, y: 0), halfSize: VecI(x: 10, y: 10)))
        #expect(grade.node.isHidden)
    }

    @Test func fogDensitySplitsAboveOneHundredPercent() {
        let dense = FogDensity.split(density: 1.2)
        #expect(dense.base == 1)
        #expect(abs(dense.boost - 0.2) < 1e-9)
        let light = FogDensity.split(density: 0.8)
        #expect(light.base == 0.8 && light.boost == 0)
        let thinned = FogDensity.split(density: 1.2 * 0.5)
        #expect(abs(thinned.base - 0.6) < 1e-9 && thinned.boost == 0, "thinned in a fight")
    }

    /// D-100: the near-miss edge is the cone's own blue made paler, never
    /// gold, which is reserved for pickups.
    @Test func nearMissEdgeIsTheConeBlueNotGold() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NearMissEdgeLayer.edgeColour.getRed(&r, green: &g, blue: &b, alpha: &a)
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        Palette.patrolConeEdge.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        #expect(b >= r && b >= g, "blue leads, as in the cone")
        #expect(b - r >= 0.1, "a gold or amber edge has more red than blue")
        #expect(r >= cr && g >= cg && b >= cb, "paler than the cone's own edge")
    }

    @Test func nearMissEdgeLightsOnlyTheNamedCones() throws {
        var sim = try Simulation.make(seed: 1)
        sim.step(command: .neutral(tick: 1))
        let snap = PresentationSnapshot(sim.state)
        let cones = snap.patrolCones.map(\.id)
        #expect(cones.count >= 2)
        let layer = NearMissEdgeLayer()
        layer.update(snap, nearMiss: [cones[0]], frame: 7, reducedMotion: true)
        #expect(layer.litIds == [cones[0]])
        let edges = layer.node.children.compactMap { $0 as? SKShapeNode }
        #expect(edges.count == 1)
        #expect(edges[0].alpha == 1, "steady bright edge under Reduced Motion")
        layer.update(snap, nearMiss: [], frame: 8, reducedMotion: false)
        #expect(layer.litIds.isEmpty)
        #expect(layer.node.zPosition < CGFloat(WorldRenderer.Layer.telegraphs.rawValue))
    }

    @Test func takedownRingHoldsStillUnderReducedMotion() {
        let still = TakedownRing.make(at: .zero, settings: PresentationVFXSettings(reducedMotion: true))
        let moving = TakedownRing.make(at: .zero, settings: PresentationVFXSettings())
        #expect(still.xScale == 1)
        #expect(moving.xScale < 1)
        #expect(still.name == TakedownRing.name)
    }

    @Test func medalStoreKeepsTodayOnly() throws {
        let seedA: UInt64 = 0xA11CE
        let seedB: UInt64 = 0xB0B
        let firstNew = MedalStore.record(earned: [.ghost, .swift], seed: seedA)
        #expect(firstNew == [.ghost, .swift])
        #expect(MedalStore.earned(seed: seedA) == [.ghost, .swift])
        #expect(MedalStore.record(earned: [.ghost], seed: seedA).isEmpty, "RS-023")
        MedalStore.record(earned: [.blackout], seed: seedB)
        #expect(MedalStore.earned(seed: seedA).isEmpty, "a new day starts empty")
        #expect(MedalStore.earned(seed: seedB) == [.blackout])
        try? FileManager.default.removeItem(at: try MedalStore.directoryURL())
    }
}
