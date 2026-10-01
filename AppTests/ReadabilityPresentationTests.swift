import CoreGraphics
import SpriteKit
import SwiftUI
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-094 readability and finish pass on screen (`animation.md` § 8b): gates
/// draw as barriers and never as blockout, actors carry a shadow and a
/// faction outline, fog thins in a fight, Lockdown tints the world and never
/// the HUD, the HUD keeps its on-screen size at the tighter framing, and the
/// caption setting survives an old settings file.
@Suite(.serialized)
@MainActor
struct ReadabilityPresentationTests {
    private static func nodes(in root: SKNode, where match: @escaping (SKNode) -> Bool) -> [SKNode] {
        var found: [SKNode] = []
        root.enumerateChildNodes(withName: "//*") { node, _ in
            if match(node) { found.append(node) }
        }
        return found
    }

    // MARK: - Gates

    @Test func closedGatesDrawAsBarriersAndNeverAsBlockout() throws {
        let state = try Simulation.make(seed: 1).state
        let snap = PresentationSnapshot(state)
        let closed = state.gates.filter(\.closed)
        let open = state.gates.filter { !$0.closed }
        #expect(!closed.isEmpty && !open.isEmpty, "seed 1 starts with both kinds")

        let renderer = WorldRenderer()
        renderer.render(snap)
        for gate in closed {
            let barrier = renderer.root.childNode(withName: "//\(WorldRenderer.gateBarrierPrefix)\(gate.id)")
            #expect(barrier != nil, "\(gate.id) has a barrier")
            guard let barrier else { continue }
            let tiles = barrier.children.filter { $0.name == WorldRenderer.gateTileName }
            #expect(!tiles.isEmpty)
            // The art covers exactly the collision box.
            let frame = tiles.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let box = gate.box
            #expect(abs(frame.minX - CGFloat(box.minX)) < 0.01, "\(gate.id) minX")
            #expect(abs(frame.maxX - CGFloat(box.maxX)) < 0.01, "\(gate.id) maxX")
            #expect(abs(frame.minY - CGFloat(box.minY)) < 0.01, "\(gate.id) minY")
            #expect(abs(frame.maxY - CGFloat(box.maxY)) < 0.01, "\(gate.id) maxY")
            let area = tiles.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
            #expect(abs(area - CGFloat(box.halfSize.x * box.halfSize.y * 4)) < 0.5, "tiles do not overlap")
            // With art delivered, every tile is the barricade texture.
            #expect(tiles.allSatisfy { ($0 as? SKSpriteNode)?.texture != nil })
            // The warning-light strip, with its lights, inside the box.
            let strip = barrier.childNode(withName: WorldRenderer.gateStripName)
            #expect(strip != nil)
            if let strip {
                #expect(frame.contains(strip.frame.insetBy(dx: 0.01, dy: 0.01)))
                #expect(!strip.children.filter { $0.name == WorldRenderer.gateLightName }.isEmpty)
            }
        }
        for gate in open {
            #expect(renderer.root.childNode(withName: "//\(WorldRenderer.gateBarrierPrefix)\(gate.id)") == nil,
                    "an open gate draws nothing")
        }
        // No blockout rectangle stands where any closed gate is.
        let blockouts = Self.nodes(in: renderer.root) { node in
            guard let shape = node as? SKShapeNode else { return false }
            return shape.fillColor == Palette.solidFill
        }
        for gate in closed {
            let centre = CGPoint(x: gate.box.center.x, y: gate.box.center.y)
            #expect(!blockouts.contains { $0.frame.contains(centre) }, "\(gate.id) has no blockout")
        }
    }

    @Test func anOpeningGateLeavesNothingBehind() throws {
        let sim = try Simulation.make(seed: 1)
        let renderer = WorldRenderer()
        var snap = PresentationSnapshot(sim.state)
        renderer.render(snap)
        let gate = try #require(sim.state.gates.first { $0.closed })
        #expect(renderer.root.childNode(withName: "//\(WorldRenderer.gateBarrierPrefix)\(gate.id)") != nil)
        // Opening a gate takes it out of the live solids; that is all the
        // renderer sees of it.
        let index = try #require(snap.solidIds.firstIndex(of: gate.id))
        snap.solidIds.remove(at: index)
        snap.solids.remove(at: index)
        renderer.render(snap)
        #expect(renderer.root.childNode(withName: "//\(WorldRenderer.gateBarrierPrefix)\(gate.id)") == nil)
    }

    // MARK: - Actor contrast

    @Test func everyActorHasAShadowAndTheLayerSitsUnderActors() throws {
        var arena = try ArenaManifest.bundled()
        arena.patrols = []
        var sim = try Simulation(seed: 1, arena: arena, content: .bundled())
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: 700, y: 300), awareness: .aware)
        let snap = PresentationSnapshot(sim.state)
        let renderer = WorldRenderer()
        renderer.render(snap)
        let shadows = Self.nodes(in: renderer.root) { node in
            node.parent?.zPosition == CGFloat(WorldRenderer.Layer.actorShadows.rawValue)
        }
        #expect(shadows.count == 1 + snap.enemies.count)
        #expect(WorldRenderer.Layer.actorShadows.rawValue < WorldRenderer.Layer.actors.rawValue)
        #expect(WorldRenderer.Layer.actorShadows.rawValue > WorldRenderer.Layer.fogHigh.rawValue)
        let expected = ActorContrast.shadowSize(radius: snap.player.radius)
        // SpriteKit stores sizes as Float, so compare within a hair.
        #expect(shadows.contains { node in
            guard let size = (node as? SKSpriteNode)?.size else { return false }
            return abs(size.width - expected.width) < 0.01 && abs(size.height - expected.height) < 0.01
        })
    }

    @Test func outlinesAreAOnePixelRingUnbrokenForThePlayerAndDashedForEnemies() throws {
        // A 6 x 6 opaque square in a 10 x 10 frame.
        var pixels = [UInt8](repeating: 0, count: 10 * 10 * 4)
        for y in 2..<8 {
            for x in 2..<8 { pixels[(y * 10 + x) * 4 + 3] = 255 }
        }
        let source = try #require(OutlineTextures.texture(pixels: pixels, width: 10, height: 10, smooth: false))
        let player = try #require(OutlineTextures.make(from: source.cgImage(), faction: .player))
        let enemy = try #require(OutlineTextures.make(from: source.cgImage(), faction: .enemy))
        #expect(player.pad == 1 && enemy.pad == 1)

        func ring(_ entry: OutlineTextures.Entry) throws -> (on: Int, interior: Int, colour: (Int, Int, Int)) {
            let image = entry.texture.cgImage()
            let bytes = try #require(OutlineTextures.rgba(image))
            var on = 0
            var interior = 0
            var colour = (0, 0, 0)
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 0 {
                    // Source square is at 3...8 in the padded frame.
                    if (3..<9).contains(x), (3..<9).contains(y) { interior += 1 }
                    on += 1
                    let i = (y * image.width + x) * 4
                    colour = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
                }
            }
            return (on, interior, colour)
        }
        let p = try ring(player)
        let e = try ring(enemy)
        // An unbroken one-pixel ring round a 6 x 6 square is 8 x 8 - 6 x 6.
        #expect(p.on == 64 - 36)
        #expect(p.interior == 0, "the outline never covers the body")
        #expect(e.on > 0 && e.on < p.on, "the enemy ring is dashed")
        #expect(e.interior == 0)
        #expect(p.colour.2 >= p.colour.0, "Player: cool white")
        #expect(e.colour.0 > e.colour.1 && e.colour.1 > e.colour.2, "enemy: warm red-orange")
    }

    // MARK: - Fog

    @Test func fogLayersThinWhileAnAwareEnemyIsOnScreen() throws {
        var arena = try ArenaManifest.bundled()
        arena.patrols = []
        var sim = try Simulation(seed: 1, arena: arena, content: .bundled())
        let renderer = WorldRenderer()
        renderer.render(PresentationSnapshot(sim.state))
        #expect(renderer.fogThinning.opacity == 1)
        let player = VecI(x: sim.state.player.position.x.unitsTruncated, y: sim.state.player.position.y.unitsTruncated)
        sim.testing_spawnStandard(.fogAnalyticsCloud, at: VecI(x: player.x + 120, y: player.y), awareness: .aware)
        for tick in UInt64(1)...40 {
            var snap = PresentationSnapshot(sim.state)
            snap.tick = tick
            renderer.render(snap)
        }
        #expect(renderer.fogThinning.opacity == FogThinning.thinnedOpacity)
    }

    // MARK: - Lockdown tint

    @Test func lockdownTintsTheWorldAndNeverTheHUD() throws {
        let tint = LockdownTintLayer()
        #expect(tint.node.blendMode == .multiply, "multiplies, so it can only darken")
        #expect(LockdownTintLayer.zPosition > VFXRenderer.worldZ)
        #expect(LockdownTintLayer.zPosition > CGFloat(WorldRenderer.Layer.allCases.map(\.rawValue).max() ?? 0))
        #expect(LockdownTintLayer.zPosition < VFXRenderer.screenZ)
        #expect(LockdownTintLayer.zPosition < 1000, "the HUD root sits at 1000")

        var snap = PresentationSnapshot(try Simulation.make(seed: 1).state)
        tint.update(snap, settings: .standard)
        #expect(tint.node.isHidden && tint.opacity == nil, "no Lockdown, no tint")

        snap.detection = .lockdown
        snap.tick = 60
        tint.update(snap, settings: .standard)
        #expect(!tint.node.isHidden)
        #expect(abs((tint.opacity ?? 0) - LockdownTint.peakOpacity) < 1e-9)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.node.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r <= 1 && g <= 1 && b <= 1 && g < 1, "a red multiply")

        for settings in [PresentationVFXSettings(reducedMotion: false, reducedFlash: true),
                         PresentationVFXSettings(reducedMotion: true, reducedFlash: false)] {
            tint.update(snap, settings: settings)
            #expect(tint.opacity == LockdownTint.baseOpacity, "steady under the reduced variants")
        }
    }

    // MARK: - HUD at the D-094 framing

    @Test func theHUDKeepsItsOnScreenSize() {
        #expect(abs(HUDRenderer.framingScale - 704.0 / 896.0) < 1e-9)
        // A label authored at 10 scene units at 896 across draws 10 * 896/704
        // points larger per unit now; scaled, its on-screen size is unchanged.
        let view = CGSize(width: 874, height: 402)
        let before = min(view.width / 896, view.height / 414) * 10
        let after = min(view.width / 704, view.height / 326) * 10 * HUDRenderer.framingScale
        #expect(abs(before - after) / before < 0.02)
    }

    // MARK: - Caption setting

    @Test func anOldSettingsFileLoadsWithTheDefaultCaptionSetting() throws {
        let suite = "ss-readability-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PresentationSettings(handedness: .left))
        ) as! [String: Any]
        legacy.removeValue(forKey: "captions")
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "com.zer0state.surveillancesurvivor.presentationSettings"
        )
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.captions == .important)
        #expect(store.settings.handedness == .left, "the stored choice survives")

        store.settings.captions = .all
        #expect(SettingsStore(defaults: defaults).settings.captions == .all)
    }
}
