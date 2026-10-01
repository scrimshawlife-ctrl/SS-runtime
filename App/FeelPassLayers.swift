import SpriteKit
import SurveillanceCore

// Feel pass 2 drawing (D-097, D-098, D-099). Presentation only: every node
// here is drawn from a snapshot or a presentation tracker and nothing is read
// back. Kept out of `WorldRenderer` so its layer list stays the one contract.

/// D-097 takedown ring: a grey wash that pulls the target's colour out, inside
/// a thin pale ring. Brief, and it never brightens the scene under Reduced
/// Flash; under Reduced Motion it does not expand.
@MainActor
enum TakedownRing {
    static let name = "takedown-ring"
    static let radius: CGFloat = 44
    static let seconds: TimeInterval = 0.35

    static func make(at point: CGPoint, settings: PresentationVFXSettings) -> SKNode {
        let node = SKNode()
        node.name = name
        node.position = point
        let wash = SKShapeNode(circleOfRadius: radius)
        wash.fillColor = SKColor(white: 0.5, alpha: 0.55)
        wash.strokeColor = .clear
        node.addChild(wash)
        let ring = SKShapeNode(circleOfRadius: radius)
        ring.fillColor = .clear
        ring.strokeColor = settings.reducedFlash ? SKColor(white: 0.62, alpha: 0.9) : SKColor(white: 0.92, alpha: 0.95)
        ring.lineWidth = 3
        node.addChild(ring)
        if settings.reducedMotion {
            node.setScale(1)
        } else {
            node.setScale(0.55)
            node.run(.scale(to: 1.15, duration: seconds))
        }
        node.run(.sequence([.fadeOut(withDuration: seconds), .removeFromParent()]))
        return node
    }
}

/// D-097 near miss: the patrol cone's edge brightens and pulses while the
/// Player is close to being seen; a steady bright edge under Reduced Motion.
/// Drawn just above the Camera field layer, where the cone itself is.
@MainActor
final class NearMissEdgeLayer {
    static let edgeName = "patrol-near-miss-edge"
    // The patrol cone's own blue, brightened: gold is reserved for pickups.
    static let edgeColour = SKColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1)

    let node = SKNode()
    private var edges: [EntityID: SKShapeNode] = [:]

    init() {
        node.zPosition = CGFloat(WorldRenderer.Layer.cameraFields.rawValue) + 0.5
    }

    func reset() {
        node.removeAllChildren()
        edges = [:]
    }

    /// Ids with a bright edge this frame (for tests and evidence).
    var litIds: [EntityID] { edges.keys.sorted() }

    func update(_ snap: PresentationSnapshot, nearMiss: [EntityID], frame: UInt64, reducedMotion: Bool) {
        let lit = Set(nearMiss)
        for (id, edge) in edges where !lit.contains(id) {
            edge.removeFromParent()
            edges.removeValue(forKey: id)
        }
        let intensity = CGFloat(PatrolNearMiss.edgeIntensity(frame: frame, reducedMotion: reducedMotion))
        for cone in snap.patrolCones where lit.contains(cone.id) {
            let edge = edges[cone.id] ?? {
                let shape = SKShapeNode()
                shape.name = Self.edgeName
                shape.fillColor = .clear
                shape.strokeColor = Self.edgeColour
                shape.glowWidth = 0
                node.addChild(shape)
                edges[cone.id] = shape
                return shape
            }()
            edge.path = Geometry.polygonPath(cone.outline)
            edge.lineWidth = 3
            edge.alpha = intensity
        }
    }
}

/// D-099 world grade: a ground-only overlay between the ground's dressing
/// and the low fog, so actors, telegraphs, Camera fields, and outlines are
/// never darkened (§ 10.3 limits).
@MainActor
final class DailyGradeLayer {
    static let name = "daily-grade"
    let node: SKSpriteNode = {
        let sprite = SKSpriteNode(color: .clear, size: .zero)
        sprite.name = name
        sprite.zPosition = CGFloat(WorldRenderer.Layer.decorations.rawValue) + 0.5
        return sprite
    }()
    private(set) var grade: DailyFlavour.Grade = .clear

    func apply(_ grade: DailyFlavour.Grade, arena: AABB) {
        self.grade = grade
        guard let overlay = DailyGradeOverlay.of(grade) else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        // One fog tile of margin, as the fog grid has, so camera shake never
        // shows an ungraded edge.
        let margin = CGFloat(WorldRenderer.fogTileUnits)
        node.size = CGSize(
            width: CGFloat(arena.halfSize.x * 2) + margin * 2,
            height: CGFloat(arena.halfSize.y * 2) + margin * 2
        )
        node.position = CGPoint(x: arena.center.x, y: arena.center.y)
        node.color = SKColor(red: overlay.red, green: overlay.green, blue: overlay.blue, alpha: 1)
        node.colorBlendFactor = 1
        node.alpha = overlay.alpha
        node.blendMode = overlay.multiply ? .multiply : .alpha
    }
}

/// D-098 intro beat in screen space: a dark veil over the world and the
/// title card, under the HUD.
@MainActor
final class IntroOverlay {
    static let titleName = "intro-title"
    let node = SKNode()
    private let veil = SKSpriteNode(color: .black, size: CGSize(width: 4000, height: 4000))
    private let title = SKLabelNode(fontNamed: "Menlo-Bold")
    private let subtitle = SKLabelNode(fontNamed: "Menlo")
    private let headline = SKLabelNode(fontNamed: "Menlo")

    init() {
        node.zPosition = 950
        veil.zPosition = 0
        node.addChild(veil)
        for (label, size, y) in [(title, CGFloat(26), CGFloat(18)), (subtitle, CGFloat(11), CGFloat(-10)), (headline, CGFloat(10), CGFloat(-28))] {
            label.fontSize = size
            label.fontColor = SKColor(white: 0.94, alpha: 1)
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.position = CGPoint(x: 0, y: y)
            label.zPosition = 1
            node.addChild(label)
        }
        title.name = Self.titleName
        title.text = IntroSequence.titleCopy
        node.isHidden = true
    }

    func update(_ intro: IntroSequence?, dailyLabel: String?, headline headlineText: String?) {
        guard let intro, !intro.isFinished else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        veil.alpha = CGFloat(intro.veilAlpha)
        let alpha = CGFloat(intro.titleAlpha)
        subtitle.text = dailyLabel ?? ""
        headline.text = headlineText ?? ""
        for label in [title, subtitle, headline] { label.alpha = alpha }
    }
}

/// D-099 fog density above 100%. A node's alpha stops at 1, so each fog tile
/// carries a second copy of itself whose alpha is the excess: a layer at
/// 120% draws the tile at full authored opacity plus the same tile at 20%.
/// Below 100% the copy is invisible and the layer alpha carries the density.
enum FogDensity {
    static let boostName = "fog-density-boost"

    static func split(density: CGFloat) -> (base: CGFloat, boost: CGFloat) {
        let clamped = max(0, density)
        return (min(1, clamped), max(0, clamped - 1))
    }

    @MainActor static func boostSprite(texture: SKTexture, size: CGSize) -> SKSpriteNode {
        let boost = SKSpriteNode(texture: texture, size: size)
        boost.name = boostName
        boost.alpha = 0
        return boost
    }
}
