import Foundation
import Testing
@testable import SurveillanceCore

/// `event-catalog-001` and `event-001.schema.json` against `EventType`: the
/// kernel publishes exactly the catalog's types at the catalog's ordinals,
/// and the schema admits every one of them (D-058 append-only, D-089
/// `enemyAlerted` at 290).
@Suite(.serialized)
struct EventCatalogTests {
    private static func contract(_ name: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: BundledResource.data(name: name, subdirectory: "contracts"))
                as? [String: Any]
        )
    }

    @Test func everyEventTypeMatchesTheCatalogOrdinal() throws {
        let catalog = try Self.contract("event-catalog-001")
        let events = try #require(catalog["events"] as? [[String: Any]])
        let byType = Dictionary(uniqueKeysWithValues: events.map { ($0["type"] as! String, $0["ordinal"] as! Int) })
        #expect(byType.count == EventType.allCases.count)
        for type in EventType.allCases {
            #expect(byType[type.rawValue] == type.ordinal, "\(type)")
        }
        let alerted = try #require(events.first { $0["type"] as? String == "enemyAlerted" })
        let payload = try #require(alerted["payload"] as? [String: Any])
        #expect(payload["required"] as? [String] == ["entityId", "cause"])
    }

    @Test func theEventSchemaAdmitsEveryTypeAndOrdinal() throws {
        let schema = try Self.contract("event-001.schema")
        let properties = try #require(schema["properties"] as? [String: Any])
        let types = try #require((properties["type"] as? [String: Any])?["enum"] as? [String])
        let ordinals = try #require((properties["ordinal"] as? [String: Any])?["enum"] as? [Int])
        for type in EventType.allCases {
            #expect(types.contains(type.rawValue), "\(type) is not in the schema's type enum")
            #expect(ordinals.contains(type.ordinal), "\(type.ordinal) is not in the schema's ordinal enum")
        }
    }

    @Test func alertCausesAreThePublishedVocabulary() {
        #expect(AlertCause.allCases.map(\.rawValue) == ["surveillance", "damage", "sight", "ally"])
    }
}
