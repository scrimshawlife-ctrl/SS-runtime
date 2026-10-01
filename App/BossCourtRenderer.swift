import SpriteKit
import SurveillanceCore

/// D-096 phase presentation (bosses.md § Phase presentation): the Authority
/// Court's per-phase light and the countdown ring on every boss telegraph.
/// Presentation only: it reads the snapshot and the local settings and writes
/// nothing back.
///
/// **Court light.** A camera child at `lightZ`, above the world and its
/// world-space effects and below the screen-space effects and the HUD, so no
/// HUD element is lit. A small fragment shader blends the palette's centre
/// and edge multipliers radially, and the node multiplies the scene, so the
/// light can only tint or darken (`CourtLighting`). `CourtLightTracker`
/// crossfades it over 1 s at each phase change, in from no light when the
/// boss activates and back out when it falls.
///
/// **Countdown rings.** World-space circles centred on each boss telegraph's
/// origin, closing from `TelegraphRing.startRadius` to `endRadius` over the
/// telegraph's duration, drawn just above the telegraph shapes.
@MainActor
final class BossCourtRenderer {
    /// Just below `LockdownTintLayer.zPosition` (800); both multiply, so their
    /// order does not change the result.
    static let lightZ: CGFloat = 790
    static let lightNodeName = "court-light"
    static let ringLayerName = "telegraph-rings"
    static let ringPrefix = "telegraph-ring-"
    /// Just above `WorldRenderer.Layer.telegraphs`, below the mines.
    static let ringLayerZ = CGFloat(WorldRenderer.Layer.telegraphs.rawValue) + 0.5
    static let ringColour = SKColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)

    let lightNode: SKSpriteNode
    let ringLayer = SKNode()

    private var tracker = CourtLightTracker()
    private let centerUniform = SKUniform(name: "u_center", vectorFloat3: SIMD3<Float>(1, 1, 1))
    private let edgeUniform = SKUniform(name: "u_edge", vectorFloat3: SIMD3<Float>(1, 1, 1))
    private var rings: [String: SKShapeNode] = [:]

    /// The light drawn this frame. For tests.
    private(set) var palette: CourtPalette = .neutral
    /// The ring frames drawn this frame, by telegraph key. For tests.
    private(set) var ringFrames: [String: TelegraphRing.Frame] = [:]

    /// Radial blend: the centre multiplier inside, the edge multiplier at the
    /// visible corners. Opaque output, so the multiply blend applies the
    /// multiplier exactly.
    private static let shaderSource = """
    void main() {
        vec2 q = (v_tex_coord - vec2(0.5)) * 2.0;
        float r = length(q) * 0.70710678;
        float w = smoothstep(0.20, 0.72, r);
        gl_FragColor = vec4(mix(u_center, u_edge, w), 1.0);
    }
    """

    init() {
        // Oversized so camera shake never exposes an unlit edge.
        lightNode = SKSpriteNode(
            color: .white,
            size: CGSize(
                width: CGFloat(PresentationCamera.visibleWidth) * 1.4,
                height: CGFloat(PresentationCamera.visibleHeight) * 1.4
            )
        )
        lightNode.name = Self.lightNodeName
        lightNode.zPosition = Self.lightZ
        lightNode.blendMode = .multiply
        let shader = SKShader(source: Self.shaderSource)
        shader.uniforms = [centerUniform, edgeUniform]
        lightNode.shader = shader
        lightNode.isHidden = true
        ringLayer.name = Self.ringLayerName
        ringLayer.zPosition = Self.ringLayerZ
    }

    func update(_ snap: PresentationSnapshot, settings: PresentationVFXSettings) {
        updateLight(snap, settings: settings)
        updateRings(snap, settings: settings)
    }

    private func updateLight(_ snap: PresentationSnapshot, settings: PresentationVFXSettings) {
        palette = tracker.update(phase: snap.boss?.phase, tick: snap.tick, reducedFlash: settings.reducedFlash)
        guard palette != .neutral else {
            lightNode.isHidden = true
            return
        }
        centerUniform.vectorFloat3Value = Self.vector(palette.center)
        edgeUniform.vectorFloat3Value = Self.vector(palette.edge)
        lightNode.isHidden = false
    }

    private func updateRings(_ snap: PresentationSnapshot, settings: PresentationVFXSettings) {
        var frames: [String: TelegraphRing.Frame] = [:]
        for telegraph in snap.telegraphs where TelegraphRing.applies(to: telegraph, bossId: snap.boss?.id) {
            let frame = TelegraphRing.frame(
                remainingTicks: telegraph.remainingTicks,
                totalTicks: telegraph.totalTicks,
                reducedMotion: settings.reducedMotion
            )
            frames[telegraph.key] = frame
            let ring = rings[telegraph.key] ?? makeRing(key: telegraph.key)
            ring.path = CGPath(
                ellipseIn: CGRect(x: -frame.radius, y: -frame.radius, width: frame.radius * 2, height: frame.radius * 2),
                transform: nil
            )
            ring.position = CGPoint(x: telegraph.x, y: telegraph.y)
            ring.lineWidth = CGFloat(frame.lineWidth)
            ring.strokeColor = Self.ringColour.withAlphaComponent(CGFloat(frame.alpha))
        }
        for (key, ring) in rings where frames[key] == nil {
            ring.removeFromParent()
            rings.removeValue(forKey: key)
        }
        ringFrames = frames
    }

    private func makeRing(key: String) -> SKShapeNode {
        let ring = SKShapeNode()
        ring.name = Self.ringPrefix + key
        ring.fillColor = .clear
        ring.isAntialiased = true
        ringLayer.addChild(ring)
        rings[key] = ring
        return ring
    }

    func reset() {
        tracker.reset()
        palette = .neutral
        lightNode.isHidden = true
        for ring in rings.values { ring.removeFromParent() }
        rings.removeAll()
        ringFrames = [:]
    }

    private static func vector(_ m: CourtMultiplier) -> SIMD3<Float> {
        SIMD3<Float>(Float(m.red), Float(m.green), Float(m.blue))
    }
}
