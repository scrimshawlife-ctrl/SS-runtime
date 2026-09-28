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
}
