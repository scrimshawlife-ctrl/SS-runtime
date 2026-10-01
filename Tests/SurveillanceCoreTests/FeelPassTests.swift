import Foundation
import Testing
@testable import SurveillanceCore

/// Shared runs for the medal and feel-pass tests.
enum FeelPassFixtures {
    /// Seeds whose competent piloted run (Ricochet Pulse) succeeds on the
    /// pinned rules, tried in order. More than one, so a rules change that
    /// turns one into a failure does not silently remove the RS-022 evidence:
    /// the test fails loudly only if none succeeds.
    static let successSeeds: [UInt64] = [3, 5, 2, 4, 6, 7, 8]

    struct Run: Sendable {
        var seed: UInt64
        var commands: [PlayerCommand]
    }

    static let pilotedSuccess: Run? = {
        for seed in successSeeds {
            guard let run = try? PacingProbe.run(seed: seed, upgrade: .ricochetPulse, profile: .competent),
                  run.outcome == .success
            else { continue }
            return Run(seed: seed, commands: run.commands)
        }
        return nil
    }()

    struct PresentedRun {
        var state: WorldState
        var medals: [Medal]
        var digests: [String]
        var takedowns: Int
        var maxStreak: Int
        var tutorialLinesAtOnce: Int
    }

    /// The run the way `GameSession` presents it: a 2 s intro before the first
    /// tick, the presenter fed around every step, the audio decorated, and
    /// the day's look derived.
    static func livePresenterRun(seed: UInt64, commands: [PlayerCommand], reducedMotion: Bool = false) throws -> PresentedRun {
        var sim = try Simulation.make(seed: seed)
        var intro = IntroSequence(cameraIds: sim.state.cameras.map(\.entityId), reducedMotion: reducedMotion)
        while !intro.isFinished { _ = intro.advance() }
        _ = DailyFlavour(day: DailyRun.Day(year: 2026, month: 10, day: 1))
        var presenter = FeelPassPresenter()
        var audio = AudioProjector()
        var digests: [String] = []
        var maxStreak = 0
        for command in commands where !sim.isTerminal {
            let before = sim.state.enemies
            presenter.willStep(sim.state)
            let result = sim.step(command: command)
            presenter.didStep(events: result.events, enemiesBefore: before, state: sim.state)
            _ = presenter.decorate(
                audio.project(tick: result.tick, events: result.events, world: AudioWorldQuery.from(sim.state), settings: .enabled)
            )
            maxStreak = max(maxStreak, presenter.takedowns.streak)
            digests.append(result.digest)
        }
        return PresentedRun(
            state: sim.state,
            medals: presenter.earnedMedals(sim.state),
            digests: digests,
            takedowns: presenter.takedowns.total,
            maxStreak: maxStreak,
            tutorialLinesAtOnce: 1
        )
    }

    /// The same commands with nothing presented.
    static func bareRun(seed: UInt64, commands: [PlayerCommand]) throws -> (state: WorldState, digests: [String]) {
        var sim = try Simulation.make(seed: seed)
        var digests: [String] = []
        for command in commands where !sim.isTerminal {
            digests.append(sim.step(command: command).digest)
        }
        return (sim.state, digests)
    }

    /// Deterministic wandering commands, with Dodge now and then.
    static func wander(count: UInt64) -> [PlayerCommand] {
        (1...count).map { tick in
            let phase = Double(tick) / 90
            return PlayerCommand(
                tick: tick,
                moveX: Int16(cos(phase) * 24_000),
                moveY: Int16(sin(phase * 0.7) * 24_000),
                dodgePressed: tick % 240 == 0
            )
        }
    }
}

/// The task's proof: every D-095/D-097/D-098/D-099 feature is presentation
/// only. The same commands with and without them give the same digest every
/// tick and the same receipt.
@Suite(.serialized)
struct FeelPassPresentationOnlyTests {
    @Test func wanderingRunDigestAndReceiptAreUnchanged() throws {
        let commands = FeelPassFixtures.wander(count: 1_800)
        let bare = try FeelPassFixtures.bareRun(seed: 11, commands: commands)
        let presented = try FeelPassFixtures.livePresenterRun(seed: 11, commands: commands)
        #expect(presented.digests == bare.digests)
        #expect(presented.state.digest() == bare.state.digest())
        #expect(RunReceipt(presented.state) == RunReceipt(bare.state))
        #expect(RunReceipt(presented.state).canonical() == RunReceipt(bare.state).canonical())
    }

    @Test func reducedMotionIntroChangesNothingEither() throws {
        let commands = FeelPassFixtures.wander(count: 600)
        let bare = try FeelPassFixtures.bareRun(seed: 12, commands: commands)
        let presented = try FeelPassFixtures.livePresenterRun(seed: 12, commands: commands, reducedMotion: true)
        #expect(presented.digests == bare.digests)
        #expect(RunReceipt(presented.state) == RunReceipt(bare.state))
    }

    /// A full piloted success, to the terminal tick, with medals earned.
    @Test func pilotedSuccessDigestAndReceiptAreUnchanged() throws {
        let run = try #require(FeelPassFixtures.pilotedSuccess)
        let bare = try FeelPassFixtures.bareRun(seed: run.seed, commands: run.commands)
        let presented = try FeelPassFixtures.livePresenterRun(seed: run.seed, commands: run.commands)
        #expect(bare.state.outcome == .success)
        #expect(presented.digests == bare.digests)
        #expect(presented.state.terminalDigest == bare.state.terminalDigest)
        #expect(RunReceipt(presented.state) == RunReceipt(bare.state))
        print("FEELPASS-PROOF seed=\(run.seed) ticks=\(bare.state.tick) digest=\(bare.state.digest()) medals=\(presented.medals.map(\.name)) takedowns=\(presented.takedowns) maxStreak=\(presented.maxStreak)")
    }
}

// MARK: - D-097 stealth texture

@Suite(.serialized)
struct StealthTextureTests {
    static let state: WorldState = MedalTests.withPatrol

    static func died(_ id: EntityID) -> AuthoritativeEvent {
        AuthoritativeEvent(tick: 2, phase: 9, type: .entityDied, primary: id, payload: [:], insertion: 0)
    }

    static func alerted(_ id: EntityID) -> AuthoritativeEvent {
        AuthoritativeEvent(tick: 2, phase: 5, type: .enemyAlerted, primary: id, payload: [:], insertion: 0)
    }

    @Test func anUnawareKillIsATakedown() {
        let id = MedalTests.patrolMember
        let enemies = Self.state.enemies
        #expect(enemies.first { $0.id == id }?.awareness == .unaware)
        #expect(TakedownTracker.takedowns(events: [Self.died(id)], before: enemies) == [id])
    }

    @Test func aKillAfterAnAlertIsNotATakedown() {
        let id = MedalTests.patrolMember
        #expect(TakedownTracker.takedowns(events: [Self.alerted(id), Self.died(id)], before: Self.state.enemies).isEmpty)
    }

    @Test func aKillOfAStruckOrAwareEnemyIsNotATakedown() {
        let id = MedalTests.patrolMember
        for awareness in [EnemyAwareness.struck, .aware] {
            var enemies = Self.state.enemies
            let index = enemies.firstIndex { $0.id == id }!
            enemies[index].awareness = awareness
            #expect(TakedownTracker.takedowns(events: [Self.died(id)], before: enemies).isEmpty)
        }
    }

    @Test func streakCountsAndResetsWhenAnEnemyBecomesAware() {
        let members = Self.state.enemies.filter { $0.patrol != nil }.map(\.id).sorted()
        #expect(members.count >= 3)
        var tracker = TakedownTracker()
        var before = Self.state.enemies
        tracker.ingest(events: [Self.died(members[0])], before: before, after: before)
        #expect(tracker.streak == 1)
        #expect(tracker.hudCopy == nil, "a single takedown has its caption already")
        tracker.ingest(events: [Self.died(members[1])], before: before, after: before)
        #expect(tracker.streak == 2)
        #expect(tracker.hudCopy == "TAKEDOWN ×2")
        var after = before
        let index = after.firstIndex { $0.id == members[2] }!
        after[index].awareness = .aware
        tracker.ingest(events: [], before: before, after: after)
        #expect(tracker.streak == 0)
        #expect(tracker.total == 2, "the streak grants nothing and forgets nothing else")
        before = after
        tracker.ingest(events: [], before: before, after: after)
        #expect(tracker.streak == 0)
    }

    @Test func takedownAudioIsPitchedFourSemitonesDownWithARoutineCaption() {
        let id = MedalTests.patrolMember
        var audio = AudioProjection.silent
        audio.cues = [
            .presentation(audioId: "impact_enemy", caption: "Impact", sourceEntityId: id),
            .presentation(audioId: "impact_enemy", caption: "Impact", sourceEntityId: EntityID(1), sequence: 1)
        ]
        let decorated = StealthTexture.decorate(audio, takedowns: [id])
        #expect(decorated.cues[0].pitchCents == -400)
        #expect(decorated.cues[1].pitchCents == 0)
        let caption = decorated.captionCues.last
        #expect(caption?.caption == "Takedown")
        #expect(CaptionClass.of(cueId: caption!.audioId) == .routine)
        var board = CaptionBoard()
        board.ingest(tick: 5, cues: decorated.captionCues)
        #expect(board.visible(at: 5, setting: .all).map { $0.text.uppercased() } == ["TAKEDOWN"])
        #expect(board.visible(at: 5, setting: .important).isEmpty, "routine, so Important hides it")
        #expect(StealthTexture.decorate(audio, takedowns: []) == audio)
    }

    @Test func takedownHitStopIsSeventyMilliseconds() {
        var clock = HitStopClock()
        clock.admit(ms: StealthTexture.takedownHitStopMs)
        #expect(clock.remainingFrames == 4, "70 ms at 60 Hz, never exceeded")
        clock.admit(ms: 30)
        #expect(clock.remainingFrames == 4, "freezes never stack")
    }

    /// § 8c near miss agrees with the rule: lit means inside 1.25 × range and
    /// the half-angle, and not seen.
    @Test func nearMissIsInsideTheWideConeButNotSeen() throws {
        var sim = try Simulation.make(seed: 1)
        sim.step(command: .neutral(tick: 1))
        let member = try #require(sim.state.enemies.filter { $0.patrol != nil }.min { $0.id < $1.id })
        let facing = try #require(member.patrol?.facing)
        let length = hypot(Double(facing.x.raw), Double(facing.y.raw))
        let range = Double(sim.state.content.patrol.sightUnits)
        let origin = (x: Double(member.position.x.unitsTruncated), y: Double(member.position.y.unitsTruncated))
        func place(_ distance: Double) {
            sim.testing_setPlayerPosition(VecI(
                x: Int((origin.x + Double(facing.x.raw) / length * distance).rounded()),
                y: Int((origin.y + Double(facing.y.raw) / length * distance).rounded())
            ))
        }
        place(range * 1.1)
        #expect(PatrolNearMiss.members(sim.state).contains(member.id))
        place(range * 1.4)
        #expect(!PatrolNearMiss.members(sim.state).contains(member.id))
        place(range * 0.8)
        let current = sim.state.enemies.first { $0.id == member.id }!
        let seen = PatrolSystem.sees(member: current, player: sim.state.player.position, spec: sim.state.content.patrol, solids: sim.state.liveSolids)
        #expect(PatrolNearMiss.members(sim.state).contains(member.id) == !seen)
    }

    @Test func nearMissEdgePulsesExceptUnderReducedMotion() {
        let pulsing = (0..<60).map { PatrolNearMiss.edgeIntensity(frame: UInt64($0), reducedMotion: false) }
        #expect(Set(pulsing).count > 10)
        #expect(pulsing.allSatisfy { $0 >= 0.6 && $0 <= 1 })
        #expect((0..<60).allSatisfy { PatrolNearMiss.edgeIntensity(frame: UInt64($0), reducedMotion: true) == 1 })
    }
}

// MARK: - D-098 opening and copy timing

@Suite(.serialized)
struct OpeningTests {
    static let cameras = (1...8).map { EntityID(UInt64(40 - $0)) }

    @Test func introPowersTheEightFieldsOnInStableIdOrderOverOnePointTwoSeconds() {
        var intro = IntroSequence(cameraIds: Self.cameras, reducedMotion: false)
        var order: [EntityID] = []
        var frames: [Int] = []
        while !intro.isFinished {
            let frame = intro.frame
            let powered = intro.advance()
            order += powered
            frames += Array(repeating: frame, count: powered.count)
        }
        #expect(intro.frame == 120, "2 s at 60 Hz")
        #expect(order == Self.cameras.sorted())
        #expect(frames.first == IntroSequence.titleHoldFrames)
        #expect(frames.last! < IntroSequence.titleHoldFrames + IntroSequence.powerOnFrames)
        #expect(intro.titleAlpha == 0)
    }

    @Test func fieldsAreDarkUntilTheirTurn() {
        var intro = IntroSequence(cameraIds: Self.cameras, reducedMotion: false)
        #expect(Self.cameras.allSatisfy { !intro.isPowered($0) })
        #expect(intro.titleAlpha == 1)
        for _ in 0...IntroSequence.titleHoldFrames { _ = intro.advance() }
        let first = Self.cameras.min()!
        #expect(intro.isPowered(first))
        #expect(Self.cameras.filter { intro.isPowered($0) } == [first])
    }

    @Test func reducedMotionIsOneHalfSecondFadeWithNoChirps() {
        var intro = IntroSequence(cameraIds: Self.cameras, reducedMotion: true)
        var chirps = 0
        while !intro.isFinished { chirps += intro.advance().count }
        #expect(intro.frame == 30)
        #expect(chirps == 0)
        #expect(Self.cameras.allSatisfy { intro.isPowered($0) })
    }

    @Test func anyTouchSkips() {
        var intro = IntroSequence(cameraIds: Self.cameras, reducedMotion: false)
        _ = intro.advance()
        intro.skip()
        #expect(intro.isFinished)
        #expect(intro.advance().isEmpty)
        #expect(Self.cameras.allSatisfy { intro.isPowered($0) })
    }

    @Test func oneTutorialLineAtATimeAndLaterLinesQueue() {
        var queue = TutorialLineQueue()
        #expect(queue.update(card: "MOVE", hints: [PatrolTutorial.copy], blocked: false) == "MOVE")
        #expect(queue.pending == ["MOVE", PatrolTutorial.copy])
        // The card completes; the queued hint shows next.
        #expect(queue.update(card: nil, hints: [PatrolTutorial.copy], blocked: false) == PatrolTutorial.copy)
        #expect(queue.pending == [PatrolTutorial.copy], "a hint is offered once")
    }

    @Test func aLineWaitsBehindTheEncounterLabelOrUpgradePromptWithoutLosingTime() {
        var queue = TutorialLineQueue()
        #expect(queue.update(card: nil, hints: [AwarenessHintProjector.copy], blocked: true) == nil)
        for _ in 0..<500 { #expect(queue.update(card: nil, hints: [], blocked: true) == nil) }
        var shown = 0
        while queue.update(card: nil, hints: [], blocked: false) != nil { shown += 1 }
        #expect(shown == TutorialLineQueue.latchedVisibleTicks)
    }

    @Test func encounterLabelAppearsOnActivationNotBefore() throws {
        var sim = try Simulation.make(seed: 1)
        sim.step(command: .neutral(tick: 1))
        var gate = EncounterLabelGate()
        let snap = PresentationSnapshot(sim.state)
        #expect(snap.objectiveNode == .mobA)
        #expect(gate.project(snap, state: sim.state) == nil)
        var state = sim.state
        state.encounters["M-A"]?.activated = true
        #expect(gate.project(snap, state: state) == "MOB ENCOUNTER A")
        #expect(gate.isFresh(.mobA, tick: snap.tick))
        #expect(!gate.isFresh(.mobA, tick: snap.tick + EncounterLabelGate.freshTicks))
    }

    @Test func spawnShowsOneLineAndNoEncounterLabel() throws {
        var sim = try Simulation.make(seed: 1)
        var presenter = FeelPassPresenter()
        for tick in UInt64(1)...30 {
            let before = sim.state.enemies
            presenter.willStep(sim.state)
            let result = sim.step(command: .neutral(tick: tick))
            presenter.didStep(events: result.events, enemiesBefore: before, state: sim.state)
            #expect(presenter.objectiveCopy == nil)
        }
        #expect(presenter.tutorialLine == "MOVE")
        #expect(presenter.tutorial.pending.first == "MOVE")
    }

    @Test func patrolTutorialCopyIsTheSpecLine() {
        #expect(PatrolTutorial.copy == "PATROL • STAY OUT OF THE CONES • WALK PAST OR STRIKE")
    }
}

// MARK: - D-099 daily flavour

struct DailyFlavourTests {
    @Test func derivedFromTheDayKeyBySpecBitRanges() {
        let day = DailyRun.Day(year: 2026, month: 10, day: 1)
        let mix = DailyRun.candidate(day: day, salt: 0)
        let flavour = DailyFlavour(day: day)
        #expect(flavour.grade == DailyFlavour.Grade.allCases[Int((mix & 0xFF) % 4)])
        #expect(flavour.fogPercent == [80, 100, 120][Int(((mix >> 8) & 0xFF) % 3)])
        #expect(flavour.headline == DailyFlavour.headlines[Int(((mix >> 16) & 0xFF) % 12)])
        #expect(DailyFlavour(day: day) == flavour, "deterministic")
    }

    @Test func aYearOfDaysUsesEveryValue() {
        var grades = Set<String>(), fogs = Set<Int>(), headlines = Set<String>()
        for day in DailyRunSeedTests.consecutiveDays(from: DailyRun.Day(year: 2026, month: 1, day: 1), count: 365) {
            let flavour = DailyFlavour(day: day)
            grades.insert(flavour.grade.rawValue)
            fogs.insert(flavour.fogPercent)
            headlines.insert(flavour.headline)
        }
        #expect(grades == ["CLEAR", "OVERCAST", "GOLDEN HOUR", "NIGHT SHIFT"])
        #expect(fogs == [80, 100, 120])
        #expect(headlines.count == 12)
    }

    @Test func theTwelveAuthoredHeadlines() {
        #expect(DailyFlavour.headlines.count == 12)
        #expect(DailyFlavour.headlines.first == "FOG ADVISORY IN EFFECT")
        #expect(DailyFlavour.headlines.last == "OBSERVATION WEEK BEGINS")
    }

    /// § 10.3 limits: night shift only ever darkens (a multiply with every
    /// channel at most 1), and no grade overlay is opaque enough to replace
    /// the ground it tints.
    @Test func gradesStayWithinTheReadabilityFloor() {
        #expect(DailyGradeOverlay.of(.clear) == nil)
        let night = DailyGradeOverlay.of(.nightShift)!
        #expect(night.multiply)
        #expect([night.red, night.green, night.blue].allSatisfy { $0 > 0.3 && $0 <= 1 })
        let golden = DailyGradeOverlay.of(.goldenHour)!
        #expect(!golden.multiply && golden.alpha <= 0.2)
        let overcast = DailyGradeOverlay.of(.overcast)!
        #expect(overcast.multiply)
    }

    @Test func fogDensityScalesBeforeThinning() {
        let dense = DailyFlavour(mix: UInt64(2) << 8)
        #expect(dense.fogPercent == 120)
        #expect(dense.fogMultiplier * FogThinning.thinnedOpacity == 0.6, "fog still thins in a fight")
    }

    @Test func titleDetailNamesGradeAndFog() {
        #expect(DailyFlavour(mix: 3).titleDetail == "NIGHT SHIFT · FOG 80%")
    }
}
