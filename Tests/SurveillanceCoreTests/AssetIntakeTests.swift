import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct AssetIntakeChecks {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func assetIntakeAcceptsPulledEvidenceAndExcludesArtSourcesFromRuntime() throws {
        let catalog = try AssetCatalog.bundled()
        let issues = try AssetIntake.validate(catalog: catalog, evidenceRoot: repoRoot())
        #expect(issues.isEmpty)
        // A runtimePath now exists only on an admitted legacy asset, and never
        // points back into the evidence tree.
        for entry in catalog.entries where entry.record.runtimePath != nil {
            // A runtimePath belongs only to admitted legacy or a delivered
            // original, and never points back into the evidence tree.
            #expect(
                entry.admissionDecision == .adaptedAdmitted
                    || entry.admissionDecision == .originalAccepted,
                "\(entry.record.assetId)"
            )
            #expect(
                entry.record.runtimePath?.hasPrefix("ArtSources/") == false,
                "\(entry.record.assetId)"
            )
        }
        #expect(
            catalog.entries.contains {
                $0.record.assetId == "legacy_san_francisco_landmark_bridge_distant_01"
                    && $0.admissionDecision == .rejected
            }
        )
    }

    @Test func assetIntakeRejectsDuplicateHashes() throws {
        let json = try JSONSerialization.jsonObject(with: SpecBundle.contract("asset-catalog-001")) as! [String: Any]
        var entries = json["entries"] as! [[String: Any]]
        let source = try #require(
            entries.first {
                (($0["record"] as? [String: Any])?["assetId"] as? String)
                    == "legacy_san_francisco_decal_cable_groove_01"
            }
        )
        var copy = source
        var record = copy["record"] as! [String: Any]
        record["assetId"] = "legacy_duplicate_hash_probe"
        copy["record"] = record
        copy["admissionDecision"] = "sfCandidate"
        entries.append(copy)
        var mutated = json
        mutated["entries"] = entries
        let catalog = try AssetCatalogLoader.decodeAndValidate(
            catalogJSON: JSONSerialization.data(withJSONObject: mutated),
            presentationJSON: SpecBundle.contract("presentation-assets-001")
        )
        let issues = try AssetIntake.validate(catalog: catalog, evidenceRoot: repoRoot())
        #expect(issues.contains { if case .duplicateHash = $0 { true } else { false } })
    }

    @Test func pulledSanFranciscoEvidenceHashesMatchCatalog() throws {
        let catalog = try AssetCatalog.bundled()
        let root = repoRoot()
        let groove = try #require(catalog.recordsByID["legacy_san_francisco_decal_cable_groove_01"])
        let grooveData = try Data(contentsOf: root.appendingPathComponent(groove.source!))
        #expect(SHA256.hex(Array(grooveData)) == groove.sha256)
        #expect(groove.dimensions == AssetDimensions(width: 256, height: 256))

        let fog = try #require(catalog.recordsByID["legacy_sfx_san_francisco_hidden_sensor_fog"])
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(fog.source!))
        let magic = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        #expect([UInt8](magic) == Array("caff".utf8))
        #expect(fog.sha256 == "d6e925e768222ebfcf5c0bd12cd3faef493f134105bb0a8f07003f842ece06e4")
    }

    @Test func deliveryPNGNameRejectsUnderscoreFreeStems() {
        #expect(AssetIntake.isValidDeliveryPNGName("player_idle@1x.png"))
        #expect(AssetIntake.isValidDeliveryPNGName("hud_extraction_ring@2x.png"))
        #expect(AssetIntake.isValidDeliveryPNGName("hud@1x.png") == false)
        #expect(AssetIntake.isValidDeliveryPNGName("Player_idle@1x.png") == false)
    }
}
