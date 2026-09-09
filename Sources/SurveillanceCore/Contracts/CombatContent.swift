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

    public static func bundled() -> CombatContent {
        let data = BundledResource.data(name: "combat-content-001", subdirectory: "contracts")
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
            bossInitialDelay: try boss.int("initialDelay", within: "boss")
        )
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
