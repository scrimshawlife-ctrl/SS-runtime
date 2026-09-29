import Foundation
import SurveillanceCore

/// `run-shell.md` § 8 and § 10.2: the one stored run the app keeps — today's
/// best on the Daily Run seed — which exists only to drive the ghost.
///
/// Application Support, keyed by seed. Storing a best for a new seed removes
/// every other record, so the app never accumulates a run history (§ 8: the
/// stored run "is never listed").
enum GhostStore {
    private static let subdirectory = "DailyGhost"

    static func directoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(subdirectory, isDirectory: true)
    }

    private static func fileURL(seed: UInt64) throws -> URL {
        try directoryURL().appendingPathComponent("\(seed).json")
    }

    /// The stored record for `seed`, or nil. A file that fails to decode is
    /// untrusted input and is treated as absent.
    static func load(seed: UInt64) -> GhostRecord? {
        guard let url = try? fileURL(seed: seed),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(GhostRecord.self, from: data),
              record.seed == seed
        else { return nil }
        return record
    }

    /// Stores `record` when it beats the stored best on its seed and Replay
    /// Identity. Returns true when it was stored.
    @discardableResult
    static func storeIfBest(_ record: GhostRecord) -> Bool {
        let stored = load(seed: record.seed)
        guard GhostRecord.replaces(
            stored,
            candidateTicks: record.ticks,
            seed: record.seed,
            identity: record.identity
        ) else { return false }
        do {
            let directory = try directoryURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: try fileURL(seed: record.seed), options: .atomic)
            let keep = "\(record.seed).json"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name != keep {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            return true
        } catch {
            return false
        }
    }
}
