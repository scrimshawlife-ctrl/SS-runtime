import Foundation

// D-098 opening and copy timing (`hud-tutorial.md` § Opening and copy
// timing). Presentation only: the intro runs before the first tick and
// produces none, and the queues below only choose which copy to draw.

/// The 2-second intro beat after Start.
///
/// The app counts display frames with `advance()` and does not step the
/// simulation until `isFinished`. No tick runs and no command is consumed, the
/// same principle as the upgrade gate freezing the clock, so the tick
/// sequence, the digest, and the receipt are exactly those of a run with no
/// intro, and replays (which never see the intro) are unaffected.
public struct IntroSequence: Equatable, Sendable {
    /// § Opening: 2 s in all.
    public static let totalFrames = 120
    /// The title card holds alone before the fields power on.
    public static let titleHoldFrames = 48
    /// § Opening: the eight fields power on over 1.2 s.
    public static let powerOnFrames = 72
    /// § Opening: Reduced Motion cuts the sequence to a single 0.5 s fade.
    public static let reducedMotionFrames = 30
    /// The title card copy.
    public static let titleCopy = "THE CIVIC SEAM"
    /// An existing short activation cue, reused as the power-up chirp.
    public static let chirpCueId = "extraction_tick"

    public let reducedMotion: Bool
    /// Cameras in stable-ID order, and the frame each powers on.
    public let powerOnSchedule: [(id: EntityID, frame: Int)]
    public private(set) var frame = 0
    public private(set) var skipped = false

    public init(cameraIds: [EntityID], reducedMotion: Bool) {
        self.reducedMotion = reducedMotion
        let ordered = cameraIds.sorted()
        let count = max(1, ordered.count)
        powerOnSchedule = ordered.enumerated().map { index, id in
            (id, reducedMotion ? 0 : Self.titleHoldFrames + index * Self.powerOnFrames / count)
        }
    }

    public static func == (lhs: IntroSequence, rhs: IntroSequence) -> Bool {
        lhs.reducedMotion == rhs.reducedMotion
            && lhs.frame == rhs.frame
            && lhs.skipped == rhs.skipped
            && lhs.powerOnSchedule.map(\.id) == rhs.powerOnSchedule.map(\.id)
            && lhs.powerOnSchedule.map(\.frame) == rhs.powerOnSchedule.map(\.frame)
    }

    public var durationFrames: Int { reducedMotion ? Self.reducedMotionFrames : Self.totalFrames }

    public var isFinished: Bool { skipped || frame >= durationFrames }

    /// Advances one display frame. Returns the Cameras that power on during
    /// this frame, in stable-ID order, each owed one chirp. Reduced Motion
    /// has no per-Camera beat, so it chirps never.
    public mutating func advance() -> [EntityID] {
        guard !isFinished else { return [] }
        let current = frame
        frame += 1
        guard !reducedMotion else { return [] }
        return powerOnSchedule.filter { $0.frame == current }.map(\.id)
    }

    /// § Opening: any touch skips it.
    public mutating func skip() {
        skipped = true
    }

    /// True once `id`'s field has powered on.
    public func isPowered(_ id: EntityID) -> Bool {
        if isFinished || reducedMotion { return true }
        return powerOnSchedule.first { $0.id == id }.map { frame > $0.frame } ?? true
    }

    /// Title card opacity: held, then fading as the fields come up. Under
    /// Reduced Motion it fades with the single fade.
    public var titleAlpha: Double {
        guard !isFinished else { return 0 }
        if reducedMotion { return 1 - Double(frame) / Double(Self.reducedMotionFrames) }
        if frame < Self.titleHoldFrames { return 1 }
        return 1 - Double(frame - Self.titleHoldFrames) / Double(Self.powerOnFrames)
    }

    /// A dark veil over the world. Under Reduced Motion this is the single
    /// fade; otherwise the arena is dimmed while the card holds and clears as
    /// the fields come up, so the fields read as lights in a dark city.
    public var veilAlpha: Double {
        guard !isFinished else { return 0 }
        if reducedMotion { return 0.85 * (1 - Double(frame) / Double(Self.reducedMotionFrames)) }
        if frame < Self.titleHoldFrames { return 0.55 }
        return 0.55 * (1 - Double(frame - Self.titleHoldFrames) / Double(Self.powerOnFrames))
    }
}

/// D-098 "One line at a time": a tutorial line appears when its subject is
/// first on screen, only one shows at a time, later lines queue, and a line
/// never overlaps the encounter label or the upgrade prompt.
public struct TutorialLineQueue: Equatable, Sendable {
    /// A one-shot hint (D-089 awareness, D-098 patrol) shows for the tutorial
    /// card's maximum visual duration once its turn comes.
    public static let latchedVisibleTicks = 300

    struct Line: Equatable, Sendable {
        var text: String
        /// True for a one-shot hint; false for the tutorial card, whose
        /// completion condition (in the simulation) withdraws it.
        var latched: Bool
        var shownTicks = 0
    }

    private(set) var lines: [Line] = []
    private var offered: Set<String> = []

    public init() {}

    public mutating func reset() {
        self = TutorialLineQueue()
    }

    /// Lines waiting or showing, front first. For tests and evidence.
    public var pending: [String] { lines.map(\.text) }

    /// One presented tick.
    ///
    /// - Parameters:
    ///   - card: the current tutorial card copy (not a safety message), or nil.
    ///   - hints: one-shot hints whose subject is on screen this tick.
    ///   - blocked: the encounter label or the upgrade prompt (or a safety
    ///     message in the card) is showing; the line waits and its time does
    ///     not run.
    /// - Returns: the one line to draw this tick, or nil.
    public mutating func update(card: String?, hints: [String], blocked: Bool) -> String? {
        // The card's own completion is authoritative: a card that is no longer
        // current leaves the queue, shown or not.
        lines.removeAll { !$0.latched && $0.text != card }
        if let card, !card.isEmpty, !offered.contains(card) {
            offered.insert(card)
            lines.append(Line(text: card, latched: false))
        }
        for hint in hints where !offered.contains(hint) {
            offered.insert(hint)
            lines.append(Line(text: hint, latched: true))
        }
        guard !blocked, !lines.isEmpty else { return nil }
        lines[0].shownTicks += 1
        let text = lines[0].text
        if lines[0].latched, lines[0].shownTicks >= Self.latchedVisibleTicks {
            lines.removeFirst()
        }
        return text
    }
}

/// D-098 patrol tutorial line (`hud-tutorial.md` copy table).
public enum PatrolTutorial {
    public static let copy = "PATROL • STAY OUT OF THE CONES • WALK PAST OR STRIKE"

    /// "First patrol cone on screen": a cone's origin is inside the view.
    public static func coneOnScreen(_ snap: PresentationSnapshot) -> Bool {
        snap.patrolCones.contains {
            PresentationCamera.contains(VecI(x: $0.x, y: $0.y), center: snap.camera.center)
        }
    }
}

/// D-098 "Encounter labels (`MOB ENCOUNTER A`) appear when that encounter
/// activates, not before", and take precedence over tutorial lines for a
/// short while after they appear.
public struct EncounterLabelGate: Equatable, Sendable {
    /// How long a newly shown label holds tutorial lines back: the caption
    /// stack's 2.5 s.
    public static let freshTicks: UInt64 = 150

    private var shownAt: [CombatAuthorityNode: UInt64] = [:]

    public init() {}

    public mutating func reset() {
        self = EncounterLabelGate()
    }

    /// True once `node`'s encounter has activated in `state`.
    public static func activated(_ node: CombatAuthorityNode, in state: WorldState) -> Bool {
        switch node {
        case .mobA, .mobB, .mobC:
            return state.encounters[node.rawValue]?.activated ?? false
        case .improperSearchDaemon:
            return state.eliteDefeated
                || state.enemies.contains { $0.archetype == .improperSearchDaemon }
        case .algorithmicModerate:
            return state.bossDefeated || state.bossRuntime != nil
        case .extraction:
            return true
        }
    }

    /// The objective copy to draw, or nil while the encounter it names has
    /// not activated. Extraction copy (locked or open) is not an encounter
    /// label and always shows.
    public mutating func project(_ snap: PresentationSnapshot, state: WorldState) -> String? {
        let copy = snap.combatObjectiveCopy
        let isEncounterLabel = copy != HUDLayout.lockedExtractionCopy
            && copy != HUDLayout.phoenixStepsOpenCopy
        guard isEncounterLabel else { return copy }
        guard Self.activated(snap.objectiveNode, in: state) else { return nil }
        if shownAt[snap.objectiveNode] == nil { shownAt[snap.objectiveNode] = snap.tick }
        return copy
    }

    /// True while the label for `node` appeared within `freshTicks`.
    public func isFresh(_ node: CombatAuthorityNode, tick: UInt64) -> Bool {
        guard let at = shownAt[node], tick >= at else { return false }
        return tick - at < Self.freshTicks
    }
}
