import Foundation
import SurveillanceCore

/// `run-shell.md` § 12 storage: today's medals, beside the day's best run
/// (`GhostStore`), keyed by seed and Replay Identity.
///
/// Application Support, one file per seed. Storing for a new seed removes
/// every other record, so a new day starts empty and the app keeps no medal
/// history beyond today's goal list.
enum MedalStore {
    private static let subdirectory = "DailyMedals"

    static func directoryURL() throws -> URL {
        try GhostStore.directoryURL()
            .deletingLastPathComponent()
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    private static func fileURL(seed: UInt64) throws -> URL {
        try directoryURL().appendingPathComponent("\(seed).json")
    }

    /// The stored record for `seed`, or nil. Undecodable files are absent.
    static func load(seed: UInt64) -> MedalRecord? {
        guard let url = try? fileURL(seed: seed),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(MedalRecord.self, from: data),
              record.seed == seed
        else { return nil }
        return record
    }

    /// Today's earned set on `seed` under the running build's identity.
    static func earned(seed: UInt64) -> Set<Medal> {
        MedalRecord.earned(load(seed: seed), seed: seed, identity: .current)
    }

    /// Adds `earned` to today's record and returns the medals new today.
    @discardableResult
    static func record(earned: [Medal], seed: UInt64, identity: ReplayIdentity = .current) -> Set<Medal> {
        let merged = MedalRecord.merging(load(seed: seed), earned: earned, seed: seed, identity: identity)
        guard !earned.isEmpty else { return [] }
        do {
            let directory = try directoryURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(merged.record).write(to: try fileURL(seed: seed), options: .atomic)
            let keep = "\(seed).json"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name != keep {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        } catch {
            return merged.new
        }
        return merged.new
    }
}
