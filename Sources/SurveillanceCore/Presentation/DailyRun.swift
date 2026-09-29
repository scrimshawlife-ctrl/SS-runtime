import Foundation

/// `run-shell.md` § 10.1 (D-081): one shared Camera layout per UTC day.
///
/// App shell, not simulation. The date is an input: nothing here reads a
/// clock. The derived seed enters the Replay Identity exactly like any other
/// seed, so the simulation never learns that a date was involved.
public struct DailyRun: Equatable, Sendable {
    /// A UTC calendar date.
    public struct Day: Equatable, Hashable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// The UTC calendar date containing `date`. Pure: the caller decides
        /// which instant to pass, and the App passes the moment Start is pressed.
        public init(utc date: Date) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            self.init(year: parts.year!, month: parts.month!, day: parts.day!)
        }

        /// § 10.1: `year * 10000 + month * 100 + day`, as UInt64.
        public var key: UInt64 {
            UInt64(year) * 10_000 + UInt64(month) * 100 + UInt64(day)
        }

        /// § 5: `YYYY-MM-DD`.
        public var label: String {
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    /// § 10.1 domain constant.
    public static let domain: UInt64 = 0x5353_4441_494C_5900

    public let day: Day
    public let seed: UInt64
    /// The salt that produced `seed`. Evidence only; never shown to a player.
    public let salt: UInt64

    /// § 10.1, exactly:
    ///
    /// ```text
    /// candidate = SplitMix64.mix(dayKey ^ 0x5353_4441_494C_5900 ^ salt),  salt = 0, 1, 2, …
    /// seed      = the first candidate whose camera placement selects and passes its runtime asserts
    /// ```
    public init(day: Day, arena: ArenaManifest) {
        self.init(day: day) { Self.placementPasses(seed: $0, arena: arena) }
    }

    /// The salt loop, over any placement test. Internal so tests can prove the
    /// loop takes the *first* passing salt without needing a day whose salt-0
    /// candidate the real arena rejects.
    init(day: Day, placementPasses: (UInt64) -> Bool) {
        var salt: UInt64 = 0
        while true {
            let candidate = Self.candidate(day: day, salt: salt)
            if placementPasses(candidate) {
                self.day = day
                self.seed = candidate
                self.salt = salt
                return
            }
            salt &+= 1
        }
    }

    /// Convenience over the bundled arena.
    public init(day: Day) throws {
        self.init(day: day, arena: try ArenaManifest.bundled())
    }

    /// § 5 title copy.
    public var titleLabel: String { Self.titleLabel(for: day) }

    public static func titleLabel(for day: Day) -> String {
        "DAILY RUN · \(day.label)"
    }

    public static func candidate(day: Day, salt: UInt64) -> UInt64 {
        SplitMix64.mix(day.key ^ domain ^ salt)
    }

    /// The same placement test `Simulation.init` applies, in the same order:
    /// the Player takes the first entity ID, then the Cameras are selected and
    /// checked. A seed that passes here is one `Simulation.make` accepts.
    public static func placementPasses(seed: UInt64, arena: ArenaManifest) -> Bool {
        var allocator = EntityAllocator()
        _ = allocator.next()
        guard let cameras = CameraPlacement.select(
            sockets: arena.cameraSockets,
            geometry: arena.standardCameraGeometry,
            runSeed: seed,
            allocator: &allocator
        ) else { return false }
        return CameraPlacement.selectedSetPassesRuntimeAsserts(cameras)
    }
}
