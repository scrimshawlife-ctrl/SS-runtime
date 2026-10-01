import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-089 on screen (animation.md § 8a): the renderer draws a `?` above each
/// unaware enemy from the snapshot and drops it once the enemy is alerted,
/// and `enemyAlerted` pops a `!` that is static under the reduced variant.
@Suite(.serialized)
@MainActor
struct AwarenessPresentationTests {
    private static func labels(_ text: String, in node: SKNode) -> [SKLabelNode] {
        var found: [SKLabelNode] = []
        node.enumerateChildNodes(withName: "//*") { child, _ in
            if let label = child as? SKLabelNode, label.text == text { found.append(label) }
        }
        return found
    }

    @Test func unawareEnemiesCarryAQuestionMarkAndAlertedOnesDoNot() throws {
        // Without the Transit Patrol, whose three unaware members would add
        // their own markers on the first tick (PatrolConePresentationTests).
        var arena = try ArenaManifest.bundled()
        arena.patrols = []
        var sim = try Simulation(seed: 1, arena: arena, content: .bundled())
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 700, y: 300), awareness: .unaware)
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 760, y: 300), awareness: .unaware)
        sim.testing_spawnStandard(.autonomousInformant, at: VecI(x: 820, y: 300), awareness: .aware)
        let renderer = WorldRenderer()
        renderer.render(PresentationSnapshot(sim.state))
        let marks = Self.labels("?", in: renderer.root)
        #expect(marks.count == 2)
        #expect(marks.allSatisfy { $0.position.y > 300 }, "the marker sits above the actor")

        // Alert them all through surveillance: the markers go.
        sim.testing_setExposure(500)
        _ = sim.step(command: .neutral(tick: 1))
        renderer.render(PresentationSnapshot(sim.state))
        #expect(Self.labels("?", in: renderer.root).isEmpty)
    }

    @Test func enemyAlertedPopsAndTheReducedVariantIsStatic() throws {
        let sim = try Simulation.make(seed: 1)
        let snap = PresentationSnapshot(sim.state)
        for reduced in [false, true] {
            let scene = SKScene(size: CGSize(width: 896, height: 414))
            let camera = SKCameraNode()
            let world = SKNode()
            scene.addChild(world)
            scene.addChild(camera)
            let vfx = VFXRenderer()
            vfx.install(in: scene, camera: camera, worldRoot: world)
            vfx.settings = reduced ? .reduced : .standard
            let event = AuthoritativeEvent(
                tick: 1, phase: 5, type: .enemyAlerted, primary: snap.player.id,
                payload: ["entityId": .string(snap.player.id.decimalString), "cause": .string("sight")],
                insertion: 0
            )
            vfx.ingest(tick: 1, events: [event], snapshot: snap)
            #expect(vfx.drawnByRecipe["enemyAlerted"] == 1)
            let pops = Self.labels("!", in: vfx.worldLayer)
            #expect(pops.count == 1)
            #expect(pops.first?.hasActions() == !reduced, reduced ? "reduced must not animate" : "default pops")
        }
    }
}
