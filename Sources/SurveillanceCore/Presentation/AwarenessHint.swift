/// Presentation-only D-089 tutorial copy (`hud-tutorial.md` "First unaware
/// enemy on screen"). Derived from the snapshot; it never writes simulation
/// state and never enters the digest.
///
/// It shows once per run: the first time a snapshot has an unaware enemy
/// inside the visible viewport, for the tutorial card's maximum visual
/// duration. It is a tutorial hint, not a safety message, so the tutorial
/// setting hides it.
public struct AwarenessHintProjector: Equatable, Sendable {
    public static let copy = "UNSEEN ENEMIES HOLD • STRIKE FIRST FOR DOUBLE DAMAGE"

    /// `hud-tutorial.md`: each card's maximum visual duration.
    public static let visibleTicks: UInt64 = 300

    /// Top-left reference rectangle. The layout table does not place this
    /// copy; it takes the row under the heat caption's borrowed Boss
    /// Integrity slot, clear of the tutorial card, which it must not
    /// replace. It and the heat caption do not show together in practice:
    /// a wave has reinforcements only while `tracked` or above, and that
    /// state alerts every unaware enemy.
    public static let referenceRect = HUDRect(x: 422 - 180, y: 108, width: 360, height: 24)

    private var shownAt: UInt64?

    public init() {}

    public mutating func reset() {
        self = AwarenessHintProjector()
    }

    /// True when an unaware enemy lies inside the viewport the snapshot's
    /// presentation camera shows.
    public static func unawareEnemyOnScreen(_ snap: PresentationSnapshot) -> Bool {
        let halfWidth = PresentationCamera.visibleWidth / 2
        let halfHeight = PresentationCamera.visibleHeight / 2
        return snap.enemies.contains { enemy in
            enemy.unaware
                && abs(enemy.x - snap.camera.center.x) <= halfWidth
                && abs(enemy.y - snap.camera.center.y) <= halfHeight
        }
    }

    /// The copy to draw for `snap`, or nil.
    public mutating func project(_ snap: PresentationSnapshot) -> String? {
        if shownAt == nil, Self.unawareEnemyOnScreen(snap) {
            shownAt = snap.tick
        }
        guard let shownAt, snap.tick >= shownAt, snap.tick - shownAt < Self.visibleTicks else { return nil }
        return Self.copy
    }
}
