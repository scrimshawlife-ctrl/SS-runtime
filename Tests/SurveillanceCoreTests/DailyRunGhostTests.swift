import Foundation
import Testing
@testable import SurveillanceCore

/// `run-shell.md` § 10.1 (D-081): the Daily Run seed.
@Suite(.serialized)
struct DailyRunSeedTests {
    static let arena = try! ArenaManifest.bundled()

    /// `days` consecutive UTC dates starting at `start`.
    static func consecutiveDays(from start: DailyRun.Day, count: Int) -> [DailyRun.Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let origin = calendar.date(
            from: DateComponents(year: start.year, month: start.month, day: start.day, hour: 12)
        )!
        return (0..<count).map { offset in
            DailyRun.Day(utc: calendar.date(byAdding: .day, value: offset, to: origin)!)
        }
    }

    /// § 10.1 formula, pinned by values computed outside this codebase: the
    /// salt-0 candidates for 2026-09-28 (dayKey 20260928).
    @Test func candidateFollowsTheSpecFormulaExactly() {
        let day = DailyRun.Day(year: 2026, month: 9, day: 28)
        #expect(day.key == 20_260_928)
        #expect(DailyRun.domain == 0x5353_4441_494C_5900)
        #expect(DailyRun.candidate(day: day, salt: 0) == 13_735_295_873_638_081_999)
        #expect(DailyRun.candidate(day: day, salt: 1) == 11_746_400_761_706_288_722)
        #expect(DailyRun.candidate(day: day, salt: 2) == 10_499_510_668_317_580_731)
    }

    /// RS-013: the same UTC date yields the same seed, however many times and
    /// at whatever moment of that day it is derived.
    @Test func seedIsDeterministicForADate() throws {
        let early = DailyRun.Day(utc: Date(timeIntervalSince1970: 1_790_553_601)) // 2026-09-28T00:00:01Z
        let late = DailyRun.Day(utc: Date(timeIntervalSince1970: 1_790_639_999))  // 2026-09-28T23:59:59Z
        #expect(early == late)
        #expect(early.label == "2026-09-28")
        let a = DailyRun(day: early, arena: Self.arena)
        let b = DailyRun(day: late, arena: Self.arena)
        #expect(a == b)
        #expect(a.seed == DailyRun.candidate(day: early, salt: a.salt))
    }

    /// Midnight UTC is the boundary, not local midnight.
    @Test func dayRollsOverAtMidnightUTC() {
        let before = DailyRun.Day(utc: Date(timeIntervalSince1970: 1_790_639_999)) // 23:59:59Z
        let after = DailyRun.Day(utc: Date(timeIntervalSince1970: 1_790_640_000))  // 00:00:00Z
        #expect(before.label == "2026-09-28")
        #expect(after.label == "2026-09-29")
    }

    /// About 400 consecutive days: every seed is distinct, every seed is one
    /// `Simulation.make` accepts, and every rejected lower salt really was a
    /// placement failure — so the loop takes the *first* passing candidate.
    @Test func fourHundredDaysYieldDistinctLegalSeeds() throws {
        let days = Self.consecutiveDays(from: DailyRun.Day(year: 2026, month: 9, day: 1), count: 400)
        var seeds: Set<UInt64> = []
        var salted = 0
        for day in days {
            let run = DailyRun(day: day, arena: Self.arena)
            seeds.insert(run.seed)
            #expect(DailyRun.placementPasses(seed: run.seed, arena: Self.arena))
            #expect((try? Simulation.make(seed: run.seed)) != nil, "\(day.label) seed rejected by Simulation.make")
            if run.salt > 0 {
                salted += 1
                for salt in 0..<run.salt {
                    let rejected = DailyRun.candidate(day: day, salt: salt)
                    #expect(!DailyRun.placementPasses(seed: rejected, arena: Self.arena))
                    #expect((try? Simulation.make(seed: rejected)) == nil)
                }
            }
        }
        #expect(Set(days).count == 400)
        #expect(seeds.count == 400)
        print("DAILY-RUN-400 distinct=\(seeds.count) salted=\(salted)")
    }

    /// No day in the 400 above needs a salt, so the loop is proven here: the
    /// seed is the first candidate, in salt order, that placement accepts.
    @Test func saltLoopTakesTheFirstPassingCandidate() {
        let day = DailyRun.Day(year: 2026, month: 9, day: 28)
        let rejected: Set<UInt64> = [
            DailyRun.candidate(day: day, salt: 0),
            DailyRun.candidate(day: day, salt: 1),
        ]
        var tried: [UInt64] = []
        let run = DailyRun(day: day) { candidate in
            tried.append(candidate)
            return !rejected.contains(candidate)
        }
        #expect(run.salt == 2)
        #expect(run.seed == DailyRun.candidate(day: day, salt: 2))
        #expect(tried == (0...2).map { DailyRun.candidate(day: day, salt: $0) })
    }

    @Test func labelFormat() {
        #expect(DailyRun.Day(year: 2026, month: 9, day: 28).label == "2026-09-28")
        #expect(DailyRun.Day(year: 2027, month: 1, day: 5).label == "2027-01-05")
        #expect(DailyRun.titleLabel(for: DailyRun.Day(year: 2026, month: 12, day: 31)) == "DAILY RUN · 2026-12-31")
        let run = DailyRun(day: DailyRun.Day(year: 2026, month: 9, day: 28), arena: Self.arena)
        #expect(run.titleLabel == "DAILY RUN · 2026-09-28")
    }
}

/// `run-shell.md` § 10.2 (D-081): the ghost.
@Suite(.serialized)
struct GhostRunTests {
    static let seed = DailyRun(day: DailyRun.Day(year: 2026, month: 9, day: 28), arena: DailyRunSeedTests.arena).seed
    static let ticks: UInt64 = 360

    /// A deterministic, moving command stream: the Player changes position
    /// most ticks, so a one-tick offset is visible in position.
    static func commands(count: UInt64, phase: UInt64 = 0) -> [PlayerCommand] {
        (1...count).map { tick in
            let t = tick + phase
            return PlayerCommand(
                tick: tick,
                moveX: (t / 45) % 2 == 0 ? 24_000 : -24_000,
                moveY: (t / 70) % 2 == 0 ? 16_000 : -16_000,
                dodgePressed: t % 97 == 0
            )
        }
    }

    static func play(seed: UInt64, commands: [PlayerCommand]) throws -> Simulation {
        var sim = try Simulation.make(seed: seed)
        for command in commands { sim.step(command: command) }
        return sim
    }

    static let recorded: (record: GhostRecord, commands: [PlayerCommand]) = {
        let commands = GhostRunTests.commands(count: ticks)
        let sim = try! play(seed: seed, commands: commands)
        let record = GhostRecord(
            identity: .current,
            seed: seed,
            ticks: sim.state.tick,
            digest: sim.state.digest(),
            commands: commands
        )
        return (record, commands)
    }()

    /// Counts ticks at which the ghost's Player stands somewhere other than a
    /// live replay of the same commands does, advancing the ghost exactly as
    /// the App does: after each live step, to the live tick.
    static func lockstepMismatches(_ ghost: inout GhostRun, commands: [PlayerCommand], seed: UInt64) throws -> Int {
        var live = try Simulation.make(seed: seed)
        var mismatches = 0
        for command in commands {
            live.step(command: command)
            ghost.advance(to: live.state.tick)
            let expected = VecI(
                x: live.state.player.position.x.unitsTruncated,
                y: live.state.player.position.y.unitsTruncated
            )
            if ghost.playerPosition != expected || ghost.tick != live.state.tick { mismatches += 1 }
        }
        return mismatches
    }

    @Test func aVerifiedRecordBuildsAGhost() {
        #expect(Self.recorded.record.ticks == Self.ticks)
        #expect(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed) != nil)
    }

    /// RS-015 / § 10.2: a different Replay Identity is discarded.
    @Test func identityMismatchIsRejected() {
        for field in 0..<4 {
            var record = Self.recorded.record
            switch field {
            case 0: record.rulesetVersion = "ss-rules-000"
            case 1: record.contentVersion = "civic-seam-content-000"
            case 2: record.arenaVersion = "civic-seam-arena-000"
            default: record.replaySchemaVersion = "runtime-kernel-000"
            }
            #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
        }
        let other = ReplayIdentity(
            rulesetVersion: "ss-rules-002",
            contentVersion: ContractVersions.content,
            arenaVersion: ContractVersions.arena,
            replaySchemaVersion: ContractVersions.replaySchema
        )
        #expect(GhostRun(record: Self.recorded.record, liveIdentity: other, liveSeed: Self.seed) == nil)
    }

    @Test func aRecordFromAnotherSeedIsRejected() {
        #expect(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed &+ 1) == nil)
    }

    /// § 10.2: a replay that does not reproduce its stored digest is discarded.
    @Test func tamperedCommandIsRejected() {
        var record = Self.recorded.record
        let index = record.commands.count / 2
        record.commands[index].x = record.commands[index].x == 24_000 ? -24_000 : 24_000
        #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
    }

    @Test func tamperedDigestIsRejected() {
        var record = Self.recorded.record
        let flipped: Character = record.digest.first == "0" ? "1" : "0"
        record.digest = String(flipped) + record.digest.dropFirst()
        #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
    }

    @Test func tamperedTicksAreRejected() {
        var record = Self.recorded.record
        record.ticks += 1
        #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
        record.ticks -= 2
        #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
    }

    @Test func outOfOrderCommandsAreRejected() {
        var record = Self.recorded.record
        record.commands.swapAt(3, 4)
        #expect(GhostRun(record: record, liveIdentity: .current, liveSeed: Self.seed) == nil)
    }

    /// A stored file survives JSON, and neutral commands are left out of it.
    @Test func recordRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.recorded.record)
        let decoded = try JSONDecoder().decode(GhostRecord.self, from: data)
        #expect(decoded == Self.recorded.record)
        #expect(GhostRun(record: decoded, liveIdentity: .current, liveSeed: Self.seed) != nil)

        let sparse = GhostRecord(
            identity: .current, seed: 1, ticks: 3, digest: "",
            commands: [.neutral(tick: 1), PlayerCommand(tick: 2, moveX: 1, moveY: 0, dodgePressed: false), .neutral(tick: 3)]
        )
        #expect(sparse.commands.map(\.t) == [2])
    }

    /// § 10.2: one ghost tick for each live tick. Its Player stands exactly
    /// where a live replay of the same commands stands, every tick.
    @Test func lockstepMatchesALiveReplay() throws {
        var ghost = try #require(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed))
        #expect(ghost.tick == 0)
        #expect(try Self.lockstepMismatches(&ghost, commands: Self.recorded.commands, seed: Self.seed) == 0)
        #expect(ghost.finished)
        #expect(ghost.tick == Self.ticks)
    }

    /// Mutation check: a ghost that runs one tick ahead must fail the lockstep
    /// comparison the test above relies on. If this ever passes with zero
    /// mismatches, that test has gone inert.
    @Test func aGhostOneTickEarlyFailsTheLockstepCheck() throws {
        var early = try #require(
            GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed, lead: 1)
        )
        #expect(try Self.lockstepMismatches(&early, commands: Self.recorded.commands, seed: Self.seed) > 0)
    }

    /// § 10.2: the ghost stops at its own terminal tick.
    @Test func ghostStopsAtItsTerminalTick() throws {
        var ghost = try #require(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed))
        ghost.advance(to: Self.ticks + 500)
        #expect(ghost.tick == Self.ticks)
        #expect(ghost.finished)
        let resting = ghost.playerPosition
        ghost.advance(to: Self.ticks + 900)
        #expect(ghost.playerPosition == resting)
    }

    /// § 10.2 "fades out": full while running, then to zero; at once with
    /// Reduced Motion.
    @Test func ghostFadesAfterItsTerminalTick() throws {
        var ghost = try #require(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed))
        ghost.advance(to: 10)
        #expect(ghost.fade(liveTick: 10, reducedMotion: false) == 1)
        ghost.advance(to: Self.ticks)
        #expect(ghost.fade(liveTick: Self.ticks, reducedMotion: false) == 1)
        let half = ghost.fade(liveTick: Self.ticks + GhostRun.fadeTicks / 2, reducedMotion: false)
        #expect(half > 0 && half < 1)
        #expect(ghost.fade(liveTick: Self.ticks + GhostRun.fadeTicks, reducedMotion: false) == 0)
        #expect(ghost.fade(liveTick: Self.ticks + 1, reducedMotion: true) == 0)
    }

    /// RS-014: a live run with a ghost beside it ends on the same digest,
    /// state, and receipt as the same run without one.
    @Test func rs014GhostLeavesTheLiveRunUntouched() throws {
        // Different commands from the ghost's, so the two runs genuinely diverge.
        let liveCommands = Self.commands(count: Self.ticks + 60, phase: 31)

        let alone = try Self.play(seed: Self.seed, commands: liveCommands)

        var withGhost = try Simulation.make(seed: Self.seed)
        var ghost = try #require(GhostRun(record: Self.recorded.record, liveIdentity: .current, liveSeed: Self.seed))
        var ghostPositions: Set<VecI> = []
        for command in liveCommands {
            withGhost.step(command: command)
            ghost.advance(to: withGhost.state.tick)
            ghostPositions.insert(ghost.playerPosition)
        }

        #expect(ghostPositions.count > 1, "the ghost never moved, so this proves nothing")
        #expect(ghost.finished)
        #expect(withGhost.state.digest() == alone.state.digest())
        #expect(withGhost.state == alone.state)
        #expect(RunReceipt(withGhost.state) == RunReceipt(alone.state))
    }

    /// § 10.2 "Best means success in the fewest ticks".
    @Test func onlyAFasterSuccessReplacesTheBest() throws {
        let stored = Self.recorded.record
        let id = ReplayIdentity.current
        #expect(GhostRecord.replaces(nil, candidateTicks: 999, seed: stored.seed, identity: id))
        #expect(GhostRecord.replaces(stored, candidateTicks: stored.ticks - 1, seed: stored.seed, identity: id))
        #expect(!GhostRecord.replaces(stored, candidateTicks: stored.ticks, seed: stored.seed, identity: id))
        #expect(!GhostRecord.replaces(stored, candidateTicks: stored.ticks + 1, seed: stored.seed, identity: id))
        // A record for another seed is not a best for this one.
        #expect(GhostRecord.replaces(stored, candidateTicks: stored.ticks + 1, seed: stored.seed &+ 1, identity: id))

        var failed = try Simulation.make(seed: Self.seed)
        failed.step(command: .neutral(tick: 1))
        #expect(GhostRecord(successfulRun: failed.state, commands: []) == nil)

        var won = try Simulation.make(seed: Self.seed)
        _ = won.testing_completeRunSuccess(upgrade: .ricochetPulse)
        let record = try #require(GhostRecord(successfulRun: won.state, commands: []))
        #expect(record.ticks == won.state.tick)
        #expect(record.seed == Self.seed)
    }
}

/// `run-shell.md` § 11 (D-081): the run card and Share.
@Suite(.serialized)
struct RunCardTests {
    static let seed = GhostRunTests.seed

    static func successState() throws -> WorldState {
        var sim = try Simulation.make(seed: seed)
        _ = sim.testing_completeRunSuccess(upgrade: .signalJammer)
        #expect(sim.state.outcome == .success)
        return sim.state
    }

    @Test func clockFormatsElapsedTicksAsMinutesAndSeconds() {
        #expect(RunCard.clock(ticks: 0) == "0:00")
        #expect(RunCard.clock(ticks: 59) == "0:00")
        #expect(RunCard.clock(ticks: 60) == "0:01")
        #expect(RunCard.clock(ticks: 3_599) == "0:59")
        #expect(RunCard.clock(ticks: 3_600) == "1:00")
        #expect(RunCard.clock(ticks: 60 * 60 * 7 + 60 * 5) == "7:05")
        #expect(RunCard.clock(ticks: 60 * 60 * 12) == "12:00")
    }

    /// RS-001: the § 11 rows, in order, for a first success on the day.
    @Test func successRowsWithNoStoredBest() throws {
        let state = try Self.successState()
        let card = RunCard(state: state, dateLabel: "2026-09-28", bestTicks: nil)
        #expect(card.rows.map(\.label) == ["DATE", "TIME", "CAMERAS", "PEAK DETECTION", "GHOST"])
        #expect(card.value(for: "DATE") == "2026-09-28")
        #expect(card.value(for: "TIME") == RunCard.clock(ticks: state.tick))
        #expect(card.value(for: "CAMERAS") == "\(state.destructions.count)/8")
        #expect(card.value(for: "PEAK DETECTION") == RunCard.peakDetection(state).rawValue.uppercased())
        #expect(card.value(for: "GHOST") == "NEW BEST")
    }

    @Test func ghostRowShowsNewBestOrTheGap() throws {
        let state = try Self.successState()
        let faster = RunCard(state: state, dateLabel: "2026-09-28", bestTicks: state.tick + 600)
        #expect(faster.value(for: "GHOST") == "NEW BEST")
        let slower = RunCard(state: state, dateLabel: "2026-09-28", bestTicks: state.tick - 120)
        #expect(slower.value(for: "GHOST") == "+0:02")
        let tie = RunCard(state: state, dateLabel: "2026-09-28", bestTicks: state.tick)
        #expect(tie.value(for: "GHOST") == "+0:00")
    }

    /// A run that is not stored (a debug-seeded harness run) never claims
    /// `NEW BEST`.
    @Test func aRunThatIsNotStoredNeverClaimsNewBest() throws {
        let state = try Self.successState()
        let none = RunCard(state: state, dateLabel: nil, bestTicks: nil, storesBest: false)
        #expect(none.value(for: "GHOST") == nil)
        #expect(none.value(for: "DATE") == nil)
        let some = RunCard(state: state, dateLabel: nil, bestTicks: state.tick + 60, storesBest: false)
        #expect(some.value(for: "GHOST") == "-0:01")
    }

    /// RS-002 / RS-017: a failed run shows no ghost row at all, with or
    /// without a stored best, so a short death never reads as "faster".
    @Test func failedRunNeverShowsNewBest() throws {
        var sim = try Simulation.make(seed: Self.seed)
        sim.testing_setPlayerIntegrity(0)
        sim.step(command: .neutral(tick: 1))
        #expect(sim.state.outcome == .failure)
        let none = RunCard(state: sim.state, dateLabel: "2026-09-28", bestTicks: nil)
        #expect(none.value(for: "GHOST") == nil)
        let some = RunCard(state: sim.state, dateLabel: "2026-09-28", bestTicks: sim.state.tick + 60)
        #expect(some.value(for: "GHOST") == nil)
    }

    @Test func networkBlackoutJoinsTheCameraRow() throws {
        var sim = try Simulation.make(seed: Self.seed)
        for index in 0..<8 {
            sim.testing_destroyCameraAtIndex(index)
            sim.step(command: .neutral(tick: UInt64(index + 1)))
        }
        #expect(sim.state.networkBlackout)
        let card = RunCard(state: sim.state, dateLabel: "2026-09-28", bestTicks: nil)
        #expect(card.value(for: "CAMERAS") == "8/8 NETWORK BLACKOUT")
    }

    /// The highest Detection State reached, not the final one.
    @Test func peakDetectionIsTheHighestReached() throws {
        var sim = try Simulation.make(seed: Self.seed)
        sim.testing_setExposure(750)
        sim.testing_setExposure(100)
        #expect(RunCard.peakDetection(sim.state) == .hunted)
        #expect(RunCard(state: sim.state, dateLabel: nil, bestTicks: nil).value(for: "PEAK DETECTION") == "HUNTED")
        var locked = sim.state
        locked.exposure.lockdownEntered = true
        #expect(RunCard.peakDetection(locked) == .lockdown)
    }

    /// RS-016: the share text carries the game's name and the § 11 rows, and
    /// no seed, digest, receipt field, or identifier.
    @Test func rs016ShareTextHasTheRowsAndNoSeedOrIdentifier() throws {
        let state = try Self.successState()
        let card = RunCard(state: state, dateLabel: "2026-09-28", bestTicks: state.tick + 60)
        let text = card.shareText
        #expect(text.hasPrefix(RunCard.gameName))
        for row in card.rows {
            #expect(text.contains(row.label))
            #expect(text.contains(row.value))
        }
        #expect(!text.contains(String(state.seed)))
        #expect(!text.contains(String(state.seed, radix: 16)))
        #expect(!text.contains(state.digest()))
        #expect(!text.contains(String(state.digest().prefix(8))))
        for identifier in [
            ContractVersions.ruleset, ContractVersions.content, ContractVersions.arena,
            ContractVersions.replaySchema, ContractVersions.specificationCommit
        ] {
            #expect(!text.contains(identifier))
        }
        #expect(!text.lowercased().contains("seed"))
        #expect(!text.lowercased().contains("receipt"))
        // Nothing but the name and one line per row.
        #expect(text.split(separator: "\n").count == card.rows.count + 1)
    }
}

/// § 10.2 / ER-007: the Ghost toggle is a presentation setting.
@Suite(.serialized)
struct GhostSettingTests {
    @Test func ghostIsOnByDefault() {
        #expect(PresentationSettings.defaults.ghostEnabled)
    }

    /// Settings stored before the toggle existed keep every stored choice.
    @Test func settingsSavedBeforeTheToggleStillDecode() throws {
        var legacy = PresentationSettings.defaults
        legacy.handedness = .left
        legacy.tutorialsEnabled = false
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "ghostEnabled")
        let decoded = try JSONDecoder().decode(
            PresentationSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.handedness == .left)
        #expect(!decoded.tutorialsEnabled)
        #expect(decoded.ghostEnabled)
    }

    @Test func ghostSettingRoundTripsAndStaysOffTheReceipt() throws {
        var off = PresentationSettings.defaults
        off.ghostEnabled = false
        let decoded = try JSONDecoder().decode(PresentationSettings.self, from: JSONEncoder().encode(off))
        #expect(!decoded.ghostEnabled)
        #expect(off.receiptMetadata == PresentationSettings.defaults.receiptMetadata)
    }

    /// The ghost never reaches the digest.
    @Test func ghostNeverAppearsInTheDigest() throws {
        var sim = try Simulation.make(seed: 3)
        sim.step(command: .neutral(tick: 1))
        #expect(!StateDigest.canonical(sim.state).serialize().lowercased().contains("ghost"))
    }
}

/// `run-shell.md` § 4 / RS-006: Share sits beside Restart and both stay usable.
@Suite(.serialized)
struct TerminalShareGeometryTests {
    static let sizes = TerminalSurfaceGeometryTests.sizes

    @Test func shareIsInsideThePanelAndMeetsTheTouchTarget() {
        for (w, h) in Self.sizes {
            let panel = HUDLayout.terminalPanel(safeWidth: w, safeHeight: h)
            let share = HUDLayout.terminalShare(safeWidth: w, safeHeight: h)
            #expect(share.width >= HUDLayout.minimumTouchTargetPoints)
            #expect(share.height >= HUDLayout.minimumTouchTargetPoints)
            #expect(share.x >= panel.x && share.y >= panel.y)
            #expect(share.x + share.width <= panel.x + panel.width)
            #expect(share.y + share.height <= panel.y + panel.height)
        }
    }

    /// The two controls never overlap, so a tap reaches exactly one of them.
    @Test func shareAndRestartDoNotOverlap() {
        for (w, h) in Self.sizes {
            let restart = HUDLayout.terminalRestart(safeWidth: w, safeHeight: h)
            let share = HUDLayout.terminalShare(safeWidth: w, safeHeight: h)
            #expect(share.x >= restart.x + restart.width || share.x + share.width <= restart.x)
            #expect(share.y == restart.y)
        }
    }

    /// Every run card row fits between the title and the controls.
    @Test func cardRowsSitBetweenTitleAndControls() {
        for (w, h) in Self.sizes {
            let restart = HUDLayout.terminalRestart(safeWidth: w, safeHeight: h)
            let title = HUDLayout.terminalTitleCentreY(safeWidth: w, safeHeight: h)
            let half = HUDLayout.terminalCardRowHeight / 2
            let first = HUDLayout.terminalCardRowCentreY(0, safeWidth: w, safeHeight: h)
            let last = HUDLayout.terminalCardRowCentreY(
                HUDLayout.terminalCardRowCapacity - 1, safeWidth: w, safeHeight: h
            )
            #expect(first - half > title)
            #expect(last + half <= restart.y)
        }
    }
}
