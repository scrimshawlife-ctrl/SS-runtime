import Foundation
import Testing
@testable import SurveillanceCore

/// T305 pacing probes and T901 long-replay determinism.
///
/// These tests measure; they do not assert a pacing target. Whether the
/// measured numbers meet `arena.md` §5 / E-011 is recorded in the SS-specs
/// evidence document, not decided here.
@Suite(.serialized)
struct PacingProbeTests {
    /// One legal piloted run, shared by the T901 tests: seed 1, Ricochet
    /// Pulse, competent profile. Thousands of ticks through the encounter
    /// graph, against the pinned fixtures' 5 (`replay-smoke-001`) and 302
    /// (`complete-run-vectors-001`) ticks.
    static let pilotedRun: PacingProbe.Result? = try? PacingProbe.run(
        seed: 1, upgrade: .ricochetPulse, profile: .competent
    )

    /// T901: the piloted run, re-executed three times from its recorded
    /// commands, ends on the tick, outcome, and digest the live run produced.
    /// The digest is printed so runs on different architectures can be
    /// compared; it is not pinned, because no spec fixture owns it.
    @Test func replayT901PilotedRunReproducesDigestThreeTimes() throws {
        let live = try #require(Self.pilotedRun)
        #expect(live.stalledOn == nil)
        #expect(live.ticks > 1_000)
        var digests: [String] = []
        for _ in 0..<3 {
            let replay = try #require(PacingProbe.replay(live))
            #expect(replay.tick == live.ticks)
            #expect(replay.outcome == live.outcome)
            digests.append(replay.digest)
        }
        #expect(Set(digests) == [live.digest])
        print("T901-PILOTED-RUN seed=1 upgrade=ricochetPulse ticks=\(live.ticks) outcome=\(live.outcome.rawValue) digest=\(live.digest)")
    }

    /// T901 / ER-001: the serialized replay survives the JSON loader and still
    /// reproduces the live digest.
    @Test func replayT901PilotedRunRoundTripsThroughEnvelopeJSON() throws {
        let live = try #require(Self.pilotedRun)
        let json = Data(PacingProbe.replayJSON(live).utf8)
        let envelope = try ReplayEnvelope.load(json: json).get()
        #expect(envelope.commands == live.commands)
        guard case .success(let replay) = Simulation.execute(envelope) else {
            Issue.record("replay failed to execute")
            return
        }
        #expect(replay.digest == live.digest)
    }

    /// T305 probe matrix. Opt-in, because each run is thousands of ticks and
    /// the sweep is minutes long even in a release build:
    ///
    /// ```
    /// SS_PACING_SEEDS=20 SS_PACING_REPORT=/path/report.jsonl \
    ///   swift test -c release -Xswiftc -enable-testing --filter pacingT305ProbeMatrix
    /// ```
    ///
    /// Every legal run must replay to its live digest. Every sustained
    /// (diagnostic) run must not fail. One JSON line per run goes to
    /// `SS_PACING_REPORT` when set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SS_PACING_SEEDS"] != nil))
    func pacingT305ProbeMatrix() throws {
        let environment = ProcessInfo.processInfo.environment
        let seedCount = try #require(environment["SS_PACING_SEEDS"].flatMap(UInt64.init))
        var lines: [String] = []
        for seed in 1...seedCount {
            for profile in [ProbePilot.Profile.competent, .firstRun] {
                for upgrade in UpgradeID.allCases {
                    let legal = try PacingProbe.run(seed: seed, upgrade: upgrade, profile: profile)
                    let replay = PacingProbe.replay(legal)
                    #expect(replay?.digest == legal.digest)
                    lines.append(PacingProbe.reportLine(legal, replayDigests: replay.map { [$0.digest] } ?? []))

                    let sustained = try PacingProbe.run(
                        seed: seed, upgrade: upgrade, profile: profile, sustained: true
                    )
                    #expect(sustained.outcome != .failure)
                    lines.append(PacingProbe.reportLine(sustained, replayDigests: []))
                }
            }
        }
        if let path = environment["SS_PACING_REPORT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// D-082 / D-083 style sweep: does a careful run draw fewer heat
    /// reinforcements than a loud one? Opt-in, like the T305 matrix:
    ///
    /// ```
    /// SS_HEAT_SEEDS=20 SS_HEAT_REPORT=/path/heat.jsonl \
    ///   swift test -c release -Xswiftc -enable-testing --filter heatD083StyleSweep
    /// ```
    ///
    /// It measures and does not assert the design verdict. It does assert
    /// what must hold on every run: legal runs replay to their digest, and
    /// the Informants the director queued at each M-A/M-B wave start are
    /// exactly the authored members plus what the Detection State, derived
    /// by `HeatCaptionProjector` from the published events, calls for.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SS_HEAT_SEEDS"] != nil))
    func heatD083StyleSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        let seedCount = try #require(environment["SS_HEAT_SEEDS"].flatMap(UInt64.init))
        struct Job: Sendable {
            var seed: UInt64
            var profile: ProbePilot.Profile
            var upgrade: UpgradeID
            var sustained: Bool
        }
        var jobs: [Job] = []
        for seed in 1...seedCount {
            for profile in [ProbePilot.Profile.stealth, .loud, .competent] {
                for upgrade in UpgradeID.allCases {
                    for sustained in [false, true] {
                        jobs.append(Job(seed: seed, profile: profile, upgrade: upgrade, sustained: sustained))
                    }
                }
            }
        }
        // Independent runs, so they run in parallel; results are collected
        // in job order and asserted here, on the test's own thread.
        let sink = ProbeSink()
        let frozen = jobs
        DispatchQueue.concurrentPerform(iterations: frozen.count) { index in
            let job = frozen[index]
            do {
                let run = try PacingProbe.run(seed: job.seed, upgrade: job.upgrade, profile: job.profile, sustained: job.sustained)
                var problems: [String] = []
                for wave in run.waveHeat where wave.queued != wave.authored + wave.added {
                    problems.append("\(job.profile.name) seed \(job.seed) \(wave.wave): queued \(wave.queued)")
                }
                var digests: [String] = []
                if !job.sustained {
                    let replay = PacingProbe.replay(run)
                    if replay?.digest != run.digest { problems.append("\(job.profile.name) seed \(job.seed): replay digest differs") }
                    digests = replay.map { [$0.digest] } ?? []
                }
                sink.add(index, PacingProbe.reportLine(run, replayDigests: digests), problems)
            } catch {
                sink.add(index, "{\"error\":\"\(error)\"}", ["\(error)"])
            }
        }
        #expect(sink.problems.isEmpty, "\(sink.problems)")
        if let path = environment["SS_HEAT_REPORT"] {
            try (sink.lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Thread-safe, order-restoring collector for the parallel sweep.
private final class ProbeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, String, [String])] = []
    func add(_ index: Int, _ line: String, _ problems: [String]) {
        lock.lock()
        entries.append((index, line, problems))
        lock.unlock()
    }
    var lines: [String] { entries.sorted { $0.0 < $1.0 }.map(\.1) }
    var problems: [String] { entries.sorted { $0.0 < $1.0 }.flatMap(\.2) }
}
