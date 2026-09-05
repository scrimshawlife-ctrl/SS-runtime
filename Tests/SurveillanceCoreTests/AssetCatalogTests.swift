import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct AssetCatalogTests {
    @Test func bundledAssetCatalogFailsClosedAndCoversPresentationIDs() throws {
        let catalog = try AssetCatalog.bundled()
        #expect(catalog.legacyCommit == LegacyEvidence.commit)
        #expect(catalog.specificationCommit == ContractVersions.specificationCommit)
        // Since the LC-009/LC-010 bounded ADAPT amendment, accepted entries
        // exist. Every one must be an admitted legacy asset with complete
        // provenance — nothing may be accepted on any other footing.
        for entry in catalog.entries where entry.record.productionStatus == .accepted {
            // Accepted means admitted legacy or a delivered original; nothing
            // else may be accepted.
            #expect(
                entry.admissionDecision == .adaptedAdmitted
                    || entry.admissionDecision == .originalAccepted,
                "\(entry.record.assetId)"
            )
            if entry.admissionDecision == .adaptedAdmitted {
                #expect(entry.record.provenance == .adaptedLegacy, "\(entry.record.assetId)")
                #expect(entry.record.source?.hasPrefix("legacy://") == true, "\(entry.record.assetId)")
            } else {
                #expect(entry.record.provenance == .projectOriginal, "\(entry.record.assetId)")
            }
            #expect(entry.record.sha256?.count == 64, "\(entry.record.assetId)")
            #expect(entry.record.license?.isEmpty == false, "\(entry.record.assetId)")
            #expect(entry.record.runtimePath?.isEmpty == false, "\(entry.record.assetId)")
        }

        let presentation = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("presentation-assets-001")
        ) as! [String: Any]
        let required = (presentation["requiredAssetIds"] as! [String]) + (presentation["audioEventIds"] as! [String])
        #expect(required.count == 52)
        // Every required presentation ID is accounted for, either by a planned
        // original still to be produced or by an admitted legacy asset.
        for id in required {
            let entry = try #require(catalog.entries.first { $0.record.assetId == id })
            #expect(entry.record.runtimeRequired, "\(id)")
            switch entry.admissionDecision {
            case .plannedOriginal:
                #expect(entry.record.productionStatus == .planned, "\(id)")
                #expect(entry.record.provenance == .projectOriginal, "\(id)")
                #expect(entry.record.source == nil, "\(id)")
                #expect(entry.record.runtimePath == nil, "\(id)")
                #expect(entry.record.sha256 == nil, "\(id)")
            case .adaptedAdmitted:
                #expect(entry.record.productionStatus == .accepted, "\(id)")
                #expect(entry.record.provenance == .adaptedLegacy, "\(id)")
                #expect(entry.record.sha256?.count == 64, "\(id)")
            case .originalAccepted:
                #expect(entry.record.productionStatus == .accepted, "\(id)")
                #expect(entry.record.provenance == .projectOriginal, "\(id)")
                #expect(entry.record.sha256?.count == 64, "\(id)")
            case .excluded, .rejected, .sfCandidate:
                Issue.record("required presentation id \(id) is not admissible")
            }
        }

        let sfVisual = catalog.entries.filter {
            $0.record.assetId.hasPrefix("legacy_san_francisco_") && $0.record.kind == .sprite
        }
        #expect(sfVisual.count == 13)
        let bridge = try #require(
            sfVisual.first { $0.record.assetId == "legacy_san_francisco_landmark_bridge_distant_01" }
        )
        #expect(bridge.admissionDecision == .rejected)
        #expect(sfVisual.filter { $0.admissionDecision == .sfCandidate }.count == 12)

        let atlanta = try #require(
            catalog.entries.first { $0.record.assetId == "legacy_atlanta_decal_beltline_stripe_01" }
        )
        #expect(atlanta.admissionDecision == .excluded)
        #expect(atlanta.record.runtimeRequired == false)

        let fog = try #require(
            catalog.entries.first { $0.record.assetId == "legacy_sfx_san_francisco_hidden_sensor_fog" }
        )
        #expect(fog.admissionDecision == .rejected)
        #expect(fog.record.sha256 == "d6e925e768222ebfcf5c0bd12cd3faef493f134105bb0a8f07003f842ece06e4")
    }

    @Test func excludedOrAcceptedWithoutHashCatalogsFailClosed() throws {
        let good = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("asset-catalog-001")
        ) as! [String: Any]
        let presentation = SpecBundle.contract("presentation-assets-001")

        func encode(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }

        var badSchema = good
        badSchema["schemaVersion"] = "asset-catalog-000"
        do {
            _ = try AssetCatalogLoader.decodeAndValidate(
                catalogJSON: encode(badSchema),
                presentationJSON: presentation
            )
            Issue.record("expected schema failure")
            return
        } catch AssetCatalogError.schemaVersion {
        }

        var accepted = good
        var entries = accepted["entries"] as! [[String: Any]]
        var record = entries[0]["record"] as! [String: Any]
        record["productionStatus"] = "accepted"
        record["runtimeRequired"] = false
        record["sha256"] = NSNull()
        record["license"] = "x"
        record["source"] = "x"
        record["runtimePath"] = "RuntimeAssets/x.png"
        entries[0]["record"] = record
        accepted["entries"] = entries
        do {
            _ = try AssetCatalogLoader.decodeAndValidate(
                catalogJSON: encode(accepted),
                presentationJSON: presentation
            )
            Issue.record("expected accepted-without-hash failure")
            return
        } catch AssetCatalogError.acceptedWithoutProvenance("legacy_atlanta_decal_beltline_stripe_01") {
        }

        var excludedRequired = good
        var excludedEntries = excludedRequired["entries"] as! [[String: Any]]
        var excludedRecord = excludedEntries[0]["record"] as! [String: Any]
        excludedRecord["runtimeRequired"] = true
        excludedEntries[0]["record"] = excludedRecord
        excludedRequired["entries"] = excludedEntries
        do {
            _ = try AssetCatalogLoader.decodeAndValidate(
                catalogJSON: encode(excludedRequired),
                presentationJSON: presentation
            )
            Issue.record("expected excluded runtimeRequired failure")
            return
        } catch AssetCatalogError.excludedRuntimeRequired("legacy_atlanta_decal_beltline_stripe_01") {
        }
    }
}
