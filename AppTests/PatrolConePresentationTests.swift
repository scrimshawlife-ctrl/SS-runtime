import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-091 on screen (animation.md § 8a): each unaware Transit Patrol member's
/// cone is drawn on the ground from the snapshot, clipped at solids, apart
/// from Camera fields and the Captain cone, removed on alert, and kept under
/// Reduced Motion.
@Suite(.serialized)
@MainActor
struct PatrolConePresentationTests {
    private static func shapes(in node: SKNode, where match: @escaping (SKShapeNode) -> Bool) -> [SKShapeNode] {
        var found: [SKShapeNode] = []
        node.enumerateChildNodes(withName: "//*") { child, _ in
            if let shape = child as? SKShapeNode, match(shape) { found.append(shape) }
        }
        return found
    }

    private static func cones(_ renderer: WorldRenderer) -> [SKShapeNode] {
        shapes(in: renderer.root) { $0.name == WorldRenderer.patrolConeName && $0.fillColor != .clear }
    }

    private static func edges(_ renderer: WorldRenderer) -> [SKShapeNode] {
        shapes(in: renderer.root) { $0.name == WorldRenderer.patrolEdgeName && $0.lineWidth > 0 }
    }

    @Test func everyUnawareMemberDrawsADashedConeUntilAlerted() throws {
        var sim = try Simulation.make(seed: 1)
        _ = sim.step(command: .neutral(tick: 1))
        let snap = PresentationSnapshot(sim.state)
        #expect(snap.patrolCones.count == 3)
        for reducedMotion in [false, true] {
            let renderer = WorldRenderer()
            renderer.render(snap, reducedMotion: reducedMotion)
            #expect(Self.cones(renderer).count == 3, "Reduced Motion \(reducedMotion) keeps the cone")
            #expect(Self.edges(renderer).count == 3)
        }
        // Distinct from a Camera field and the Captain cone.
        #expect(Palette.patrolCone != Palette.cameraField && Palette.patrolCone != Palette.captainField)

        let renderer = WorldRenderer()
        renderer.render(snap)
        sim.testing_setExposure(500)
        _ = sim.step(command: .neutral(tick: 2))
        let alerted = PresentationSnapshot(sim.state)
        #expect(alerted.patrolCones.isEmpty)
        renderer.render(alerted)
        #expect(Self.cones(renderer).isEmpty, "alerted members lose their cones")
        #expect(Self.edges(renderer).isEmpty)
    }

    /// The outline stops at a solid: a cone pointed at the transit kiosk
    /// ends at its face instead of passing through it.
    @Test func coneOutlineIsClippedAtSolids() throws {
        let sim = try Simulation.make(seed: 1)
        let kiosk = try #require(sim.state.arena.permanentSolids.first { $0.id == "solid-03-transit-kiosk" }).aabb
        let origin = VecI(x: kiosk.center.x, y: kiosk.minY - 100)
        let outline = PatrolConeProjection.outline(
            origin: origin,
            facing: VecI(x: 0, y: 1).asQ8,
            rangeUnits: 240,
            halfAngleMilli: 45_000,
            solids: [kiosk]
        )
        let middle = outline[1 + PatrolConeProjection.rays / 2]
        #expect(abs(middle.y - kiosk.minY) <= 1, "the centre ray stops at the kiosk face")
        let open = PatrolConeProjection.outline(
            origin: origin, facing: VecI(x: 0, y: 1).asQ8, rangeUnits: 240, halfAngleMilli: 45_000, solids: []
        )
        #expect(open[1 + PatrolConeProjection.rays / 2].y == origin.y + 240)
    }

    /// Presentation never writes: projecting and drawing leave the state as
    /// it was.
    @Test func drawingConesDoesNotTouchState() throws {
        var sim = try Simulation.make(seed: 1)
        _ = sim.step(command: .neutral(tick: 1))
        let before = sim.state
        WorldRenderer().render(PresentationSnapshot(sim.state))
        #expect(sim.state == before)
    }
}
