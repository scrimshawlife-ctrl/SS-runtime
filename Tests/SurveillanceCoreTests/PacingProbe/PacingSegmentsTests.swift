import Testing
@testable import SurveillanceCore

/// `arena.md` § 5 as data (D-079). The table has to agree with the arena and
/// event contracts it names, and a real run has to produce its boundaries in
/// order, or E-011 would be measured against something the game never does.
@Suite(.serialized)
struct PacingSegmentsTests {
    @Test func windowsAreContiguousAndEndInsideTheRunTarget() {
        let windows = PacingSegment.allCases.map(\.targetSeconds)
        #expect(windows.first?.lowerBound == 0)
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(a.upperBound == b.lowerBound, "gap or overlap between \(a) and \(b)")
        }
        let end = windows.last!.upperBound
        #expect(PacingSegment.targetRunSeconds.contains(end), "table ends at \(end) s, outside 5-8 minutes")
        #expect(PacingSegment.targetRunSeconds == 300...480)
    }

    /// `arena.md` § 5 as rescaled by D-090 (SS-specs a9e023d): the windows,
    /// and the Lockdown Ring starting at the M-C wave, not `eliteActivated`.
    @Test func windowsMatchTheD090Table() {
        let expected: [PacingSegment: ClosedRange<Int>] = [
            .spawnAlley: 0...10, .cameraCorridor: 10...40, .civicPlaza: 40...75,
            .pressureRoute: 75...120, .lockdownRing: 120...255, .captainCourt: 255...345,
            .extraction: 345...360,
        ]
        for segment in PacingSegment.allCases {
            #expect(segment.targetSeconds == expected[segment], "\(segment)")
        }
        #expect(PacingSegment.lockdownRing.start == .wave(encounterId: "M-C"))
        #expect(PacingSegment.captainCourt.start == .event(.bossActivated))
        #expect(PacingSegment.extraction.targetSeconds.upperBound == 360, "the table ends at 6:00")

        var timeline = PacingTimeline()
        timeline.observe(
            tick: 7_300,
            events: [AuthoritativeEvent(tick: 0, phase: 15, type: .waveStarted, payload: ["encounterId": .string("M-C"), "waveId": .string("C1")], insertion: 0)],
            playerZone: "Z-05"
        )
        #expect(timeline.starts[.lockdownRing] == 7_300)
        timeline.observe(tick: 9_000, events: [AuthoritativeEvent(tick: 0, phase: 16, type: .eliteActivated, insertion: 0)], playerZone: "Z-05")
        #expect(timeline.starts[.lockdownRing] == 7_300, "eliteActivated no longer starts it")
    }

    @Test func everyBoundaryNamesSomethingTheContractsDefine() throws {
        let arena = try ArenaManifest.bundled()
        let zones = Set(arena.zones.map(\.id))
        let encounters = Set(arena.encounterTriggers.map(\.encounterId))
        for segment in PacingSegment.allCases {
            #expect(zones.contains(segment.zoneId), "\(segment) names zone \(segment.zoneId)")
            switch segment.start {
            case .runStart: break
            case .zoneEntry(let zone): #expect(zones.contains(zone))
            case .wave(let encounter): #expect(encounters.contains(encounter), "\(segment) waits for \(encounter)")
            case .event(let type): #expect(EventType.allCases.contains(type))
            }
        }
        // Zones run Z-01 to Z-07 in table order.
        #expect(PacingSegment.allCases.map(\.zoneId) == (1...7).map { "Z-0\($0)" })
    }

    @Test func onlyTheFirstStartCountsAndWavesAreKeyedByEncounter() {
        var timeline = PacingTimeline()
        func wave(_ id: String) -> AuthoritativeEvent {
            AuthoritativeEvent(tick: 0, phase: 14, type: .waveStarted, payload: ["encounterId": .string(id), "waveId": .string("w1")], insertion: 0)
        }
        timeline.observe(tick: 100, events: [], playerZone: "Z-02")
        timeline.observe(tick: 200, events: [wave("M-A")], playerZone: "Z-03")
        timeline.observe(tick: 300, events: [wave("M-A")], playerZone: "Z-03")
        #expect(timeline.starts[.cameraCorridor] == 100)
        #expect(timeline.starts[.civicPlaza] == 200)
        #expect(timeline.starts[.pressureRoute] == nil, "an M-A wave must not start the Pressure Route")
        timeline.observe(tick: 400, events: [wave("M-B")], playerZone: "Z-04")
        #expect(timeline.starts[.pressureRoute] == 400)
        #expect(timeline.endTick == nil)
        #expect(timeline.runWithinTarget == nil)
        timeline.observe(tick: 60 * 330, events: [AuthoritativeEvent(tick: 0, phase: 20, type: .runSucceeded, insertion: 0)], playerZone: "Z-07")
        #expect(timeline.runWithinTarget == true)
    }

    /// The piloted run reaches the boss; its segments start in table order.
    @Test func aPilotedRunProducesTheBoundariesInOrder() throws {
        let run = try #require(PacingProbeTests.pilotedRun)
        let starts = PacingSegment.allCases.compactMap { run.timeline.starts[$0] }
        #expect(starts == starts.sorted(), "segment starts out of order: \(run.timeline.starts)")
        for segment in [PacingSegment.spawnAlley, .cameraCorridor, .civicPlaza, .pressureRoute, .lockdownRing, .captainCourt] {
            #expect(run.timeline.starts[segment] != nil, "\(segment) never started")
        }
    }
}
