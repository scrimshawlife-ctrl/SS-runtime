import Foundation
import Testing
@testable import SurveillanceCore

/// S3: combat content loading fails closed. Every `as!` in
/// `CombatContent.decode` became a typed `CombatContentError` that names the
/// field that failed, so a malformed `combat-content-001` payload is reported
/// by field path instead of crashing the kernel at an untyped cast.
@Suite(.serialized)
struct CombatContentFailClosedTests {
    @Test func bundledContentStillDecodesWithKnownValues() {
        let content = CombatContent.bundled()
        #expect(content.bossHP == 800)
        #expect(content.eliteHP == 300)
        #expect(content.standardEnemies.count == 5)
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
