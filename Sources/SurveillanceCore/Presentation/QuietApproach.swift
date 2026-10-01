/// Presentation of the D-101 quiet approach (hud-tutorial.md § Exposure
/// presentation, UI-009 to UI-011). It reads the authoritative latch and
/// never writes simulation state, so the tag cannot disagree with the rule.
public struct QuietApproachProjector: Equatable, Sendable {
    public static let tagCopy = "QUIET"
    public static let lostCopy = "QUIET APPROACH LOST"
    public static func paidCopy(integrity: Int) -> String {
        "QUIET APPROACH • INTEGRITY \(integrity)"
    }

    /// VoiceOver text for the tag (sentence case, hud-tutorial.md § Exact copy).
    public static let tagAccessibilityLabel =
        "Quiet approach: reach the Lockdown Ring without being tracked for a stronger restore at the Authority Court."

    /// A caption's life: the 2.5 s caption time (D-094).
    public static let visibleTicks: UInt64 = 150

    /// The tag sits beside the state label under the Exposure bar: just
    /// right of `HUDLayout.detectionLabel` (top-left anchors, 422 + 180).
    public static let tagRect = HUDRect(x: 610, y: 54, width: 64, height: 24)

    /// The caption row: centred, between the boss bar (y 82) and the
    /// Extraction ring (y 134), which the layout table leaves empty, so it
    /// never covers the reinforcement line or the boss bar.
    public static let captionRect = HUDRect(x: 422 - 180, y: 108, width: 360, height: 22)

    public struct Frame: Equatable, Sendable {
        public var tagVisible: Bool
        public var caption: String?
    }

    /// The latch at the previous frame; nil before the first, which is a
    /// baseline and never announces a loss.
    private var wasQuiet: Bool?
    private var paid = false
    private var caption: String?
    private var shownAt: UInt64?

    public init() {}

    public mutating func reset() {
        self = QuietApproachProjector()
    }

    /// The tag and caption after `events` were published at `tick`.
    public mutating func project(tick: UInt64, events: [AuthoritativeEvent], state: WorldState) -> Frame {
        let quiet = state.exposure.quietApproach
        if wasQuiet == true && !quiet {
            caption = Self.lostCopy
            shownAt = tick
        }
        wasQuiet = quiet
        if events.contains(where: { $0.type == .bossActivated }) {
            paid = true
            if quiet {
                caption = Self.paidCopy(integrity: state.player.integrity)
                shownAt = tick
            }
        }
        let live = caption.flatMap { copy -> String? in
            guard let shownAt, tick >= shownAt, tick - shownAt < Self.visibleTicks else { return nil }
            return copy
        }
        return Frame(tagVisible: quiet && !paid, caption: live)
    }
}
