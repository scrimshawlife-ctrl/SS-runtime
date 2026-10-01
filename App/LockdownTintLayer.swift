import SpriteKit
import SurveillanceCore

/// D-094 Lockdown atmosphere (`animation.md` § 8b): while Lockdown is latched
/// the world takes a red tint at 6% that pulses to 10% once every 2 seconds,
/// steady at 6% under Reduced Flash or Reduced Motion.
///
/// World layer only: the node is a child of the camera at `zPosition`, above
/// the world and its world-space effects and below the screen-space effect
/// layer and the HUD, so no HUD element is ever tinted. It multiplies rather
/// than blends (`LockdownTint.multiplier`), so it can only darken: the
/// scene never brightens. It reads the snapshot's tick and detection state
/// and the local settings, and writes nothing back.
@MainActor
final class LockdownTintLayer {
    /// Above `WorldRenderer` layers and `VFXRenderer.worldZ`, below
    /// `VFXRenderer.screenZ` and the HUD (1000).
    static let zPosition: CGFloat = 800
    static let nodeName = "lockdown-tint"

    let node: SKSpriteNode

    init() {
        // Oversized so camera shake never exposes an untinted edge.
        node = SKSpriteNode(
            color: .white,
            size: CGSize(
                width: CGFloat(PresentationCamera.visibleWidth) * 1.4,
                height: CGFloat(PresentationCamera.visibleHeight) * 1.4
            )
        )
        node.name = Self.nodeName
        node.zPosition = Self.zPosition
        node.blendMode = .multiply
        node.colorBlendFactor = 1
        node.isHidden = true
    }

    /// The opacity drawn this frame, or nil while hidden. For tests.
    private(set) var opacity: Double?

    func update(_ snap: PresentationSnapshot, settings: PresentationVFXSettings) {
        opacity = LockdownTint.opacity(
            tick: snap.tick,
            detection: snap.detection,
            reducedFlash: settings.reducedFlash,
            reducedMotion: settings.reducedMotion
        )
        guard let opacity else {
            node.isHidden = true
            return
        }
        let multiplier = LockdownTint.multiplier(opacity: opacity)
        node.color = SKColor(red: multiplier.red, green: multiplier.green, blue: multiplier.blue, alpha: 1)
        node.isHidden = false
    }

    func reset() {
        opacity = nil
        node.isHidden = true
    }
}
