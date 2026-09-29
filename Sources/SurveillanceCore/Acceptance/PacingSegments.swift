/// `arena.md` § 5 (D-079, rescaled by D-090): the seven pacing segments of a
/// competent run, how each one starts, and its target window.
///
/// This is measurement, not authority. Nothing here reads or writes simulation
/// state; it turns a run's authoritative events and the Player's zone into
/// segment start times, so E-011 and G-005 can be checked against the table
/// instead of against a number someone remembered.
public enum PacingSegment: String, CaseIterable, Sendable {
    case spawnAlley, cameraCorridor, civicPlaza, pressureRoute, lockdownRing, captainCourt, extraction

    /// How a segment starts. Every boundary is an event except the Camera
    /// Corridor, which has none and starts when the Player first enters Z-02.
    public enum Start: Equatable, Sendable {
        case runStart
        case zoneEntry(String)
        case wave(encounterId: String)
        case event(EventType)
    }

    public var zoneId: String {
        switch self {
        case .spawnAlley: "Z-01"
        case .cameraCorridor: "Z-02"
        case .civicPlaza: "Z-03"
        case .pressureRoute: "Z-04"
        case .lockdownRing: "Z-05"
        case .captainCourt: "Z-06"
        case .extraction: "Z-07"
        }
    }

    public var start: Start {
        switch self {
        case .spawnAlley: .runStart
        case .cameraCorridor: .zoneEntry("Z-02")
        case .civicPlaza: .wave(encounterId: "M-A")
        case .pressureRoute: .wave(encounterId: "M-B")
        // D-090: the Lockdown Ring starts with M-C, the forced-Lockdown
        // fight in its own zone, and includes the elite.
        case .lockdownRing: .wave(encounterId: "M-C")
        case .captainCourt: .event(.bossActivated)
        case .extraction: .event(.extractionArmed)
        }
    }

    /// Target elapsed time in seconds, start to end, from the table as
    /// rescaled to the arena as built (D-090): the map crosses in about ten
    /// seconds, so the opening is short and the minutes come from the fights.
    public var targetSeconds: ClosedRange<Int> {
        switch self {
        case .spawnAlley: 0...10
        case .cameraCorridor: 10...40
        case .civicPlaza: 40...75
        case .pressureRoute: 75...120
        case .lockdownRing: 120...255
        case .captainCourt: 255...345
        case .extraction: 345...360
        }
    }

    /// Constitution Article I (1.2.0) and G-005: a competent complete run.
    public static let targetRunSeconds: ClosedRange<Int> = 300...480
}

/// Segment start ticks for one run, fed one tick at a time.
public struct PacingTimeline: Equatable, Sendable {
    public private(set) var starts: [PacingSegment: UInt64] = [.spawnAlley: 0]
    /// The tick of `runSucceeded`, when the run ended in success.
    public private(set) var endTick: UInt64?

    public init() {}

    /// Records the segments that started on `tick`. Only the first start of
    /// each segment counts, so a second wave in the same zone moves nothing.
    public mutating func observe(tick: UInt64, events: [AuthoritativeEvent], playerZone: String?) {
        for segment in PacingSegment.allCases where starts[segment] == nil {
            if begins(segment, events: events, playerZone: playerZone) { starts[segment] = tick }
        }
        if endTick == nil, events.contains(where: { $0.type == .runSucceeded }) { endTick = tick }
    }

    private func begins(_ segment: PacingSegment, events: [AuthoritativeEvent], playerZone: String?) -> Bool {
        switch segment.start {
        case .runStart:
            return true
        case .zoneEntry(let zone):
            return playerZone == zone
        case .wave(let encounter):
            return events.contains { event in
                guard event.type == .waveStarted, case .string(let id)? = event.payload["encounterId"] else { return false }
                return id == encounter
            }
        case .event(let type):
            return events.contains { $0.type == type }
        }
    }

    /// Seconds from run start to the segment's start, or nil if it never began.
    public func startSeconds(_ segment: PacingSegment) -> Double? {
        starts[segment].map { Double($0) / Double(SimulationClock.ticksPerSecond) }
    }

    /// Segments whose start fell outside their target window. Reported, never
    /// enforced: pacing is judged by playtests (T903/T904), not by this type.
    public var segmentsOffTarget: [PacingSegment] {
        PacingSegment.allCases.filter { segment in
            guard let seconds = startSeconds(segment) else { return true }
            return !segment.targetSeconds.contains(Int(seconds.rounded()))
        }
    }

    public var runWithinTarget: Bool? {
        endTick.map { PacingSegment.targetRunSeconds.contains(Int((Double($0) / Double(SimulationClock.ticksPerSecond)).rounded())) }
    }
}
