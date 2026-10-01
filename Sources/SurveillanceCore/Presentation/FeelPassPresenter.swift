import Foundation

/// The per-tick presentation state for medals (D-095) and feel pass 2
/// (D-097, D-098), fed by the app's session after every step.
///
/// It consumes the tick's published events, the enemy list before the step,
/// and the state after it. It owns no simulation and is never read by one:
/// `FeelPassPresentationOnlyTests` runs the same commands with and without it
/// and compares the digest and the receipt.
public struct FeelPassPresenter: Equatable, Sendable {
    public private(set) var medals = MedalTracker()
    public private(set) var takedowns = TakedownTracker()
    public private(set) var tutorial = TutorialLineQueue()
    public private(set) var encounterLabels = EncounterLabelGate()
    /// This tick's takedowns (D-097), by ascending ID.
    public private(set) var lastTakedowns: [EntityID] = []
    /// Patrol members whose cone edge is lit (D-097 near miss).
    public private(set) var nearMiss: [EntityID] = []
    /// The single tutorial line to draw (D-098), or nil.
    public private(set) var tutorialLine: String?
    /// The combat objective copy to draw (D-098), or nil before its
    /// encounter activates.
    public private(set) var objectiveCopy: String?

    public init() {}

    public mutating func reset() {
        self = FeelPassPresenter()
    }

    /// Before a step: learn the patrol (for `SHADOW`).
    public mutating func willStep(_ state: WorldState) {
        medals.notePatrol(state)
    }

    /// After a step.
    public mutating func didStep(events: [AuthoritativeEvent], enemiesBefore: [EnemyBody], state: WorldState) {
        medals.ingest(events)
        lastTakedowns = takedowns.ingest(events: events, before: enemiesBefore, after: state.enemies)
        observe(state)
    }

    /// Refreshes everything derived from the current state alone (also used
    /// once a debug scenario has rewritten the state).
    public mutating func observe(_ state: WorldState) {
        let snap = PresentationSnapshot(state)
        nearMiss = PatrolNearMiss.members(state)
        objectiveCopy = encounterLabels.project(snap, state: state)
        var hints: [String] = []
        if PatrolTutorial.coneOnScreen(snap) { hints.append(PatrolTutorial.copy) }
        if Self.unawareNonPatrolOnScreen(snap) { hints.append(AwarenessHintProjector.copy) }
        let card = snap.tutorialCopyIsSafetyMessage ? nil : snap.tutorialCopy
        let blocked = snap.upgradePending
            || snap.tutorialCopyIsSafetyMessage
            || encounterLabels.isFresh(snap.objectiveNode, tick: snap.tick)
        tutorialLine = tutorial.update(card: card, hints: hints, blocked: blocked)
    }

    /// The D-089 hint is about unaware enemies in general; a patrol member's
    /// cone has its own line, so the patrol alone does not raise this one.
    static func unawareNonPatrolOnScreen(_ snap: PresentationSnapshot) -> Bool {
        let patrol = Set(snap.patrolCones.map(\.id))
        return snap.enemies.contains { enemy in
            enemy.unaware && !patrol.contains(enemy.id)
                && PresentationCamera.contains(VecI(x: enemy.x, y: enemy.y), center: snap.camera.center)
        }
    }

    /// The tick's audio with the takedown's pitch and caption (D-097).
    public func decorate(_ audio: AudioProjection) -> AudioProjection {
        StealthTexture.decorate(audio, takedowns: lastTakedowns)
    }

    /// § 8c streak copy, or nil.
    public var streakCopy: String? { takedowns.hudCopy }

    /// The medals `state` earned (§ 12), empty unless it succeeded.
    public func earnedMedals(_ state: WorldState) -> [Medal] {
        medals.medals(for: state)
    }
}
