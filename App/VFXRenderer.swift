import SpriteKit
import SurveillanceCore

/// D-088: draws every `procedural-vfx-002` recipe, and owns hit-stop and
/// screen shake.
///
/// Before D-088 the core projected these recipes (`VFXProjector`) and nothing
/// drew them. This is the device layer for that projection, the way
/// `AudioEngine` is for `AudioProjector`: it reads authoritative events after
/// the simulation has stepped and never writes anything back.
///
/// - **Hit-stop.** `consumeHitStopFrame()` runs before the scene steps. On a
///   frozen frame the scene neither steps the simulation nor redraws the
///   world, and every world and effect action is paused. The simulation is a
///   pure function of its seed and tick-indexed commands, and a frozen frame
///   yields no tick and consumes no command, so the digest and receipt cannot
///   change (`GameFeelTests` proves it on a full piloted run).
/// - **Shake.** Applied to the world camera node only. The HUD is a child of
///   that node, so it stays put on screen; Camera fields and objective markers
///   move with the world they belong to. Off under Reduced Motion.
/// - **Pools.** `VFXPool` holds each recipe's `poolSize` and the catalog's
///   `maxConcurrentEmitters` across ticks; a node lives exactly as long as its
///   pool instance.
@MainActor
final class VFXRenderer {
    /// Effects in arena space, above every world layer.
    let worldLayer = SKNode()
    /// Effects in screen space (title cards, the Blackout dim, edge cues).
    /// Attached to the camera node beneath the HUD, which sits at 1000.
    let screenLayer = SKNode()

    static let worldZ: CGFloat = 20
    static let screenZ: CGFloat = 900

    var settings: PresentationVFXSettings = .standard

    private let catalog: ProceduralVFXCatalog?
    private var projector = VFXProjector()
    private var hitStop = HitStopClock()
    private var shake = ScreenShake()
    private var pool: VFXPool?
    /// Unfrozen presentation frames. Effect lifetimes are counted in these, so
    /// a hit-stop pauses an effect exactly as it pauses its actions.
    private var frame: UInt64 = 0
    private var nodes: [Int: SKNode] = [:]
    private var trails: [Int: Trail] = [:]
    /// Last drawn position of every actor and Camera, so an effect for an
    /// entity that has just left the snapshot (a defeated enemy) still lands
    /// where it was.
    private var knownPositions: [EntityID: CGPoint] = [:]
    private weak var worldRoot: SKNode?
    private var cameraBase: CGPoint = .zero
    private var frozen = false

    /// Presentations drawn so far this run, by recipe, for evidence logging.
    private(set) var drawnByRecipe: [String: Int] = [:]
    /// Called with each recipe as it is admitted (DEBUG evidence harness).
    var onAdmit: ((VFXPresentation) -> Void)?

    private struct Trail {
        var remaining: Int
        var every: Int
        var age: Int
        var reducedEchoPlaced: Bool
    }

    init(catalog: ProceduralVFXCatalog? = try? ProceduralVFXCatalog.bundled()) {
        self.catalog = catalog
        pool = catalog.map(VFXPool.init(catalog:))
        worldLayer.zPosition = Self.worldZ
        screenLayer.zPosition = Self.screenZ
    }

    /// `worldRoot` is paused with the effects during a hit-stop, so clip
    /// animations freeze on the impact frame too.
    func install(in scene: SKNode, camera: SKCameraNode, worldRoot: SKNode) {
        scene.addChild(worldLayer)
        camera.addChild(screenLayer)
        self.worldRoot = worldRoot
    }

    func reset() {
        worldLayer.removeAllChildren()
        screenLayer.removeAllChildren()
        nodes = [:]
        linked = [:]
        trails = [:]
        knownPositions = [:]
        projector.reset()
        hitStop.reset()
        shake.reset()
        pool?.reset()
        frame = 0
        drawnByRecipe = [:]
        setFrozen(false)
    }

    var liveEffectCount: Int { pool?.live.count ?? 0 }
    var frozenFrames: Int { hitStop.frozenFrames }
    var freezes: Int { hitStop.freezes }

    // MARK: - Frame

    /// Call once per display frame before stepping. True means this frame is
    /// a hit-stop frame: do not step and do not redraw the world.
    func consumeHitStopFrame() -> Bool {
        let isFrozen = hitStop.consumeFrame()
        setFrozen(isFrozen)
        return isFrozen
    }

    private func setFrozen(_ value: Bool) {
        guard frozen != value else { return }
        frozen = value
        worldLayer.isPaused = value
        screenLayer.isPaused = value
        worldRoot?.isPaused = value
    }

    /// The world camera's position for this frame: the follow position plus
    /// this frame's shake. Advances the shake one frame.
    func cameraPosition(base: CGPoint) -> CGPoint {
        cameraBase = base
        return shaken()
    }

    /// A frozen frame keeps the last follow position and keeps shaking.
    func frozenCameraPosition() -> CGPoint {
        shaken()
    }

    private func shaken() -> CGPoint {
        let offset = shake.advance()
        return CGPoint(x: cameraBase.x + offset.x, y: cameraBase.y + offset.y)
    }

    /// Projects one stepped tick. Call after `session.step()`, before redraw.
    ///
    /// `heatReinforcements` is the D-083 count granted to this tick's waves,
    /// from `HeatCaptionProjector.reinforcements`.
    func ingest(
        tick: UInt64,
        events: [AuthoritativeEvent],
        snapshot snap: PresentationSnapshot,
        heatReinforcements: Int = 0
    ) {
        guard let catalog, !events.isEmpty else { return }
        let projection = projector.project(
            tick: tick,
            events: events,
            catalog: catalog,
            settings: settings,
            context: VFXProjectionContext(
                cameraIds: snap.cameras.map(\.id),
                heatReinforcements: heatReinforcements
            )
        )
        guard !projection.presentations.isEmpty else { return }
        hitStop.admit(projection.presentations, catalog: catalog)
        shake.admit(projection.presentations, reducedMotion: settings.reducedMotion)
        guard var pool else { return }
        let admission = pool.admit(projection.presentations, frame: frame)
        self.pool = pool
        for sequence in admission.evicted { remove(sequence) }
        for instance in admission.admitted {
            draw(instance.presentation, events: events, snap: snap)
            drawnByRecipe[instance.presentation.recipeId, default: 0] += 1
            onAdmit?(instance.presentation)
        }
    }

    /// Per unfrozen frame, after the world is drawn: expire effects and run
    /// the ones that follow live state.
    func render(_ snap: PresentationSnapshot) {
        frame += 1
        if var pool {
            for sequence in pool.expire(frame: frame) { remove(sequence) }
            self.pool = pool
        }
        advanceTrails(snap)
        remember(snap)
    }

    private func remove(_ sequence: Int) {
        trails.removeValue(forKey: sequence)
        guard let node = nodes.removeValue(forKey: sequence) else { return }
        // A world node may own a screen-space part (a title card, the dim).
        linked.removeValue(forKey: ObjectIdentifier(node))?.removeFromParent()
        node.removeFromParent()
    }

    private func remember(_ snap: PresentationSnapshot) {
        knownPositions[snap.player.id] = CGPoint(x: snap.player.x, y: snap.player.y)
        for enemy in snap.enemies { knownPositions[enemy.id] = CGPoint(x: enemy.x, y: enemy.y) }
        for camera in snap.cameras { knownPositions[camera.id] = CGPoint(x: camera.x, y: camera.y) }
        for shot in snap.projectiles { knownPositions[shot.id] = CGPoint(x: shot.x, y: shot.y) }
    }

    private func position(of id: EntityID?, in snap: PresentationSnapshot) -> CGPoint? {
        guard let id else { return nil }
        if id == snap.player.id { return CGPoint(x: snap.player.x, y: snap.player.y) }
        if let enemy = snap.enemies.first(where: { $0.id == id }) { return CGPoint(x: enemy.x, y: enemy.y) }
        if let camera = snap.cameras.first(where: { $0.id == id }) { return CGPoint(x: camera.x, y: camera.y) }
        return knownPositions[id]
    }

    // MARK: - Recipes

    private func draw(_ p: VFXPresentation, events: [AuthoritativeEvent], snap: PresentationSnapshot) {
        let seconds = TimeInterval(p.lifetimeMs) / 1000
        let player = CGPoint(x: snap.player.x, y: snap.player.y)
        let source = position(of: p.sourceEntityId, in: snap)
        let node: SKNode
        switch p.recipeId {
        case "cameraAcquire":
            node = acquireReticle(at: player, seconds: seconds, reduced: p.reduced)
        case "exposureThreshold":
            node = edgeBrackets(seconds: seconds, reduced: p.reduced)
        case "playerHit":
            let from = payloadEntity(p.sourceEntityId, events: events, key: "sourceEntityId").flatMap { position(of: $0, in: snap) }
            node = impactArc(at: player, from: from, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "enemyHit":
            node = spark(at: source ?? player, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "enemyDefeat":
            node = burst(at: source ?? player, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "ghostStep":
            node = SKNode()
            trails[p.sequence] = Trail(
                remaining: max(1, p.particleCount),
                every: 3,
                age: 0,
                reducedEchoPlaced: false
            )
        case "ricochet":
            let hits = events.filter { $0.type == .projectileHit }.compactMap { event -> CGPoint? in
                position(of: payloadEntity(event.primaryEntityId, events: [event], key: "targetEntityId"), in: snap)
            }
            node = ricochetTrace(hits.isEmpty ? [source ?? player] : hits, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "lockdown":
            node = lockdownPulse(at: player, seconds: seconds, reduced: p.reduced)
        case "captainTelegraph":
            node = captainAnticipation(at: source ?? bossPosition(snap) ?? player, seconds: seconds, reduced: p.reduced)
        case "extraction":
            node = extractionBrackets(snap.extraction, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "cameraDestroyed":
            node = cameraShatter(at: source ?? player, particles: p.particleCount, seconds: seconds, reduced: p.reduced)
        case "networkBlackout":
            node = blackout(p, snap: snap, seconds: seconds)
        case "bossPhaseBreak":
            node = phaseBreak(p, at: source ?? bossPosition(snap), seconds: seconds)
        case "heatReinforcements":
            node = reinforcementChevrons(snap, seconds: seconds, reduced: p.reduced)
        default:
            return
        }
        if node.parent == nil { worldLayer.addChild(node) }
        nodes[p.sequence] = node
    }

    private func bossPosition(_ snap: PresentationSnapshot) -> CGPoint? {
        guard let boss = snap.boss else { return nil }
        return position(of: boss.id, in: snap)
    }

    private func payloadEntity(_ fallback: EntityID?, events: [AuthoritativeEvent], key: String) -> EntityID? {
        for event in events {
            if case .string(let raw)? = event.payload[key], let value = UInt64(raw) { return EntityID(value) }
        }
        return fallback
    }

    // MARK: Shapes

    /// Deterministic spread: the golden angle, so no two particles share a
    /// direction and no randomness is involved.
    private static func direction(_ index: Int, offset: CGFloat = 0) -> CGVector {
        let angle = CGFloat(index) * 2.399963 + offset
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private func dot(_ size: CGFloat, _ colour: SKColor) -> SKSpriteNode {
        SKSpriteNode(color: colour, size: CGSize(width: size, height: size))
    }

    private func brokenRing(radius: CGFloat, segments: Int, colour: SKColor, width: CGFloat) -> SKShapeNode {
        let path = CGMutablePath()
        let step = CGFloat.pi * 2 / CGFloat(segments)
        for index in 0..<segments {
            let start = CGFloat(index) * step
            path.addArc(center: .zero, radius: radius, startAngle: start, endAngle: start + step * 0.62, clockwise: false)
            path.move(to: CGPoint(x: radius * cos(start + step), y: radius * sin(start + step)))
        }
        let shape = SKShapeNode(path: path)
        shape.strokeColor = colour
        shape.lineWidth = width
        shape.lineCap = .round
        return shape
    }

    private func brackets(size: CGSize, arm: CGFloat, colour: SKColor, width: CGFloat) -> SKShapeNode {
        let path = CGMutablePath()
        let hx = size.width / 2
        let hy = size.height / 2
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            let corner = CGPoint(x: hx * sx, y: hy * sy)
            path.move(to: CGPoint(x: corner.x - arm * sx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y - arm * sy))
        }
        let shape = SKShapeNode(path: path)
        shape.strokeColor = colour
        shape.lineWidth = width
        return shape
    }

    private func fadeOut(after seconds: TimeInterval, over tail: TimeInterval) -> SKAction {
        .sequence([.wait(forDuration: max(0, seconds - tail)), .fadeOut(withDuration: tail)])
    }

    // cameraAcquire: contractingReticleAndShortScan / staticReticleAndOpacityStep
    private func acquireReticle(at point: CGPoint, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        let reticle = brackets(size: CGSize(width: 56, height: 56), arm: 12, colour: VFXPalette.watch, width: 2)
        root.addChild(reticle)
        if reduced {
            reticle.alpha = 0.9
            reticle.run(.sequence([.wait(forDuration: seconds * 0.6), .fadeAlpha(to: 0.4, duration: 0)]))
        } else {
            reticle.setScale(1.6)
            reticle.run(.scale(to: 1.0, duration: seconds * 0.7))
            let scan = SKSpriteNode(color: VFXPalette.watch.withAlphaComponent(0.6), size: CGSize(width: 52, height: 1.5))
            scan.position = CGPoint(x: 0, y: 26)
            scan.run(.moveTo(y: -26, duration: seconds))
            root.addChild(scan)
        }
        return root
    }

    // exposureThreshold: hudPulseAndEdgeBrackets / iconSwapAndShortHighlight
    private func edgeBrackets(seconds: TimeInterval, reduced: Bool) -> SKNode {
        let size = CGSize(width: CGFloat(PresentationCamera.visibleWidth) - 24, height: CGFloat(PresentationCamera.visibleHeight) - 24)
        let frame = brackets(size: size, arm: 34, colour: VFXPalette.warning, width: 3)
        screenLayer.addChild(frame)
        if reduced {
            frame.alpha = 1
            frame.run(.sequence([.wait(forDuration: seconds * 0.5), .fadeAlpha(to: 0.35, duration: 0)]))
        } else {
            frame.alpha = 0.25
            frame.run(.sequence([.fadeAlpha(to: 1, duration: seconds * 0.35), .fadeAlpha(to: 0, duration: seconds * 0.65)]))
        }
        return frame
    }

    // playerHit: oneToTwoFrameImpactAndDirectionalArc / directionalArcWithoutScreenFlash
    private func impactArc(at point: CGPoint, from: CGPoint?, particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        let facing: CGFloat = from.map { atan2($0.y - point.y, $0.x - point.x) } ?? .pi / 2
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: 24, startAngle: facing - 0.7, endAngle: facing + 0.7, clockwise: false)
        let arc = SKShapeNode(path: path)
        arc.strokeColor = VFXPalette.damage
        arc.lineWidth = 4
        arc.lineCap = .round
        arc.run(fadeOut(after: seconds, over: seconds * 0.5))
        root.addChild(arc)
        if !reduced {
            // One to two frames of impact: a ring around the Player, not a
            // full-screen flash.
            let ring = SKShapeNode(circleOfRadius: 18)
            ring.strokeColor = VFXPalette.impact
            ring.lineWidth = 3
            ring.run(.sequence([.wait(forDuration: 2.0 / 60), .removeFromParent()]))
            root.addChild(ring)
            for index in 0..<particles {
                let spread = CGFloat(index) - CGFloat(particles - 1) / 2
                let angle = facing + spread * 0.5
                let bit = dot(3, VFXPalette.damage)
                bit.position = CGPoint(x: 24 * cos(angle), y: 24 * sin(angle))
                bit.run(.group([
                    .moveBy(x: 14 * cos(angle), y: 14 * sin(angle), duration: seconds),
                    .fadeOut(withDuration: seconds)
                ]))
                root.addChild(bit)
            }
        }
        return root
    }

    // enemyHit: compactSpark / outlineChange
    private func spark(at point: CGPoint, particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        if reduced {
            let outline = SKShapeNode(circleOfRadius: 20)
            outline.strokeColor = VFXPalette.impact
            outline.lineWidth = 2
            root.addChild(outline)
            return root
        }
        for index in 0..<particles {
            let direction = Self.direction(index, offset: point.x * 0.01)
            let bit = dot(3, VFXPalette.impact)
            bit.run(.group([
                .moveBy(x: direction.dx * 16, y: direction.dy * 16, duration: seconds),
                .fadeOut(withDuration: seconds)
            ]))
            root.addChild(bit)
        }
        return root
    }

    // enemyDefeat: fourToEightParticles / dissolveOrTwoParticleCue
    private func burst(at point: CGPoint, particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        let reach: CGFloat = reduced ? 8 : 34
        for index in 0..<particles {
            let direction = Self.direction(index)
            let bit = dot(reduced ? 5 : 4, VFXPalette.debris)
            bit.run(.group([
                .moveBy(x: direction.dx * reach, y: direction.dy * reach, duration: seconds),
                .fadeOut(withDuration: seconds)
            ]))
            root.addChild(bit)
        }
        return root
    }

    // ghostStep: afterimageTrail / singleOutlineEcho — sampled from the live
    // Player position each frame, in advanceTrails.
    private func advanceTrails(_ snap: PresentationSnapshot) {
        for (sequence, var trail) in trails {
            guard let root = nodes[sequence], trail.remaining > 0 else { continue }
            let reducedEcho = settings.reducedMotion || settings.reducedFlash
            if trail.age % trail.every == 0 {
                let echo = SKShapeNode(path: Geometry.silhouettePath(snap.player.silhouette))
                echo.position = CGPoint(x: snap.player.x, y: snap.player.y)
                echo.strokeColor = VFXPalette.echo
                echo.lineWidth = 1.5
                if reducedEcho {
                    // One static outline, removed with its pool instance.
                    echo.fillColor = .clear
                    trail.remaining = 0
                } else {
                    echo.fillColor = VFXPalette.echo.withAlphaComponent(0.18)
                    echo.run(.fadeOut(withDuration: 0.25))
                    trail.remaining -= 1
                }
                root.addChild(echo)
            }
            trail.age += 1
            trails[sequence] = trail
        }
    }

    // ricochet: segmentedPathTrace / impactMarkersOnly
    private func ricochetTrace(_ points: [CGPoint], particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        if !reduced, points.count >= 2 {
            let path = CGMutablePath()
            path.addLines(between: points)
            let dashed = path.copy(dashingWithPhase: 0, lengths: [8, 6])
            let trace = SKShapeNode(path: dashed)
            trace.strokeColor = VFXPalette.pulse
            trace.lineWidth = 2
            trace.run(.fadeOut(withDuration: seconds))
            root.addChild(trace)
        }
        for (index, point) in points.prefix(max(1, particles)).enumerated() {
            let marker = SKShapeNode(path: {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -4, y: -4)); path.addLine(to: CGPoint(x: 4, y: 4))
                path.move(to: CGPoint(x: -4, y: 4)); path.addLine(to: CGPoint(x: 4, y: -4))
                return path
            }())
            marker.position = point
            marker.strokeColor = VFXPalette.pulse
            marker.lineWidth = 2
            if !reduced { marker.run(.sequence([.wait(forDuration: Double(index) * 0.03), .fadeOut(withDuration: seconds)])) }
            root.addChild(marker)
        }
        return root
    }

    // lockdown: oneControlledScenePulseAndBarriers / staticPerimeterChange
    private func lockdownPulse(at point: CGPoint, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let bars = SKNode()
        let w = CGFloat(PresentationCamera.visibleWidth)
        let h = CGFloat(PresentationCamera.visibleHeight)
        for rect in [
            CGRect(x: -w / 2, y: h / 2 - 6, width: w, height: 6),
            CGRect(x: -w / 2, y: -h / 2, width: w, height: 6),
            CGRect(x: -w / 2, y: -h / 2, width: 6, height: h),
            CGRect(x: w / 2 - 6, y: -h / 2, width: 6, height: h)
        ] {
            let bar = SKShapeNode(rect: rect)
            bar.fillColor = VFXPalette.lockdown
            bar.strokeColor = .clear
            bars.addChild(bar)
        }
        screenLayer.addChild(bars)
        let root = SKNode()
        root.addChild(SKNode()) // anchor so removal takes the bars too
        if reduced {
            bars.alpha = 1
        } else {
            bars.alpha = 0
            bars.run(.fadeIn(withDuration: seconds * 0.3))
            // One controlled pulse: a ring leaving the Player, never a flash.
            let ring = brokenRing(radius: 20, segments: 6, colour: VFXPalette.lockdown, width: 4)
            ring.position = point
            ring.run(.group([.scale(to: 12, duration: seconds), .fadeOut(withDuration: seconds)]))
            root.addChild(ring)
        }
        worldLayer.addChild(root)
        linked[ObjectIdentifier(root)] = bars
        return root
    }

    /// Screen-space nodes owned by a world node, removed with it.
    private var linked: [ObjectIdentifier: SKNode] = [:]

    // captainTelegraph: groundShapeAndBodyAnticipation / groundShapeAndPhaseIcon.
    // The ground shape is the telegraph WorldRenderer already draws.
    private func captainAnticipation(at point: CGPoint, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        if reduced {
            let icon = SKShapeNode(path: {
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: 10), CGPoint(x: 8, y: 0), CGPoint(x: 0, y: -10), CGPoint(x: -8, y: 0), CGPoint(x: 0, y: 10)])
                return path
            }())
            icon.position = CGPoint(x: 0, y: 70)
            icon.strokeColor = VFXPalette.captain
            icon.fillColor = VFXPalette.captain.withAlphaComponent(0.4)
            icon.lineWidth = 2
            root.addChild(icon)
        } else {
            let ring = SKShapeNode(circleOfRadius: 52)
            ring.strokeColor = VFXPalette.captain
            ring.lineWidth = 3
            ring.setScale(1.4)
            ring.run(.group([.scale(to: 1.0, duration: seconds), .fadeAlpha(to: 0.2, duration: seconds)]))
            root.addChild(ring)
        }
        return root
    }

    // extraction: inwardParticlesAndStableBrackets / bracketsAndProgressFill
    private func extractionBrackets(_ zone: AABB, particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        let center = CGPoint(x: zone.center.x, y: zone.center.y)
        let size = CGSize(width: zone.halfSize.x * 2, height: zone.halfSize.y * 2)
        root.position = center
        root.addChild(brackets(size: size, arm: 18, colour: VFXPalette.extraction, width: 3))
        if reduced {
            let fill = SKShapeNode(rectOf: size)
            fill.fillColor = VFXPalette.extraction.withAlphaComponent(0.15)
            fill.strokeColor = .clear
            fill.xScale = 0
            fill.run(.scaleX(to: 1, duration: seconds))
            root.addChild(fill)
        } else {
            for index in 0..<particles {
                let direction = Self.direction(index)
                let bit = dot(4, VFXPalette.extraction)
                bit.position = CGPoint(x: direction.dx * size.width / 2, y: direction.dy * size.height / 2)
                bit.run(.group([.move(to: .zero, duration: seconds), .fadeOut(withDuration: seconds)]))
                root.addChild(bit)
            }
        }
        return root
    }

    // cameraDestroyed: lensShatterAndSparkBurst / staticCrackAndFieldCut
    private func cameraShatter(at point: CGPoint, particles: Int, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        root.position = point
        if reduced {
            let crack = CGMutablePath()
            crack.move(to: CGPoint(x: -10, y: 9)); crack.addLine(to: CGPoint(x: -2, y: 1)); crack.addLine(to: CGPoint(x: -5, y: -4)); crack.addLine(to: CGPoint(x: 6, y: -11))
            crack.move(to: CGPoint(x: -2, y: 1)); crack.addLine(to: CGPoint(x: 9, y: 6))
            let lines = SKShapeNode(path: crack)
            lines.strokeColor = VFXPalette.shard
            lines.lineWidth = 2
            root.addChild(lines)
            // The field cut: a short bar across the dead lens.
            let cut = SKSpriteNode(color: VFXPalette.fieldCut, size: CGSize(width: 34, height: 3))
            cut.zRotation = -.pi / 5
            root.addChild(cut)
            return root
        }
        let ring = brokenRing(radius: 12, segments: 5, colour: VFXPalette.shard, width: 3)
        ring.run(.group([.scale(to: 3.4, duration: seconds), .fadeOut(withDuration: seconds)]))
        root.addChild(ring)
        // Lens shards: six small triangles thrown outward, spinning.
        for index in 0..<6 {
            let direction = Self.direction(index, offset: 0.4)
            let shard = SKShapeNode(path: {
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: 5), CGPoint(x: 3, y: -3), CGPoint(x: -3, y: -2), CGPoint(x: 0, y: 5)])
                return path
            }())
            shard.fillColor = VFXPalette.shard
            shard.strokeColor = .clear
            shard.run(.group([
                .moveBy(x: direction.dx * 46, y: direction.dy * 46, duration: seconds),
                .rotate(byAngle: .pi * 2, duration: seconds),
                fadeOut(after: seconds, over: seconds * 0.5)
            ]))
            root.addChild(shard)
        }
        // Sparks: the recipe's particle count, faster and farther than shards.
        for index in 0..<particles {
            let direction = Self.direction(index, offset: 1.1)
            let spark = dot(2.5, VFXPalette.spark)
            let reach = CGFloat(40 + (index % 3) * 14)
            spark.run(.group([
                .moveBy(x: direction.dx * reach, y: direction.dy * reach, duration: seconds * 0.8),
                .fadeOut(withDuration: seconds * 0.8)
            ]))
            root.addChild(spark)
        }
        return root
    }

    // networkBlackout: fieldsCascadeOffAndSceneDim / staticBlackoutBanner
    private func blackout(_ p: VFXPresentation, snap: PresentationSnapshot, seconds: TimeInterval) -> SKNode {
        let root = SKNode()
        let screen = SKNode()
        screenLayer.addChild(screen)
        linked[ObjectIdentifier(root)] = screen
        let title = SKLabelNode(fontNamed: "Menlo-Bold")
        title.text = p.label ?? VFXProjector.blackoutTitle
        title.fontSize = 34
        title.fontColor = VFXPalette.title
        title.verticalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: 40)
        if p.reduced {
            // Reduced Flash: no luminance change at all, only a static banner.
            let banner = SKShapeNode(rectOf: CGSize(width: 420, height: 52))
            banner.fillColor = VFXPalette.banner
            banner.strokeColor = VFXPalette.title
            banner.lineWidth = 1
            banner.position = title.position
            screen.addChild(banner)
            screen.addChild(title)
            return root
        }
        // The dim: a darkening overlay, never brighter than the scene. It
        // settles in, holds, and lifts back to the scene's own level.
        let dim = SKSpriteNode(
            color: .black,
            size: CGSize(width: CGFloat(PresentationCamera.visibleWidth) * 1.2, height: CGFloat(PresentationCamera.visibleHeight) * 1.2)
        )
        dim.alpha = 0
        dim.run(.sequence([
            .fadeAlpha(to: VFXPalette.blackoutDim, duration: seconds * 0.3),
            .wait(forDuration: seconds * 0.45),
            .fadeAlpha(to: 0, duration: seconds * 0.25)
        ]))
        screen.addChild(dim)
        title.alpha = 0
        title.setScale(1.25)
        title.run(.sequence([
            .group([.fadeIn(withDuration: 0.12), .scale(to: 1.0, duration: 0.12)]),
            .wait(forDuration: seconds * 0.6),
            .fadeOut(withDuration: seconds * 0.25)
        ]))
        screen.addChild(title)
        // Every Camera field, in stable-ID order, cuts off at its offset.
        for step in p.cascade {
            guard let camera = snap.cameras.first(where: { $0.id == step.cameraId }) else { continue }
            let field = SKShapeNode(path: Geometry.conePath(
                range: camera.range,
                headingMilli: camera.headingMilli,
                fieldAngleMilli: camera.fieldAngleMilli
            ))
            field.position = CGPoint(x: camera.x, y: camera.y)
            field.fillColor = VFXPalette.cascadeField
            field.strokeColor = VFXPalette.cascadeEdge
            field.lineWidth = 1.5
            field.run(.sequence([
                .wait(forDuration: TimeInterval(step.offsetMs) / 1000),
                .fadeAlpha(to: 0, duration: 0.06)
            ]))
            root.addChild(field)
        }
        return root
    }

    // bossPhaseBreak: phaseNameSlamAndRingRelease / phaseNameCutIn
    private func phaseBreak(_ p: VFXPresentation, at point: CGPoint?, seconds: TimeInterval) -> SKNode {
        let root = SKNode()
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = p.label
        label.fontSize = 30
        label.fontColor = VFXPalette.captain
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: 70)
        screenLayer.addChild(label)
        linked[ObjectIdentifier(root)] = label
        if p.reduced {
            label.alpha = 1
            return root
        }
        label.setScale(2.2)
        label.alpha = 0
        label.run(.sequence([
            .group([.scale(to: 1.0, duration: 0.09), .fadeIn(withDuration: 0.09)]),
            .wait(forDuration: seconds * 0.6),
            .fadeOut(withDuration: seconds * 0.3)
        ]))
        if let point {
            let ring = brokenRing(radius: 40, segments: 8, colour: VFXPalette.captain, width: 4)
            ring.position = point
            ring.run(.group([.scale(to: 5.5, duration: seconds), .fadeOut(withDuration: seconds)]))
            root.addChild(ring)
        }
        return root
    }

    // heatReinforcements: edgeChevronsTowardSpawnSockets / staticEdgeChevrons
    private func reinforcementChevrons(_ snap: PresentationSnapshot, seconds: TimeInterval, reduced: Bool) -> SKNode {
        let root = SKNode()
        let screen = SKNode()
        screenLayer.addChild(screen)
        linked[ObjectIdentifier(root)] = screen
        let halfW = CGFloat(PresentationCamera.visibleWidth) / 2 - 22
        let halfH = CGFloat(PresentationCamera.visibleHeight) / 2 - 22
        let center = CGPoint(x: snap.camera.center.x, y: snap.camera.center.y)
        for socket in snap.spawnSockets.prefix(6) {
            let dx = CGFloat(socket.x) - center.x
            let dy = CGFloat(socket.y) - center.y
            guard dx != 0 || dy != 0 else { continue }
            let scale = min(halfW / max(abs(dx), 0.001), halfH / max(abs(dy), 0.001), 1)
            let chevron = SKShapeNode(path: {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -8, y: 10)); path.addLine(to: CGPoint(x: 4, y: 0)); path.addLine(to: CGPoint(x: -8, y: -10))
                return path
            }())
            chevron.strokeColor = VFXPalette.warning
            chevron.lineWidth = 4
            chevron.zRotation = atan2(dy, dx)
            chevron.position = CGPoint(x: dx * scale, y: dy * scale)
            if !reduced {
                chevron.run(.repeat(.sequence([
                    .moveBy(x: 6 * cos(chevron.zRotation), y: 6 * sin(chevron.zRotation), duration: seconds / 4),
                    .moveBy(x: -6 * cos(chevron.zRotation), y: -6 * sin(chevron.zRotation), duration: seconds / 4)
                ]), count: 2))
            }
            screen.addChild(chevron)
        }
        return root
    }
}

/// Effect colours. Nothing here is white at full strength over the whole
/// screen: `forbidFullScreenWhiteFlash` holds, and the only full-screen node
/// (the Blackout dim) is black.
enum VFXPalette {
    static let watch = SKColor(red: 0.95, green: 0.78, blue: 0.20, alpha: 0.95)
    static let warning = SKColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 0.95)
    static let damage = SKColor(red: 0.95, green: 0.36, blue: 0.28, alpha: 1)
    static let impact = SKColor(white: 0.96, alpha: 0.9)
    static let debris = SKColor(white: 0.70, alpha: 0.9)
    static let echo = SKColor(red: 0.55, green: 0.85, blue: 0.95, alpha: 0.7)
    static let pulse = SKColor(white: 0.92, alpha: 0.85)
    static let lockdown = SKColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 0.55)
    static let captain = SKColor(red: 0.90, green: 0.88, blue: 0.80, alpha: 0.95)
    static let extraction = SKColor(red: 0.35, green: 0.85, blue: 0.60, alpha: 0.9)
    static let shard = SKColor(red: 0.70, green: 0.88, blue: 0.98, alpha: 1)
    static let spark = SKColor(red: 1.0, green: 0.80, blue: 0.35, alpha: 1)
    static let fieldCut = SKColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 0.8)
    static let cascadeField = SKColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 0.16)
    static let cascadeEdge = SKColor(red: 0.95, green: 0.75, blue: 0.15, alpha: 0.7)
    // Neutral white: gold is reserved for pickups (visual language), so the
    // Blackout title must not read as a reward colour.
    static let title = SKColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    static let banner = SKColor(white: 0.05, alpha: 0.85)
    /// Peak Blackout darkening. The overlay is black, so the scene only ever
    /// gets darker than it was.
    static let blackoutDim: CGFloat = 0.5
}
