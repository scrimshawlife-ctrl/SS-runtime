import Foundation

public enum ArchetypeID: String, Equatable, Sendable, Codable, CaseIterable {
    case fogAnalyticsCloud
    case cableCarCorrelator
    case sutroSignalWitch
    case autonomousInformant
    case victorianVendor
    case improperSearchDaemon
    case algorithmicModerate
}

public enum UpgradeID: String, Equatable, Sendable, CaseIterable {
    case signalJammer
    case ricochetPulse
    case ghostStep

    public var selectionIndex: UInt8 {
        switch self {
        case .signalJammer: 0
        case .ricochetPulse: 1
        case .ghostStep: 2
        }
    }

    public static func from(index: UInt8) -> UpgradeID? {
        switch index {
        case 0: .signalJammer
        case 1: .ricochetPulse
        case 2: .ghostStep
        default: nil
        }
    }
}

public struct StandardEnemyStats: Equatable, Sendable {
    public var hp: Int
    public var radius: Int
    public var speed: Int
    public var contactDps: Int
    public var pulse: Pulse?
    public var charge: Charge?
    public var shot: Shot?
    public var range: [Int]?
    public var mine: Mine?

    public struct Pulse: Equatable, Sendable {
        public var first: Int
        public var cooldown: Int
        public var telegraph: Int
        public var range: Int
        public var exposure: Int
    }

    public struct Charge: Equatable, Sendable {
        public var first: Int
        public var cooldown: Int
        public var telegraph: Int
        public var ticks: Int
        public var speed: Int
        public var recover: Int
    }

    public struct Shot: Equatable, Sendable {
        public var first: Int
        public var cooldown: Int
        public var telegraph: Int
        public var speed: Int
        public var radius: Int
        public var lifetime: Int
        public var damage: Int
    }

    public struct Mine: Equatable, Sendable {
        public var first: Int
        public var cooldown: Int
        public var telegraph: Int
        public var maximum: Int
        public var arm: Int
        public var lifetime: Int
        public var radius: Int
        public var damage: Int
    }
}

public struct WaveMember: Equatable, Sendable {
    public var archetype: ArchetypeID
    public var count: Int
}

public struct WaveSpec: Equatable, Sendable {
    public var id: String
    public var interval: Int
    public var delay: Int
    public var members: [WaveMember]
}

/// `combat-content-005` `heat` (D-083): Autonomous Informants appended to an
/// M-A or M-B wave by the Detection State read when the wave starts.
public struct HeatSpec: Equatable, Sendable {
    public var reinforcementArchetype: ArchetypeID
    public var encounters: [String]
    public var byDetectionState: [DetectionState: Int]

    /// Informants appended to a wave of `encounter` that starts while
    /// `state`. Zero for any encounter the block does not name (M-C). The
    /// table covers every Detection State, `lockdown` included (D-084,
    /// EN-015), and decoding requires all five.
    public func reinforcements(encounter: String, state: DetectionState) -> Int {
        guard encounters.contains(encounter) else { return 0 }
        return byDetectionState[state] ?? 0
    }
}

/// `combat-content-005` `awareness` (D-089, `enemies-and-encounters.md`
/// § Awareness): which standard enemies can be unaware, how they become
/// alerted, and the ambush multiplier.
public struct AwarenessSpec: Equatable, Sendable {
    /// The archetypes that can spawn unaware. Never the elite or the boss.
    public var appliesTo: [ArchetypeID]
    /// Sight radius, inclusive, in arena units.
    public var sightRangeUnits: Int
    /// One-hop ally alert radius, inclusive, in arena units.
    public var allyAlertRadiusUnits: Int
    /// The Detection State at or above which surveillance alerts every
    /// unaware enemy, and at or above which a standard enemy spawns aware.
    public var surveillanceAlertState: DetectionState
    /// The first damage an unaware enemy takes is multiplied by this.
    public var ambushDamageMultiplier: Int
    /// Encounters whose enemies always spawn aware (M-C).
    public var awareEncounters: [String]
    /// Heat reinforcements (D-083) spawn aware.
    public var heatReinforcementsSpawnAware: Bool
    /// D-090 drift: an unaware encounter enemy moves toward its encounter's
    /// trigger centre at this percent of its archetype speed...
    public var unawareDriftPercent: Int
    /// ...and stops once it is within this many units of that centre.
    public var unawareDriftStopUnits: Int

    /// True when `state` is `surveillanceAlertState` or above.
    public func surveillanceAlerts(_ state: DetectionState) -> Bool {
        Self.rank(state) >= Self.rank(surveillanceAlertState)
    }

    /// Detection States in escalation order.
    static let order: [DetectionState] = [.hidden, .observed, .tracked, .hunted, .lockdown]

    static func rank(_ state: DetectionState) -> Int {
        order.firstIndex(of: state)!
    }

    /// Whether a standard enemy spawned now starts aware
    /// (`enemies-and-encounters.md` § Awareness, Spawning). `state` is the
    /// Detection State resolved after the previous tick.
    public func spawnsAware(
        archetype: ArchetypeID,
        encounter: String,
        state: DetectionState,
        heatReinforcement: Bool
    ) -> Bool {
        !appliesTo.contains(archetype)
            || surveillanceAlerts(state)
            || awareEncounters.contains(encounter)
            || (heatReinforcement && heatReinforcementsSpawnAware)
    }
}

/// `combat-content-005` `patrol` (D-091, `enemies-and-encounters.md`
/// § Transit Patrol): how an unaware patrol member moves and sees. The routes
/// themselves are arena data (`civic-seam-arena-004` `patrols`).
public struct PatrolSpec: Equatable, Sendable {
    /// A member's spawn Integrity, as a percent of its archetype's (D-093).
    public var integrityPercent: Int
    /// Patrol speed, as a percent of the member's archetype speed.
    public var speedPercent: Int
    /// Ticks a member holds at each waypoint it reaches.
    public var dwellTicks: Int
    /// Cone sight range, inclusive, in arena units.
    public var sightUnits: Int
    /// Cone half-angle about the member's facing.
    public var sightHalfAngleMilliDegrees: Int
    /// A member within this many units of its waypoint has arrived.
    public var arrivalUnits: Int

    /// The half-angles whose squared cosine is an exact small fraction, so
    /// the cone stays the D-082 integer test (`dot > 0` and
    /// `denominator · dot² ≥ numerator · |f|² · |d|²`). Any other half-angle
    /// is refused at decode rather than approximated.
    static let exactCosineSquared: [Int: (numerator: UInt64, denominator: UInt64)] = [
        30_000: (3, 4),
        45_000: (1, 2),
        60_000: (1, 4)
    ]

    /// cos² of the half-angle as a fraction. Decoding guarantees it exists.
    public var cosineSquared: (numerator: UInt64, denominator: UInt64) {
        Self.exactCosineSquared[sightHalfAngleMilliDegrees]!
    }
}

/// `combat-content-005` `player` (D-090, `player-controller.md` § Damage
/// response).
public struct PlayerDamageSpec: Equatable, Sendable {
    /// Spawn Integrity, and the clamp's ceiling (D-092, 150).
    public var integrity: Int
    /// Every Integrity loss the Player would take is scaled by this percent,
    /// with an exact remainder in hundredths carried forward.
    public var damageTakenPercent: Int
    /// Captain Court threshold (D-096, bosses.md): on `bossActivated` the
    /// Player is raised to at least this percent of `integrity`, never
    /// lowered (60).
    public var courtThresholdRestorePercent: Int

    /// The Integrity floor the Captain Court threshold restores to:
    /// `integrity × courtThresholdRestorePercent / 100`, rounded down.
    public var courtThresholdIntegrity: Int {
        integrity * courtThresholdRestorePercent / 100
    }
}

/// `combat-content-005` `boss.phases[].minHp` (bosses.md): the lowest HP
/// after a damage batch at which each phase still holds.
public struct BossPhaseBands: Equatable, Sendable {
    /// Minimum HP of each phase, in `BossPhase.receiptOrder`, strictly
    /// decreasing, the last 1.
    public var minHp: [Int]

    public init(minHp: [Int]) {
        self.minHp = minHp
    }

    /// The phase for `hp` after the tick's damage batch.
    public func phase(hp: Int) -> BossPhase {
        for (index, floor) in minHp.enumerated() where hp >= floor {
            return BossPhase.receiptOrder[index]
        }
        return BossPhase.receiptOrder[BossPhase.receiptOrder.count - 1]
    }
}

public struct EncounterSpec: Equatable, Sendable {
    public var zone: String
    public var totals: Int
    public var activationExposure: Int?
    public var initialDelay: Int?
    public var waves: [WaveSpec]
}

/// Fail-closed combat content decoding (S3). Every malformed field throws a
/// `CombatContentError` that names the field path, so bad data can never be
/// force-cast into the kernel.
public enum CombatContentError: Equatable, Sendable, Error {
    /// The payload is not valid JSON, or does not decode to a JSON object.
    case invalidJSON
    /// A required field is absent at the given path, e.g. `"boss"`,
    /// `"standardEnemies.fogAnalyticsCloud.hp"`.
    case missingField(String)
    /// The value at the given path has the wrong shape or type, e.g.
    /// `"encounters.M-A.waves[0].members.autonomousInformant"`.
    case wrongType(String)
    /// A `standardEnemies` key or wave `members` entry names an archetype the
    /// kernel does not know, e.g. `"phantomCritic"`.
    case unknownArchetype(String)
}

extension CombatContentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "combat content is not a JSON object"
        case let .missingField(path):
            "combat content is missing required field \"\(path)\""
        case let .wrongType(path):
            "combat content field \"\(path)\" has the wrong type"
        case let .unknownArchetype(key):
            "combat content references unknown archetype \"\(key)\""
        }
    }
}

public struct CombatContent: Equatable, Sendable {
    public var standardEnemies: [ArchetypeID: StandardEnemyStats]
    public var encounters: [String: EncounterSpec]
    public var eliteHP: Int
    public var eliteRadius: Int
    public var eliteSpeed: Int
    public var eliteContactDps: Int
    public var eliteSpawnDelay: Int
    public var bossHP: Int
    public var bossRadius: Int
    public var bossSpeed: Int
    public var bossContactDps: Int
    public var bossInitialDelay: Int
    public var bossPhaseBands: BossPhaseBands
    public var heat: HeatSpec
    public var awareness: AwarenessSpec
    public var patrol: PatrolSpec
    public var player: PlayerDamageSpec

    public static func bundled() -> CombatContent {
        let data = BundledResource.data(name: "combat-content-005", subdirectory: "contracts")
        return try! decode(data)
    }

    public static func decode(_ data: Data) throws -> CombatContent {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CombatContentError.invalidJSON
            }
            root = object
        } catch let error as CombatContentError {
            throw error
        } catch {
            throw CombatContentError.invalidJSON
        }
        let elite = try decodeObject(root["elite"], path: "elite")
        let boss = try decodeObject(root["boss"], path: "boss")

        return CombatContent(
            standardEnemies: try parseEnemies(root["standardEnemies"]),
            encounters: try parseEncounters(root["encounters"]),
            eliteHP: try elite.int("hp", within: "elite"),
            eliteRadius: try elite.int("radius", within: "elite"),
            eliteSpeed: try elite.int("speed", within: "elite"),
            eliteContactDps: try elite.int("contactDps", within: "elite"),
            eliteSpawnDelay: try elite.int("spawnDelay", within: "elite"),
            bossHP: try boss.int("hp", within: "boss"),
            bossRadius: try boss.int("radius", within: "boss"),
            bossSpeed: try boss.int("baseSpeed", within: "boss"),
            bossContactDps: try boss.int("baseContactDps", within: "boss"),
            bossInitialDelay: try boss.int("initialDelay", within: "boss"),
            bossPhaseBands: try parseBossBands(boss["phases"], hp: try boss.int("hp", within: "boss")),
            heat: try parseHeat(root["heat"]),
            awareness: try parseAwareness(root["awareness"]),
            patrol: try parsePatrol(root["patrol"]),
            player: try parsePlayer(root["player"])
        )
    }

    /// `boss.phases`: exactly the four phases, in `BossPhase.receiptOrder`,
    /// each with an integer `minHp`, strictly decreasing, the first at most
    /// the boss HP and the last 1 (bosses.md: the last band ends at 1).
    private static func parseBossBands(_ raw: Any?, hp: Int) throws -> BossPhaseBands {
        let phases = try decodeArray(raw, path: "boss.phases")
        guard phases.count == BossPhase.receiptOrder.count else {
            throw CombatContentError.wrongType("boss.phases")
        }
        var floors: [Int] = []
        for (index, entry) in phases.enumerated() {
            let path = "boss.phases[\(index)]"
            let phase = try decodeObject(entry, path: path)
            guard try phase.string("id", within: path) == BossPhase.receiptOrder[index].rawValue else {
                throw CombatContentError.wrongType("\(path).id")
            }
            guard let value = phase["minHp"] else { throw CombatContentError.missingField("\(path).minHp") }
            guard !isJSONBool(value), let floor = value as? Int, floor >= 1, floor <= hp,
                  floors.last.map({ floor < $0 }) ?? true
            else {
                throw CombatContentError.wrongType("\(path).minHp")
            }
            floors.append(floor)
        }
        guard floors.last == 1 else { throw CombatContentError.wrongType("boss.phases[3].minHp") }
        return BossPhaseBands(minHp: floors)
    }

    /// A flat block of integers: every key required and exactly typed. An
    /// unknown key, a missing key, a JSON boolean, a non-integer, or a value
    /// below its minimum fails closed at `block.key`.
    private static func strictInts(
        _ raw: Any?,
        block name: String,
        minimums: [String: Int]
    ) throws -> [String: Int] {
        let block = try decodeObject(raw, path: name)
        for key in block.keys.sorted() where minimums[key] == nil {
            throw CombatContentError.wrongType("\(name).\(key)")
        }
        var values: [String: Int] = [:]
        for (key, minimum) in minimums.sorted(by: { $0.key < $1.key }) {
            guard let value = block[key] else { throw CombatContentError.missingField("\(name).\(key)") }
            guard !isJSONBool(value), let number = value as? Int, number >= minimum else {
                throw CombatContentError.wrongType("\(name).\(key)")
            }
            values[key] = number
        }
        return values
    }

    /// `patrol` (D-091). The half-angle must be one the integer cone test can
    /// express exactly (`PatrolSpec.exactCosineSquared`).
    private static func parsePatrol(_ raw: Any?) throws -> PatrolSpec {
        let values = try strictInts(raw, block: "patrol", minimums: [
            "integrityPercent": 1, "speedPercent": 1, "dwellTicks": 0, "sightUnits": 1,
            "sightHalfAngleMilliDegrees": 1, "arrivalUnits": 1
        ])
        let half = values["sightHalfAngleMilliDegrees"]!
        guard PatrolSpec.exactCosineSquared[half] != nil else {
            throw CombatContentError.wrongType("patrol.sightHalfAngleMilliDegrees")
        }
        return PatrolSpec(
            integrityPercent: values["integrityPercent"]!,
            speedPercent: values["speedPercent"]!,
            dwellTicks: values["dwellTicks"]!,
            sightUnits: values["sightUnits"]!,
            sightHalfAngleMilliDegrees: half,
            arrivalUnits: values["arrivalUnits"]!
        )
    }

    /// `player`: Integrity (D-092, at least 1), the damage-taken percent
    /// (D-090, 0 through 100), and the Captain Court threshold restore
    /// percent (D-096, 0 through 100).
    private static func parsePlayer(_ raw: Any?) throws -> PlayerDamageSpec {
        let values = try strictInts(raw, block: "player", minimums: [
            "integrity": 1, "damageTakenPercent": 0, "courtThresholdRestorePercent": 0
        ])
        let percent = values["damageTakenPercent"]!
        guard percent <= 100 else { throw CombatContentError.wrongType("player.damageTakenPercent") }
        let restore = values["courtThresholdRestorePercent"]!
        guard restore <= 100 else { throw CombatContentError.wrongType("player.courtThresholdRestorePercent") }
        return PlayerDamageSpec(
            integrity: values["integrity"]!,
            damageTakenPercent: percent,
            courtThresholdRestorePercent: restore
        )
    }

    private static let awarenessKeys: Set<String> = [
        "appliesTo", "sightRangeUnits", "allyAlertRadiusUnits", "surveillanceAlertState",
        "ambushDamageMultiplier", "awareEncounters", "heatReinforcementsSpawnAware",
        "unawareDriftPercent", "unawareDriftStopUnits"
    ]

    /// Every field is required and exactly typed; an unknown key, a
    /// non-standard archetype (the elite and the boss are always aware), a
    /// JSON boolean where a number belongs, or a number where a boolean
    /// belongs fails closed.
    private static func parseAwareness(_ raw: Any?) throws -> AwarenessSpec {
        let block = try decodeObject(raw, path: "awareness")
        for key in block.keys.sorted() where !awarenessKeys.contains(key) {
            throw CombatContentError.wrongType("awareness.\(key)")
        }
        for key in awarenessKeys.sorted() where block[key] == nil {
            throw CombatContentError.missingField("awareness.\(key)")
        }
        guard let names = block["appliesTo"] as? [String] else {
            throw CombatContentError.wrongType("awareness.appliesTo")
        }
        var appliesTo: [ArchetypeID] = []
        for name in names {
            guard let archetype = ArchetypeID(rawValue: name) else {
                throw CombatContentError.unknownArchetype(name)
            }
            guard archetype != .improperSearchDaemon, archetype != .algorithmicModerate else {
                throw CombatContentError.wrongType("awareness.appliesTo")
            }
            appliesTo.append(archetype)
        }
        func strictInt(_ key: String, minimum: Int) throws -> Int {
            let value = block[key]
            guard !isJSONBool(value), let number = value as? Int, number >= minimum else {
                throw CombatContentError.wrongType("awareness.\(key)")
            }
            return number
        }
        guard let stateName = block["surveillanceAlertState"] as? String,
              let alertState = DetectionState(rawValue: stateName)
        else {
            throw CombatContentError.wrongType("awareness.surveillanceAlertState")
        }
        guard let encounters = block["awareEncounters"] as? [String] else {
            throw CombatContentError.wrongType("awareness.awareEncounters")
        }
        let spawnAware = block["heatReinforcementsSpawnAware"]
        guard isJSONBool(spawnAware), let reinforcementsAware = spawnAware as? Bool else {
            throw CombatContentError.wrongType("awareness.heatReinforcementsSpawnAware")
        }
        return AwarenessSpec(
            appliesTo: appliesTo,
            sightRangeUnits: try strictInt("sightRangeUnits", minimum: 1),
            allyAlertRadiusUnits: try strictInt("allyAlertRadiusUnits", minimum: 0),
            surveillanceAlertState: alertState,
            ambushDamageMultiplier: try strictInt("ambushDamageMultiplier", minimum: 1),
            awareEncounters: encounters,
            heatReinforcementsSpawnAware: reinforcementsAware,
            unawareDriftPercent: try strictInt("unawareDriftPercent", minimum: 0),
            unawareDriftStopUnits: try strictInt("unawareDriftStopUnits", minimum: 0)
        )
    }

    /// `JSONSerialization` bridges both JSON booleans and numbers to
    /// `NSNumber`, so `as? Int` accepts `true` and `as? Bool` accepts `1`.
    /// The CoreFoundation type tells them apart.
    private static func isJSONBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// All five Detection States are required; any other key fails closed.
    private static func parseHeat(_ raw: Any?) throws -> HeatSpec {
        let heat = try decodeObject(raw, path: "heat")
        let archetypeKey = try heat.string("reinforcementArchetype", within: "heat")
        guard let archetype = ArchetypeID(rawValue: archetypeKey) else {
            throw CombatContentError.unknownArchetype(archetypeKey)
        }
        guard let rawEncounters = heat["encounters"] else {
            throw CombatContentError.missingField("heat.encounters")
        }
        guard let encounters = rawEncounters as? [String] else {
            throw CombatContentError.wrongType("heat.encounters")
        }
        let table = try decodeDictionary(heat["byDetectionState"], path: "heat.byDetectionState")
        var counts: [DetectionState: Int] = [:]
        for key in table.keys.sorted() {
            guard let state = DetectionState(rawValue: key),
                  let value = table[key] as? Int, value >= 0
            else {
                throw CombatContentError.wrongType("heat.byDetectionState.\(key)")
            }
            counts[state] = value
        }
        for state in [DetectionState.hidden, .observed, .tracked, .hunted, .lockdown] where counts[state] == nil {
            throw CombatContentError.missingField("heat.byDetectionState.\(state.rawValue)")
        }
        return HeatSpec(reinforcementArchetype: archetype, encounters: encounters, byDetectionState: counts)
    }

    private static func parseEnemies(_ raw: Any?) throws -> [ArchetypeID: StandardEnemyStats] {
        let enemies = try decodeDictionary(raw, path: "standardEnemies")
        var stats: [ArchetypeID: StandardEnemyStats] = [:]
        for key in enemies.keys.sorted() {
            guard let archetype = ArchetypeID(rawValue: key) else {
                throw CombatContentError.unknownArchetype(key)
            }
            stats[archetype] = try parseEnemy(enemies[key], path: "standardEnemies.\(key)")
        }
        return stats
    }

    private static func parseEncounters(_ raw: Any?) throws -> [String: EncounterSpec] {
        let encounters = try decodeDictionary(raw, path: "encounters")
        var specs: [String: EncounterSpec] = [:]
        for key in encounters.keys.sorted() {
            specs[key] = try parseEncounter(encounters[key], path: "encounters.\(key)")
        }
        return specs
    }

    private static func parseEnemy(_ raw: Any?, path: String) throws -> StandardEnemyStats {
        let enemy = try decodeObject(raw, path: path)
        return StandardEnemyStats(
            hp: try enemy.int("hp", within: path),
            radius: try enemy.int("radius", within: path),
            speed: try enemy.int("speed", within: path),
            contactDps: try enemy.int("contactDps", within: path),
            pulse: try enemy.pulse(within: path),
            charge: try enemy.charge(within: path),
            shot: try enemy.shot(within: path),
            range: try enemy.optionalInts("range", within: path),
            mine: try enemy.mine(within: path)
        )
    }

    private static func parseEncounter(_ raw: Any?, path: String) throws -> EncounterSpec {
        let encounter = try decodeObject(raw, path: path)
        let waveObjects = try decodeArray(encounter["waves"], path: "\(path).waves")
        var waves: [WaveSpec] = []
        for (index, waveRaw) in waveObjects.enumerated() {
            let wavePath = "\(path).waves[\(index)]"
            let wave = try decodeObject(waveRaw, path: wavePath)
            let members = try parseMembers(wave["members"], path: wavePath)
            waves.append(WaveSpec(
                id: try wave.string("id", within: wavePath),
                interval: try wave.int("interval", within: wavePath),
                delay: try wave.optionalInt("delay", within: wavePath) ?? 0,
                members: members
            ))
        }
        return EncounterSpec(
            zone: try encounter.string("zone", within: path),
            totals: try encounter.int("totals", within: path),
            activationExposure: try encounter.optionalInt("activationExposure", within: path),
            initialDelay: try encounter.optionalInt("initialDelay", within: path),
            waves: waves
        )
    }

    private static func parseMembers(_ raw: Any?, path: String) throws -> [WaveMember] {
        let members = try decodeDictionary(raw, path: "\(path).members")
        var result: [WaveMember] = []
        for key in members.keys.sorted() {
            guard let archetype = ArchetypeID(rawValue: key) else {
                throw CombatContentError.unknownArchetype(key)
            }
            result.append(WaveMember(archetype: archetype, count: try members.count(key, within: path)))
        }
        return result
    }
}

private extension [String: Any] {
    /// The value of `field` as a required `Int`, at `within.field`.
    func int(_ field: String, within: String) throws -> Int {
        guard let raw = self[field] else {
            throw CombatContentError.missingField("\(within).\(field)")
        }
        guard let value = raw as? Int else {
            throw CombatContentError.wrongType("\(within).\(field)")
        }
        return value
    }

    /// The value of `field` as a required `String`, at `within.field`.
    func string(_ field: String, within: String) throws -> String {
        guard let raw = self[field] else {
            throw CombatContentError.missingField("\(within).\(field)")
        }
        guard let value = raw as? String else {
            throw CombatContentError.wrongType("\(within).\(field)")
        }
        return value
    }

    /// The value of `field` as an `Int`, nil when the field is absent. A
    /// present field of the wrong type throws.
    func optionalInt(_ field: String, within: String) throws -> Int? {
        guard let raw = self[field] else { return nil }
        guard let value = raw as? Int else {
            throw CombatContentError.wrongType("\(within).\(field)")
        }
        return value
    }

    /// The value of `field` as `[Int]`, nil when the field is absent. A
    /// present field of the wrong type throws.
    func optionalInts(_ field: String, within: String) throws -> [Int]? {
        guard let raw = self[field] else { return nil }
        guard let value = raw as? [Int] else {
            throw CombatContentError.wrongType("\(within).\(field)")
        }
        return value
    }

    /// The value of `field` as a required nested object, at `within.field`.
    func object(_ field: String, within: String) throws -> [String: Any] {
        guard let raw = self[field] else {
            throw CombatContentError.missingField("\(within).\(field)")
        }
        guard let value = raw as? [String: Any] else {
            throw CombatContentError.wrongType("\(within).\(field)")
        }
        return value
    }

    /// The optional `pulse` block of a standard enemy.
    func pulse(within path: String) throws -> StandardEnemyStats.Pulse? {
        guard self["pulse"] != nil else { return nil }
        let pulse = try object("pulse", within: path)
        return StandardEnemyStats.Pulse(
            first: try pulse.int("first", within: "\(path).pulse"),
            cooldown: try pulse.int("cooldown", within: "\(path).pulse"),
            telegraph: try pulse.int("telegraph", within: "\(path).pulse"),
            range: try pulse.int("range", within: "\(path).pulse"),
            exposure: try pulse.int("exposure", within: "\(path).pulse")
        )
    }

    /// The optional `charge` block of a standard enemy.
    func charge(within path: String) throws -> StandardEnemyStats.Charge? {
        guard self["charge"] != nil else { return nil }
        let charge = try object("charge", within: path)
        return StandardEnemyStats.Charge(
            first: try charge.int("first", within: "\(path).charge"),
            cooldown: try charge.int("cooldown", within: "\(path).charge"),
            telegraph: try charge.int("telegraph", within: "\(path).charge"),
            ticks: try charge.int("ticks", within: "\(path).charge"),
            speed: try charge.int("speed", within: "\(path).charge"),
            recover: try charge.int("recover", within: "\(path).charge")
        )
    }

    /// The optional `shot` block of a standard enemy.
    func shot(within path: String) throws -> StandardEnemyStats.Shot? {
        guard self["shot"] != nil else { return nil }
        let shot = try object("shot", within: path)
        return StandardEnemyStats.Shot(
            first: try shot.int("first", within: "\(path).shot"),
            cooldown: try shot.int("cooldown", within: "\(path).shot"),
            telegraph: try shot.int("telegraph", within: "\(path).shot"),
            speed: try shot.int("speed", within: "\(path).shot"),
            radius: try shot.int("radius", within: "\(path).shot"),
            lifetime: try shot.int("lifetime", within: "\(path).shot"),
            damage: try shot.int("damage", within: "\(path).shot")
        )
    }

    /// The optional `mine` block of a standard enemy.
    func mine(within path: String) throws -> StandardEnemyStats.Mine? {
        guard self["mine"] != nil else { return nil }
        let mine = try object("mine", within: path)
        return StandardEnemyStats.Mine(
            first: try mine.int("first", within: "\(path).mine"),
            cooldown: try mine.int("cooldown", within: "\(path).mine"),
            telegraph: try mine.int("telegraph", within: "\(path).mine"),
            maximum: try mine.int("maximum", within: "\(path).mine"),
            arm: try mine.int("arm", within: "\(path).mine"),
            lifetime: try mine.int("lifetime", within: "\(path).mine"),
            radius: try mine.int("radius", within: "\(path).mine"),
            damage: try mine.int("damage", within: "\(path).mine")
        )
    }

    /// The value of `key` in a wave `members` map, at `path.members.key`.
    func count(_ key: String, within path: String) throws -> Int {
        let field = "members.\(key)"
        guard let raw = self[key] else {
            throw CombatContentError.missingField("\(path).\(field)")
        }
        guard let value = raw as? Int else {
            throw CombatContentError.wrongType("\(path).\(field)")
        }
        return value
    }
}

private func decodeDictionary(_ raw: Any?, path: String) throws -> [String: Any] {
    guard let value = raw as? [String: Any] else {
        throw raw == nil
            ? CombatContentError.missingField(path)
            : CombatContentError.wrongType(path)
    }
    return value
}

private func decodeObject(_ raw: Any?, path: String) throws -> [String: Any] {
    guard let value = raw as? [String: Any] else {
        throw raw == nil
            ? CombatContentError.missingField(path)
            : CombatContentError.wrongType(path)
    }
    return value
}

private func decodeArray(_ raw: Any?, path: String) throws -> [Any] {
    guard let value = raw as? [Any] else {
        throw raw == nil
            ? CombatContentError.missingField(path)
            : CombatContentError.wrongType(path)
    }
    return value
}
