import Foundation
import Testing
@testable import SurveillanceCore

/// Research only (`research/pacing-search`): value overrides for a pacing
/// parameter search. Nothing here is a rule. It mutates a loaded
/// `CombatContent` in memory; the bundled contract is never touched.
///
/// A config is written as letter-number pairs, for example
/// `s320d25w150c100e125b125h100`:
/// - `s` sight range (units), `d` unaware drift (% of archetype speed),
/// - `w` M-A/M-B wave-size %, `c` M-C wave-size %,
/// - `e` elite Integrity %, `b` boss Integrity % (phase bands scale with it),
/// - `h` standard-enemy Integrity %, `x` standard-enemy damage %,
/// - `a` ally alert radius (units),
/// - `m` ambush damage multiplier,
/// - `i` Player starting Integrity (legal runs; sustained runs refill to 100),
/// - `p` every hit on the Player, % (all enemy, elite and boss damage).
struct PacingOverrides: Sendable {
    var label: String
    var sightRange = 160
    var driftPercent = 0
    var wavePercentAB = 100
    var wavePercentC = 100
    var elitePercent = 100
    var bossPercent = 100
    var standardHPPercent = 100
    var standardDamagePercent = 100
    var allyRadius = 128
    var playerDamagePercent = 100
    var ambushMultiplier = 2
    var playerIntegrity = 100

    init(_ label: String) {
        self.label = label
        var key: Character?
        var digits = ""
        func flush() {
            guard let key, let value = Int(digits) else { return }
            switch key {
            case "s": sightRange = value
            case "d": driftPercent = value
            case "w": wavePercentAB = value
            case "c": wavePercentC = value
            case "e": elitePercent = value
            case "b": bossPercent = value
            case "h": standardHPPercent = value
            case "x": standardDamagePercent = value
            case "a": allyRadius = value
            case "p": playerDamagePercent = value
            case "m": ambushMultiplier = value
            case "i": playerIntegrity = value
            default: break
            }
        }
        for ch in label {
            if ch.isLetter {
                flush()
                key = ch
                digits = ""
            } else {
                digits.append(ch)
            }
        }
        flush()
    }

    /// Round half up, never below 1 for an authored member.
    private static func scale(_ value: Int, _ percent: Int) -> Int {
        max(value > 0 ? 1 : 0, (value * percent + 50) / 100)
    }

    func apply(to base: CombatContent) -> CombatContent {
        var content = base
        content.awareness.sightRangeUnits = sightRange
        content.awareness.allyAlertRadiusUnits = allyRadius
        content.awareness.ambushDamageMultiplier = ambushMultiplier
        for (id, spec) in content.encounters {
            let percent = id == "M-C" ? wavePercentC : wavePercentAB
            var copy = spec
            copy.waves = spec.waves.map { wave in
                var w = wave
                w.members = wave.members.map { WaveMember(archetype: $0.archetype, count: Self.scale($0.count, percent)) }
                return w
            }
            copy.totals = copy.waves.reduce(0) { $0 + $1.members.reduce(0) { $0 + $1.count } }
            content.encounters[id] = copy
        }
        content.eliteHP = Self.scale(base.eliteHP, elitePercent)
        content.bossHP = Self.scale(base.bossHP, bossPercent)
        for (id, stats) in content.standardEnemies {
            var s = stats
            s.hp = Self.scale(stats.hp, standardHPPercent)
            if standardDamagePercent != 100 {
                s.contactDps = Self.scale(stats.contactDps, standardDamagePercent)
                s.shot?.damage = Self.scale(stats.shot?.damage ?? 0, standardDamagePercent)
                s.mine?.damage = Self.scale(stats.mine?.damage ?? 0, standardDamagePercent)
            }
            content.standardEnemies[id] = s
        }
        return content
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(Int, String)] = []
    func add(_ index: Int, _ line: String) {
        lock.lock()
        lines.append((index, line))
        lock.unlock()
    }
    var ordered: [String] { lines.sorted { $0.0 < $1.0 }.map(\.1) }
}

@Suite(.serialized)
struct PacingSearchTests {
    /// Opt-in grid:
    ///
    /// ```
    /// SS_SEARCH_CONFIGS="s160d0;s320d25w150" SS_SEARCH_SEEDS=1-10 \
    ///   SS_SEARCH_REPORT=/path/out.jsonl \
    ///   swift test -c release -Xswiftc -enable-testing --filter pacingSearch
    /// ```
    ///
    /// Runs every (config, seed, upgrade, profile, legal/sustained) job in
    /// parallel and writes one report line per run with a `config` field.
    /// Overridden content is not the bundled contract, so these runs are not
    /// replayable through `Simulation.execute` and carry no replay digests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SS_SEARCH_CONFIGS"] != nil))
    func pacingSearch() throws {
        let environment = ProcessInfo.processInfo.environment
        let configs = try #require(environment["SS_SEARCH_CONFIGS"])
            .split(separator: ";").map { PacingOverrides(String($0)) }
        let seedSpec = environment["SS_SEARCH_SEEDS"] ?? "1-10"
        let bounds = seedSpec.split(separator: "-").compactMap { UInt64($0) }
        let seeds = Array(bounds[0]...(bounds.count > 1 ? bounds[1] : bounds[0]))
        let profiles: [ProbePilot.Profile] = (environment["SS_SEARCH_PROFILES"] ?? "competent,stealth,loud")
            .split(separator: ",").compactMap { name in
                switch name {
                case "competent": .competent
                case "stealth": .stealth
                case "loud": .loud
                case "firstRun": .firstRun
                default: nil
                }
            }
        let sustainedModes: [Bool] = environment["SS_SEARCH_LEGAL_ONLY"] != nil ? [false] : [false, true]
        struct Job: Sendable {
            var config: PacingOverrides
            var seed: UInt64
            var upgrade: UpgradeID
            var profile: ProbePilot.Profile
            var sustained: Bool
        }
        var jobs: [Job] = []
        for config in configs {
            for seed in seeds {
                for profile in profiles {
                    for upgrade in UpgradeID.allCases {
                        for sustained in sustainedModes {
                            jobs.append(Job(config: config, seed: seed, upgrade: upgrade, profile: profile, sustained: sustained))
                        }
                    }
                }
            }
        }
        let sink = LineSink()
        let frozen = jobs
        DispatchQueue.concurrentPerform(iterations: frozen.count) { index in
            let job = frozen[index]
            let line: String
            do {
                let run = try PacingProbe.run(
                    seed: job.seed, upgrade: job.upgrade, profile: job.profile,
                    sustained: job.sustained, overrides: job.config
                )
                line = PacingProbe.reportLine(run, replayDigests: [])
            } catch {
                line = "{\"error\":\"\(error)\"}"
            }
            sink.add(index, "{\"config\":\"\(job.config.label)\"," + line.dropFirst())
        }
        if let path = environment["SS_SEARCH_REPORT"] {
            try (sink.ordered.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
