import SpriteKit
import SurveillanceCore

/// Draws the authoritative world projection into a SpriteKit layer tree.
///
/// Nodes are keyed and reused across frames. The previous implementation called
/// `removeAllChildren()` every tick, which reallocated the whole scene graph 60
/// times a second and made the transient-node budget in `plan.md` unmeasurable.
///
/// Nothing here reads back from nodes: geometry always flows one way, from
/// `PresentationSnapshot` to the renderer.
@MainActor
final class WorldRenderer {
    /// visual-language-001 sprite boxes.
    static func spriteBox(for role: String) -> CGSize {
        switch role {
        case "improperSearchDaemon": CGSize(width: 80, height: 80)
        case "algorithmicModerate": CGSize(width: 96, height: 96)
        default: CGSize(width: 64, height: 64)
        }
    }

    /// Draw order. Later layers sit on top.
    private enum Layer: Int, CaseIterable {
        case solids
        case extraction
        case cameraFields
        case telegraphs
        case mines
        case spawnSockets
        case actors
        case projectiles
        case markers
    }

    let root = SKNode()
    /// Admitted clip frames. Empty until assets are admitted, in which case
    /// every actor keeps its authored blockout.
    private let sprites = SpriteLibrary()
    /// Clip currently playing per actor key, so an animation is not restarted
    /// on every frame.
    private var activeClips: [String: String] = [:]
    private var layers: [Layer: SKNode] = [:]
    /// Live nodes by layer and stable key, so a key that disappears from the
    /// snapshot has its node removed rather than left on screen.
    private var nodes: [Layer: [String: SKNode]] = [:]
    private var seen: [Layer: Set<String>] = [:]
    /// Static solids are rebuilt only when the live solid set actually changes
    /// (a gate opening or closing), not every tick.
    private var solidSignature: Int?

    init() {
        for layer in Layer.allCases {
            let node = SKNode()
            node.zPosition = CGFloat(layer.rawValue)
            root.addChild(node)
            layers[layer] = node
            nodes[layer] = [:]
        }
    }

    func reset() {
        for layer in Layer.allCases {
            layers[layer]?.removeAllChildren()
            nodes[layer] = [:]
        }
        solidSignature = nil
        activeClips = [:]
    }

    /// Backed frames over the whole clip contract, for evidence reporting.
    var spriteCoverage: (backed: Int, total: Int) { sprites.coverage }

    /// Plays `clipId` on a sprite node, or returns false when the clip has no
    /// admitted art and the caller must fall back to the blockout.
    private func playClip(
        _ clipId: String,
        direction: String?,
        key: String,
        at position: CGPoint,
        boxWidth: CGFloat,
        boxHeight: CGFloat,
        layer: Layer
    ) -> Bool {
        guard sprites.isBacked(clipId: clipId, direction: direction) else { return false }
        let node = node(layer, "sprite-\(key)") { () -> SKSpriteNode in
            SKSpriteNode()
        }
        guard let sprite = node as? SKSpriteNode else { return false }
        sprite.size = CGSize(width: boxWidth, height: boxHeight)
        sprite.anchorPoint = sprites.anchorPoint(
            clipId: clipId,
            boxHeight: boxHeight,
            boxWidth: boxWidth
        )
        sprite.position = position

        let token = "\(clipId)|\(direction ?? "-")"
        if activeClips[key] != token {
            activeClips[key] = token
            sprite.removeAllActions()
            if let animation = sprites.animation(clipId: clipId, direction: direction) {
                sprite.run(animation)
            } else if let texture = sprites.firstTexture(clipId: clipId, direction: direction) {
                sprite.texture = texture
            }
        }
        return true
    }

    // MARK: - Node reuse

    /// Returns the node for `key`, creating it with `make` on first use.
    private func node(_ layer: Layer, _ key: String, make: () -> SKNode) -> SKNode {
        seen[layer, default: []].insert(key)
        if let existing = nodes[layer]?[key] { return existing }
        let created = make()
        nodes[layer]?[key] = created
        layers[layer]?.addChild(created)
        return created
    }

    private func beginLayer(_ layer: Layer) {
        seen[layer] = []
    }

    /// Removes nodes whose key was not emitted this frame.
    private func endLayer(_ layer: Layer) {
        let live = seen[layer] ?? []
        guard var existing = nodes[layer] else { return }
        for (key, node) in existing where !live.contains(key) {
            node.removeFromParent()
            existing.removeValue(forKey: key)
        }
        nodes[layer] = existing
    }

    // MARK: - Frame

    func render(_ snap: PresentationSnapshot) {
        renderSolids(snap)
        renderExtraction(snap)
        renderCameras(snap)
        renderTelegraphs(snap)
        renderMines(snap)
        renderSpawnSockets(snap)
        renderActors(snap)
        renderProjectiles(snap)
        renderMarkers(snap)
    }

    private func renderSolids(_ snap: PresentationSnapshot) {
        // Cheap change detector: solids are authored, so position and count
        // fully identify the live set.
        var signature = Hasher()
        signature.combine(snap.solids.count)
        for solid in snap.solids {
            signature.combine(solid.center.x)
            signature.combine(solid.center.y)
            signature.combine(solid.halfSize.x)
            signature.combine(solid.halfSize.y)
        }
        let value = signature.finalize()
        guard value != solidSignature else { return }
        solidSignature = value

        let layer = layers[.solids]
        layer?.removeAllChildren()
        nodes[.solids] = [:]
        for solid in snap.solids {
            let node = SKShapeNode(
                rectOf: CGSize(
                    width: CGFloat(solid.halfSize.x * 2),
                    height: CGFloat(solid.halfSize.y * 2)
                )
            )
            node.position = CGPoint(x: solid.center.x, y: solid.center.y)
            node.fillColor = Palette.solidFill
            node.strokeColor = Palette.solidStroke
            node.lineWidth = 2
            layer?.addChild(node)
        }
    }

    private func renderExtraction(_ snap: PresentationSnapshot) {
        beginLayer(.extraction)
        let zone = node(.extraction, "extraction") {
            SKShapeNode(
                rectOf: CGSize(
                    width: CGFloat(snap.extraction.halfSize.x * 2),
                    height: CGFloat(snap.extraction.halfSize.y * 2)
                )
            )
        }
        if let shape = zone as? SKShapeNode {
            shape.position = CGPoint(x: snap.extraction.center.x, y: snap.extraction.center.y)
            shape.fillColor = snap.extractionArmed ? Palette.extractionArmed : Palette.extractionLocked
            shape.strokeColor = Palette.extractionStroke
        }
        endLayer(.extraction)
    }

    private func renderCameras(_ snap: PresentationSnapshot) {
        beginLayer(.cameraFields)
        beginLayer(.actors)

        for camera in snap.cameras {
            let key = "camera-\(camera.id.raw)"
            let position = CGPoint(x: camera.x, y: camera.y)
            // clip-metadata-001 names the clip; CameraPresentation picked it.
            let drawn = playClip(
                camera.clipId,
                direction: nil,
                key: key,
                at: position,
                boxWidth: 64,
                boxHeight: 96,
                layer: .actors
            )
            if !drawn {
                let body = node(.actors, key) {
                    let shape = SKShapeNode(circleOfRadius: 12)
                    shape.strokeColor = .clear
                    return shape
                }
                body.position = position
                (body as? SKShapeNode)?.fillColor = Palette.cameraFill(camera.presentationState)
            }

            guard camera.fieldVisible else { continue }
            let fieldKey = "field-\(camera.id.raw)"
            let field = node(.cameraFields, fieldKey) { SKShapeNode() }
            if let shape = field as? SKShapeNode {
                shape.path = Geometry.conePath(
                    range: camera.range,
                    headingMilli: camera.headingMilli,
                    fieldAngleMilli: camera.fieldAngleMilli
                )
                shape.position = CGPoint(x: camera.x, y: camera.y)
                shape.fillColor = camera.detecting ? Palette.cameraFieldDetecting : Palette.cameraField
                shape.strokeColor = .clear
            }
        }

        if let field = snap.captainField {
            let node = node(.cameraFields, "captain-field") { SKShapeNode() }
            if let shape = node as? SKShapeNode {
                shape.path = Geometry.conePath(
                    range: field.range,
                    headingMilli: field.headingMilli,
                    fieldAngleMilli: field.fieldAngleMilli
                )
                shape.position = CGPoint(x: field.x, y: field.y)
                shape.fillColor = Palette.captainField
                shape.strokeColor = .clear
            }
        }
        endLayer(.cameraFields)
        // .actors is closed in renderActors, which also emits into it.
    }

    /// bosses.md telegraphs. Wind-up is carried by outline weight and fill so a
    /// Reduced Flash setting can drop the fill without losing the warning.
    private func renderTelegraphs(_ snap: PresentationSnapshot) {
        beginLayer(.telegraphs)
        for telegraph in snap.telegraphs {
            let shapeNode = node(.telegraphs, telegraph.key) { SKShapeNode() }
            guard let shape = shapeNode as? SKShapeNode else { continue }
            switch telegraph.kind {
            case .cone, .emitterField:
                shape.path = Geometry.conePath(
                    range: telegraph.rangeUnits,
                    headingMilli: telegraph.headingMilli,
                    fieldAngleMilli: telegraph.halfAngleMilli * 2
                )
            case .lane:
                shape.path = Geometry.lanePath(
                    range: telegraph.rangeUnits,
                    headingMilli: telegraph.headingMilli,
                    width: telegraph.widthUnits
                )
            }
            shape.position = CGPoint(x: telegraph.x, y: telegraph.y)
            // Fill deepens as the resolve approaches; the outline is always
            // present so the shape reads without relying on the flash.
            let progress = CGFloat(telegraph.progressPermille) / 1000
            shape.fillColor = Palette.telegraphFill(progress: progress, locked: telegraph.locked)
            shape.strokeColor = Palette.telegraphStroke
            shape.lineWidth = telegraph.locked ? 4 : 2
        }
        endLayer(.telegraphs)
    }

    private func renderMines(_ snap: PresentationSnapshot) {
        beginLayer(.mines)
        for mine in snap.mines {
            let mineNode = node(.mines, "mine-\(mine.id.raw)") {
                SKShapeNode(circleOfRadius: CGFloat(mine.radius))
            }
            mineNode.position = CGPoint(x: mine.x, y: mine.y)
            if let shape = mineNode as? SKShapeNode {
                shape.fillColor = mine.armed ? Palette.mineArmed : Palette.mineArming
                shape.strokeColor = Palette.mineStroke
                shape.lineWidth = mine.armed ? 3 : 1
            }
        }
        endLayer(.mines)
    }

    private func renderSpawnSockets(_ snap: PresentationSnapshot) {
        beginLayer(.spawnSockets)
        for (index, socket) in snap.spawnSockets.enumerated() {
            let dot = node(.spawnSockets, "socket-\(index)") {
                let shape = SKShapeNode(circleOfRadius: 3)
                shape.fillColor = Palette.spawnSocket
                shape.strokeColor = .clear
                return shape
            }
            dot.position = CGPoint(x: socket.x, y: socket.y)
        }
        endLayer(.spawnSockets)
    }

    private func renderActors(_ snap: PresentationSnapshot) {
        let playerPosition = CGPoint(x: snap.player.x, y: snap.player.y)
        // clip-metadata-001 sprite box for the Player.
        let playerDrawn = playClip(
            snap.playerClipId,
            direction: snap.playerDirection,
            key: "player",
            at: playerPosition,
            boxWidth: 64,
            boxHeight: 64,
            layer: .actors
        )
        if !playerDrawn {
            let player = node(.actors, "player") {
                let shape = SKShapeNode(path: Geometry.silhouettePath(snap.player.silhouette))
                shape.fillColor = Palette.playerFill
                shape.strokeColor = Palette.playerStroke
                shape.lineWidth = 2
                return shape
            }
            player.position = playerPosition
        }

        for enemy in snap.enemies {
            let key = "enemy-\(enemy.id.raw)"
            let position = CGPoint(x: enemy.x, y: enemy.y)
            let box = Self.spriteBox(for: enemy.role)
            let drawn = enemy.clipId.map {
                playClip(
                    $0,
                    direction: enemy.direction,
                    key: key,
                    at: position,
                    boxWidth: box.width,
                    boxHeight: box.height,
                    layer: .actors
                )
            } ?? false
            if !drawn {
                let body = node(.actors, key) {
                    let shape = SKShapeNode(path: Geometry.silhouettePath(enemy.silhouette))
                    shape.fillColor = Palette.enemyFill(enemy.role)
                    shape.strokeColor = Palette.enemyStroke
                    shape.lineWidth = 1
                    return shape
                }
                body.position = position
            }
        }
        endLayer(.actors)
    }

    /// combat-001 projectiles. Drawn from the authoritative swept segment so a
    /// fast bolt stays visible between ticks.
    private func renderProjectiles(_ snap: PresentationSnapshot) {
        beginLayer(.projectiles)
        for projectile in snap.projectiles {
            let key = "shot-\(projectile.id.raw)"
            let shotNode = node(.projectiles, key) {
                let shape = SKShapeNode(circleOfRadius: CGFloat(projectile.radius))
                shape.strokeColor = .clear
                return shape
            }
            shotNode.position = CGPoint(x: projectile.x, y: projectile.y)
            (shotNode as? SKShapeNode)?.fillColor =
                projectile.hostile ? Palette.hostileProjectile : Palette.playerProjectile

            let trailKey = "trail-\(projectile.id.raw)"
            let trailNode = node(.projectiles, trailKey) { SKShapeNode() }
            if let trail = trailNode as? SKShapeNode {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: projectile.previousX, y: projectile.previousY))
                path.addLine(to: CGPoint(x: projectile.x, y: projectile.y))
                trail.path = path
                trail.strokeColor = projectile.hostile
                    ? Palette.hostileProjectileTrail
                    : Palette.playerProjectileTrail
                trail.lineWidth = CGFloat(projectile.radius)
            }
        }
        endLayer(.projectiles)
    }

    private func renderMarkers(_ snap: PresentationSnapshot) {
        beginLayer(.markers)
        for (index, marker) in snap.queryMarkers.enumerated() {
            let ring = node(.markers, "query-\(marker.id.raw)-\(index)") {
                let shape = SKShapeNode(circleOfRadius: CGFloat(marker.radius))
                shape.fillColor = .clear
                shape.strokeColor = Palette.queryMarker
                shape.lineWidth = 2
                return shape
            }
            ring.position = CGPoint(x: marker.x, y: marker.y)
        }
        endLayer(.markers)
    }
}

/// Grayscale role palette. visual-language-001 owns the authored values; these
/// are the blockout stand-ins used until asset intake accepts final art.
enum Palette {
    static let solidFill = SKColor(white: 0.18, alpha: 1)
    static let solidStroke = SKColor(white: 0.32, alpha: 1)
    static let playerFill = SKColor(white: 0.92, alpha: 1)
    static let playerStroke = SKColor(white: 1, alpha: 0.7)
    static let enemyStroke = SKColor(white: 0.75, alpha: 0.8)
    static let extractionArmed = SKColor(red: 0.2, green: 0.45, blue: 0.35, alpha: 0.35)
    static let extractionLocked = SKColor(red: 0.2, green: 0.45, blue: 0.35, alpha: 0.12)
    static let extractionStroke = SKColor(white: 0.7, alpha: 0.6)
    static let cameraField = SKColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 0.12)
    static let cameraFieldDetecting = SKColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 0.28)
    static let captainField = SKColor(white: 0.75, alpha: 0.18)
    static let spawnSocket = SKColor(white: 0.45, alpha: 0.5)
    static let queryMarker = SKColor(white: 0.8, alpha: 0.7)
    static let playerProjectile = SKColor(white: 0.98, alpha: 1)
    static let playerProjectileTrail = SKColor(white: 0.85, alpha: 0.35)
    static let hostileProjectile = SKColor(red: 0.95, green: 0.45, blue: 0.30, alpha: 1)
    static let hostileProjectileTrail = SKColor(red: 0.95, green: 0.45, blue: 0.30, alpha: 0.30)
    static let mineArmed = SKColor(red: 0.85, green: 0.35, blue: 0.25, alpha: 0.35)
    static let mineArming = SKColor(white: 0.6, alpha: 0.15)
    static let mineStroke = SKColor(red: 0.9, green: 0.5, blue: 0.35, alpha: 0.8)
    static let telegraphStroke = SKColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 0.9)

    static func telegraphFill(progress: CGFloat, locked: Bool) -> SKColor {
        let alpha = locked ? 0.42 : 0.10 + 0.22 * progress
        return SKColor(red: 0.95, green: 0.45, blue: 0.25, alpha: alpha)
    }

    static func enemyFill(_ role: String) -> SKColor {
        switch role {
        case "algorithmicModerate": SKColor(white: 0.30, alpha: 1)
        case "improperSearchDaemon": SKColor(white: 0.42, alpha: 1)
        default: SKColor(white: 0.55, alpha: 1)
        }
    }

    static func cameraFill(_ state: CameraPresentationState) -> SKColor {
        switch state {
        case .operational: SKColor(white: 0.78, alpha: 1)
        case .damaged, .hit: SKColor(white: 0.55, alpha: 1)
        case .critical: SKColor(white: 0.38, alpha: 1)
        case .destroying, .fieldOff, .destroyed, .dormant: SKColor(white: 0.18, alpha: 1)
        }
    }
}

/// Path construction from authoritative milli-degree headings.
///
/// Authoritative headings are clockwise-positive — `Cordic.headingUnit(θ)` is
/// `(cos θ, −sin θ)` — while SpriteKit measures counter-clockwise. The sign
/// flips exactly once, here, so no call site has to remember it.
/// `ConeOrientationTests` pins the convention.
enum Geometry {
    static func radians(milliDegrees: Int) -> CGFloat {
        -CGFloat(milliDegrees) / 1000 * .pi / 180
    }

    /// An angular *width*, which has no direction and so never flips sign.
    static func spanRadians(milliDegrees: Int) -> CGFloat {
        CGFloat(milliDegrees) / 1000 * .pi / 180
    }

    static func conePath(range: Int, headingMilli: Int, fieldAngleMilli: Int) -> CGPath {
        let path = CGMutablePath()
        let half = spanRadians(milliDegrees: fieldAngleMilli) / 2
        let heading = radians(milliDegrees: headingMilli)
        path.move(to: .zero)
        path.addArc(
            center: .zero,
            radius: CGFloat(range),
            startAngle: heading - half,
            endAngle: heading + half,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    /// A straight corridor of `width`, origin at one end.
    static func lanePath(range: Int, headingMilli: Int, width: Int) -> CGPath {
        let heading = radians(milliDegrees: headingMilli)
        let halfWidth = CGFloat(width) / 2
        let dx = cos(heading)
        let dy = sin(heading)
        // Perpendicular offset.
        let px = -dy * halfWidth
        let py = dx * halfWidth
        let endX = dx * CGFloat(range)
        let endY = dy * CGFloat(range)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: px, y: py))
        path.addLine(to: CGPoint(x: endX + px, y: endY + py))
        path.addLine(to: CGPoint(x: endX - px, y: endY - py))
        path.addLine(to: CGPoint(x: -px, y: -py))
        path.closeSubpath()
        return path
    }

    static func silhouettePath(_ silhouette: ActorSilhouette) -> CGPath {
        let path = CGMutablePath()
        let points = silhouette.contour
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }
        path.closeSubpath()
        return path
    }
}
