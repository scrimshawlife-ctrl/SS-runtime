import Foundation
import Testing
@testable import SurveillanceCore

/// `run-shell.md` § 12 (D-095) acceptance vectors RS-018 to RS-023.
@Suite(.serialized)
struct MedalTests {
    // MARK: - Fixtures

    /// A finished successful run (T705's 302-tick vector): full Integrity, no
    /// Camera destroyed, well under 5:30.
    static let success: WorldState = {
        var sim = try! Simulation.make(seed: 1)
        _ = sim.testing_completeRunSuccess(upgrade: .signalJammer)
        precondition(sim.state.outcome == .success)
        return sim.state
    }()

    /// The state after the first tick, when the Transit Patrol exists.
    static let withPatrol: WorldState = {
        var sim = try! Simulation.make(seed: 1)
        sim.step(command: .neutral(tick: 1))
        return sim.state
    }()

    static var patrolMember: EntityID {
        withPatrol.enemies.filter { $0.patrol != nil }.map(\.id).min()!
    }

    static func event(_ type: EventType, tick: UInt64 = 10, primary: EntityID? = nil, payload: [String: CanonicalJSON] = [:]) -> AuthoritativeEvent {
        AuthoritativeEvent(tick: tick, phase: 5, type: type, primary: primary, payload: payload, insertion: 0)
    }

    static func wave(_ encounter: CombatAuthorityNode, tick: UInt64 = 10) -> AuthoritativeEvent {
        event(.waveStarted, tick: tick, payload: ["encounterId": .string(encounter.rawValue), "waveId": .string("w")])
    }

    static func detection(_ after: DetectionState, tick: UInt64 = 10) -> AuthoritativeEvent {
        event(.detectionStateChanged, tick: tick, payload: ["before": .string("hidden"), "after": .string(after.rawValue)])
    }

    static func alert(_ id: EntityID, tick: UInt64 = 10) -> AuthoritativeEvent {
        event(.enemyAlerted, tick: tick, primary: id, payload: ["entityId": .string(id.decimalString), "cause": .string("sight")])
    }

    static func medals(_ events: [[AuthoritativeEvent]], state: WorldState = success) -> [Medal] {
        var tracker = MedalTracker()
        tracker.notePatrol(withPatrol)
        for tick in events { tracker.ingest(tick) }
        return tracker.medals(for: state)
    }

    // MARK: - RS-018 GHOST

    /// D-101: `GHOST` reads the authoritative quiet-approach latch, so the
    /// events no longer decide it (RS-024 in `QuietApproachTests`).
    @Test func rs018BelowTrackedUntilMobCEarnsGhost() {
        var quiet = Self.success
        quiet.exposure.quietApproach = true
        #expect(Self.medals([[Self.detection(.observed)], [Self.wave(.mobA)], [Self.wave(.mobC)]], state: quiet).contains(.ghost))
    }

    @Test func trackedBeforeMobCLosesGhost() {
        var lost = Self.success
        lost.exposure.quietApproach = false
        #expect(!Self.medals([[Self.detection(.tracked)], [Self.wave(.mobC)]], state: lost).contains(.ghost))
    }

    // MARK: - RS-019 SHADOW

    @Test func rs019PatrolAlertedBeforeMobALosesShadow() {
        let earned = Self.medals([[Self.alert(Self.patrolMember)], [Self.wave(.mobA)]])
        #expect(!earned.contains(.shadow))
    }

    @Test func patrolAlertedAfterMobAKeepsShadow() {
        let earned = Self.medals([[Self.wave(.mobA)], [Self.alert(Self.patrolMember)]])
        #expect(earned.contains(.shadow))
    }

    @Test func aNonPatrolAlertKeepsShadow() {
        let other = EntityID(9_999)
        #expect(Self.medals([[Self.alert(other)]]).contains(.shadow))
    }

    // MARK: - RS-020 SURGICAL

    @Test func rs020SurgicalNeedsHalfIntegrity() {
        var state = Self.success
        #expect(state.player.maxIntegrity == 150)
        state.player.integrity = 74
        #expect(!Self.medals([], state: state).contains(.surgical))
        state.player.integrity = 75
        #expect(Self.medals([], state: state).contains(.surgical))
    }

    // MARK: - BLACKOUT and SWIFT

    @Test func blackoutNeedsNetworkBlackout() {
        var state = Self.success
        #expect(!Self.medals([], state: state).contains(.blackout))
        state.networkBlackout = true
        #expect(Self.medals([], state: state).contains(.blackout))
    }

    @Test func swiftIsUnderFiveThirty() {
        #expect(Self.medals([]).contains(.swift), "the 302-tick run")
        #expect(MedalTracker.swift(ticks: 19_799))
        #expect(!MedalTracker.swift(ticks: 19_800))
    }

    // MARK: - RS-021 failure

    @Test func rs021AFailedRunEarnsNothing() {
        var state = Self.success
        state.outcome = .failure
        #expect(Self.medals([[Self.wave(.mobA)], [Self.wave(.mobC)]], state: state).isEmpty)
        let card = RunCard(state: state, dateLabel: "2026-10-01", bestTicks: nil, medals: Medal.allCases, newMedals: Set(Medal.allCases))
        #expect(card.value(for: RunCard.medalsLabel) == nil)
        #expect(card.medals.isEmpty)
        #expect(!card.shareText.contains("MEDALS"))
    }

    /// D-100: a success that earned no medal shows no medal row either.
    @Test func aSuccessWithNoMedalsShowsNoRow() {
        let none = RunCard(state: Self.success, dateLabel: "2026-10-01", bestTicks: nil, medals: [], newMedals: [])
        #expect(none.value(for: RunCard.medalsLabel) == nil)
        #expect(!none.shareText.contains("MEDALS"))
        let one = RunCard(state: Self.success, dateLabel: "2026-10-01", bestTicks: nil, medals: [.swift], newMedals: [])
        #expect(one.value(for: RunCard.medalsLabel) == "SWIFT")
    }

    // MARK: - RS-022 replay

    /// A real piloted success, replayed from its commands: the medals the
    /// live presenter derived are the medals the replay derives.
    @Test func rs022AReplayEarnsTheSameMedals() throws {
        let run = try #require(FeelPassFixtures.pilotedSuccess, "no piloted success among the candidate seeds")
        let live = try #require(FeelPassFixtures.pilotedPresented).live
        #expect(live.state.outcome == .success)
        let replay = try MedalTracker.replayMedals(seed: run.seed, commands: run.commands)
        #expect(!live.medals.isEmpty)
        #expect(replay == live.medals)
    }

    // MARK: - RS-023 NEW

    @Test func rs023ASecondGhostTodayIsNotNew() {
        let identity = ReplayIdentity.current
        let first = MedalRecord.merging(nil, earned: [.ghost, .swift], seed: 7, identity: identity)
        #expect(first.new == [.ghost, .swift])
        let second = MedalRecord.merging(first.record, earned: [.ghost, .surgical], seed: 7, identity: identity)
        #expect(second.new == [.surgical])
        #expect(second.record.medals == [.ghost, .surgical, .swift])
        let card = RunCard(state: Self.success, dateLabel: nil, bestTicks: nil, medals: [.ghost, .surgical], newMedals: second.new)
        #expect(card.value(for: RunCard.medalsLabel) == "GHOST · SURGICAL NEW")
    }

    // MARK: - Storage, title, Share

    @Test func aNewDayOrAnotherIdentityStartsEmpty() {
        let identity = ReplayIdentity.current
        let stored = MedalRecord(identity: identity, seed: 7, medals: [.ghost])
        #expect(MedalRecord.earned(stored, seed: 7, identity: identity) == [.ghost])
        #expect(MedalRecord.earned(stored, seed: 8, identity: identity).isEmpty)
        let other = ReplayIdentity(
            rulesetVersion: "ss-rules-999",
            contentVersion: identity.contentVersion,
            arenaVersion: identity.arenaVersion,
            replaySchemaVersion: identity.replaySchemaVersion
        )
        #expect(MedalRecord.earned(stored, seed: 7, identity: other).isEmpty)
    }

    @Test func recordRoundTripsThroughJSON() throws {
        let record = MedalRecord(identity: .current, seed: 42, medals: [.swift, .ghost])
        let decoded = try JSONDecoder().decode(MedalRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.medals == [.ghost, .swift], "canonical order")
    }

    @Test func titleGoalsShowAllFiveByShape() {
        let goals = MedalGoal.goals(earned: [.shadow])
        #expect(goals.map(\.medal) == Medal.allCases)
        #expect(goals.filter(\.earned).map(\.medal) == [.shadow])
        #expect(Set(goals.map(\.glyph)).count == 2, "earned and not-earned differ in shape")
    }

    @Test func shareAppendsMedalNamesWithoutNewMarks() {
        let card = RunCard(state: Self.success, dateLabel: "2026-10-01", bestTicks: nil, medals: [.swift, .ghost], newMedals: [.ghost])
        let lines = card.shareText.split(separator: "\n").map(String.init)
        #expect(lines.last == "MEDALS GHOST SWIFT", "names only; NEW is a local mark")
        #expect(lines.filter { $0.hasPrefix("MEDALS") }.count == 1)
        #expect(card.value(for: RunCard.medalsLabel) == "GHOST NEW · SWIFT", "the card itself keeps NEW")
    }
}
