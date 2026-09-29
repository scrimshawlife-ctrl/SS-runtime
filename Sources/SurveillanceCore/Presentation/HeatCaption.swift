/// Presentation-only heat-reinforcement caption (D-083, `hud-tutorial.md`
/// "Wave with heat reinforcements"). Does not enter the digest and never
/// writes simulation state.
///
/// It is derived, not stored. A `waveStarted` event names the encounter, and
/// the Detection State the director read is the one resolved after the
/// previous tick: the `before` of this tick's first `detectionStateChanged`
/// event, or, when the state did not change this tick, the current state.
/// `content.heat` turns that into the count, exactly as the director does.
public struct HeatCaptionProjector: Equatable, Sendable {
    /// How long the caption stays up: the tutorial card's maximum visual
    /// duration, the only duration `hud-tutorial.md` gives a caption.
    public static let visibleTicks: UInt64 = 300

    /// Top-left reference rectangle. The layout table does not place this
    /// caption, so it borrows the Boss Integrity slot — (422, 82) top-centre,
    /// 360 × 24 — which is empty whenever an M-A or M-B wave can start: the
    /// boss bar shows only while the boss is active, after M-C.
    public static let referenceRect = HUDRect(x: 422 - 180, y: 82, width: 360, height: 24)

    private var copy: String?
    private var shownAt: UInt64?

    public init() {}

    public mutating func reset() {
        self = HeatCaptionProjector()
    }

    /// `REINFORCEMENTS +<n> • <STATE>`, or nil when a wave started with none.
    public static func copy(count: Int, state: DetectionState) -> String? {
        count > 0 ? "REINFORCEMENTS +\(count) • \(state.rawValue.uppercased())" : nil
    }

    /// The Detection State the encounter director read for a wave started in
    /// this tick.
    public static func stateAtWaveStart(events: [AuthoritativeEvent], current: DetectionState) -> DetectionState {
        let change = events.first { $0.type == .detectionStateChanged }
        if case .string(let before)? = change?.payload["before"], let state = DetectionState(rawValue: before) {
            return state
        }
        return current
    }

    /// The caption to draw after `events` were published at `tick`.
    public mutating func project(
        tick: UInt64,
        events: [AuthoritativeEvent],
        detection: DetectionState,
        heat: HeatSpec
    ) -> String? {
        for event in events where event.type == .waveStarted {
            guard case .string(let encounter)? = event.payload["encounterId"] else { continue }
            let state = Self.stateAtWaveStart(events: events, current: detection)
            let count = heat.reinforcements(encounter: encounter, state: state)
            // A wave with none clears an older caption: it no longer describes
            // the wave on screen.
            copy = Self.copy(count: count, state: state)
            shownAt = tick
        }
        guard let copy, let shownAt, tick >= shownAt, tick - shownAt < Self.visibleTicks else { return nil }
        return copy
    }
}
