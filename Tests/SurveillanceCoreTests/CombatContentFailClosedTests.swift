import Foundation
import Testing
@testable import SurveillanceCore

/// S3: combat content loading fails closed. Every `as!` in
/// `CombatContent.decode` became a typed `CombatContentError` that names the
/// field that failed, so a malformed `combat-content-004` payload is reported
/// by field path instead of crashing the kernel at an untyped cast.
@Suite(.serialized)
struct CombatContentFailClosedTests {
    /// D-090 values (`combat-content-004`): Integrity x1.5, the boss 1600
    /// with bands 1200/800/400/1, the patrol block, and the Player's 50%.
    @Test func bundledContentStillDecodesWithKnownValues() {
        let content = CombatContent.bundled()
        #expect(content.bossHP == 1600)
        #expect(content.bossPhaseBands.minHp == [1200, 800, 400, 1])
        #expect(content.eliteHP == 450)
        #expect(content.standardEnemies.count == 5)
        #expect(content.standardEnemies.mapValues(\.hp) == [
            .fogAnalyticsCloud: 30, .cableCarCorrelator: 60, .sutroSignalWitch: 45,
            .autonomousInformant: 30, .victorianVendor: 90
        ])
        #expect(content.patrol == PatrolSpec(
            speedPercent: 40, dwellTicks: 30, sightUnits: 240, sightHalfAngleMilliDegrees: 45_000, arrivalUnits: 4
        ))
        #expect(content.player.damageTakenPercent == 50)
        #expect(content.encounters["M-A"]?.totals == 14)
        #expect(content.encounters["M-B"]?.totals == 17)
        #expect(content.encounters["M-C"]?.totals == 25)
    }

    @Test func invalidJSONThrowsInvalidJSON() {
        let error = Self.decodingError(json: "not json at all")
        #expect(error == .invalidJSON)
    }

    @Test func nonObjectRootThrowsInvalidJSON() {
        let error = Self.decodingError(json: "[1, 2, 3]")
        #expect(error == .invalidJSON)
    }

    @Test func malformedBossSectionThrowsTypedErrorNamingTheField() {
        // `boss.hp` is a string: the old `as! Int` here would have crashed.
        let error = Self.decodingError(json: """
        {"boss":{"hp":"eight hundred"},
         "elite":{"hp":300,"radius":26,"speed":108,"contactDps":14,"spawnDelay":90},
         "standardEnemies":{},"encounters":{}}
        """)
        #expect(error == .wrongType("boss.hp"))
    }

    @Test func missingEliteFieldThrowsTypedErrorNamingTheField() {
        let error = Self.decodingError(json: """
        {"boss":{},"standardEnemies":{},"encounters":{},"elite":{"hp":300}}
        """)
        #expect(error == .missingField("elite.radius"))
    }

    @Test func unknownArchetypeThrowsTypedErrorNamingTheKey() {
        let error = Self.decodingError(json: """
        {"boss":{},"encounters":{},"elite":{},
         "standardEnemies":{"phantomCritic":{"hp":1,"radius":1,"speed":1,"contactDps":1}}}
        """)
        #expect(error == .unknownArchetype("phantomCritic"))
    }

    @Test func malformedWaveMemberThrowsTypedErrorNamingThePath() {
        let error = Self.decodingError(json: """
        {"boss":{},"elite":{},"standardEnemies":{},
         "encounters":{"M-X":{"zone":"Z-99","totals":1,
            "waves":[{"id":"X1","interval":30,"members":{"autonomousInformant":"three"}}]}}}
        """)
        #expect(error == .wrongType("encounters.M-X.waves[0].members.autonomousInformant"))
    }

    /// The bundled contract with `mutate` applied, decoded: the typed error,
    /// or nil if it decoded.
    private static func mutated(_ mutate: (inout [String: Any]) -> Void) -> CombatContentError? {
        var root = (try? JSONSerialization.jsonObject(
            with: BundledResource.data(name: "combat-content-004", subdirectory: "contracts")
        )) as? [String: Any] ?? [:]
        mutate(&root)
        do {
            _ = try CombatContent.decode(try JSONSerialization.data(withJSONObject: root))
            return nil
        } catch {
            return error as? CombatContentError
        }
    }

    private static func withKey(_ block: String, _ key: String, _ value: Any?) -> CombatContentError? {
        mutated { root in
            var inner = root[block] as? [String: Any] ?? [:]
            inner[key] = value
            root[block] = inner
        }
    }

    /// D-091 `patrol`: every key required and a strict integer; no other
    /// key; a half-angle the integer cone test cannot express is refused.
    @Test func patrolBlockFailsClosed() {
        #expect(Self.mutated { $0["patrol"] = nil } == .missingField("patrol"))
        #expect(Self.mutated { $0["patrol"] = [40] } == .wrongType("patrol"))
        for key in ["speedPercent", "dwellTicks", "sightUnits", "sightHalfAngleMilliDegrees", "arrivalUnits"] {
            #expect(Self.withKey("patrol", key, nil) == .missingField("patrol.\(key)"), "\(key)")
            #expect(Self.withKey("patrol", key, "1") == .wrongType("patrol.\(key)"), "\(key)")
            #expect(Self.withKey("patrol", key, true) == .wrongType("patrol.\(key)"), "\(key)")
            #expect(Self.withKey("patrol", key, 1.5) == .wrongType("patrol.\(key)"), "\(key)")
        }
        #expect(Self.withKey("patrol", "speedPercent", 0) == .wrongType("patrol.speedPercent"))
        #expect(Self.withKey("patrol", "dwellTicks", -1) == .wrongType("patrol.dwellTicks"))
        #expect(Self.withKey("patrol", "sightHalfAngleMilliDegrees", 44_000) == .wrongType("patrol.sightHalfAngleMilliDegrees"))
        #expect(Self.withKey("patrol", "sightRange", 240) == .wrongType("patrol.sightRange"))
        #expect(Self.withKey("patrol", "sightHalfAngleMilliDegrees", 30_000) == nil, "30 degrees is exact")
    }

    /// D-090 `player`: `damageTakenPercent` required, a strict integer 0-100.
    @Test func playerBlockFailsClosed() {
        #expect(Self.mutated { $0["player"] = nil } == .missingField("player"))
        #expect(Self.withKey("player", "damageTakenPercent", nil) == .missingField("player.damageTakenPercent"))
        #expect(Self.withKey("player", "damageTakenPercent", 101) == .wrongType("player.damageTakenPercent"))
        #expect(Self.withKey("player", "damageTakenPercent", -1) == .wrongType("player.damageTakenPercent"))
        #expect(Self.withKey("player", "damageTakenPercent", 50.5) == .wrongType("player.damageTakenPercent"))
        #expect(Self.withKey("player", "damageTakenPercent", true) == .wrongType("player.damageTakenPercent"))
        #expect(Self.withKey("player", "invulnerable", false) == .wrongType("player.invulnerable"))
    }

    /// bosses.md phase bands come from `boss.phases[].minHp`: four phases in
    /// order, strictly decreasing, the first within the boss HP, the last 1.
    @Test func bossPhaseBandsFailClosed() {
        func phases(_ edit: (inout [[String: Any]]) -> Void) -> CombatContentError? {
            Self.mutated { root in
                var boss = root["boss"] as! [String: Any]
                var list = boss["phases"] as! [[String: Any]]
                edit(&list)
                boss["phases"] = list
                root["boss"] = boss
            }
        }
        #expect(phases { _ in } == nil)
        #expect(phases { $0[1]["minHp"] = nil } == .missingField("boss.phases[1].minHp"))
        #expect(phases { $0[1]["minHp"] = "800" } == .wrongType("boss.phases[1].minHp"))
        #expect(phases { $0[1]["minHp"] = 1300 } == .wrongType("boss.phases[1].minHp"), "not decreasing")
        #expect(phases { $0[0]["minHp"] = 1601 } == .wrongType("boss.phases[0].minHp"), "above boss HP")
        #expect(phases { $0[3]["minHp"] = 2 } == .wrongType("boss.phases[3].minHp"), "last band ends at 1")
        #expect(phases { $0.swapAt(1, 2) } == .wrongType("boss.phases[1].id"))
        #expect(phases { $0.removeLast() } == .wrongType("boss.phases"))
    }

    /// Decodes `json` and returns the `CombatContentError` it threw, or nil
    /// when decoding unexpectedly succeeds or throws a non-typed error.
    private static func decodingError(json: String) -> CombatContentError? {
        do {
            _ = try CombatContent.decode(Data(json.utf8))
            return nil
        } catch let error as CombatContentError {
            return error
        } catch {
            return nil
        }
    }
}
