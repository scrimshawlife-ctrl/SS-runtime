import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct RuntimeBundleTests {
    @Test func runtimeBundleT805ProjectsOnlyReachablePlannedOriginals() throws {
        let catalog = try AssetCatalog.bundled()
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let projection = RuntimeBundleFilter.project(catalog: catalog, reachable: reachable)
        let eligible = catalog.entries
            .filter {
                $0.admissionDecision == .plannedOriginal
                    || $0.admissionDecision == .adaptedAdmitted
                    || $0.admissionDecision == .originalAccepted
            }
            .map(\.record.assetId)
            .sorted()
        #expect(projection.bundleAssetIds == eligible)
        #expect(projection.excludedAssetIds.count == catalog.entries.count - eligible.count)
        #expect(projection.bundleAssetIds.allSatisfy { reachable.contains($0) })
        // Nothing excluded, rejected, or merely an SF candidate may ship.
        #expect(
            catalog.entries.filter {
                $0.admissionDecision != .plannedOriginal
                    && $0.admissionDecision != .adaptedAdmitted
                    && $0.admissionDecision != .originalAccepted
            }.allSatisfy {
                !projection.bundleAssetIds.contains($0.record.assetId)
            }
        )
    }

    @Test func runtimeBundleT805BundledCatalogHasNoBundleViolations() throws {
        let catalog = try AssetCatalog.bundled()
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let issues = RuntimeBundleFilter.validate(catalog: catalog, reachable: reachable)
        #expect(issues.isEmpty)
    }

    @Test func runtimeBundleT805RejectsLegacyEvidenceWithRuntimePath() throws {
        let catalog = try AssetCatalog.bundled()
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        var record = try #require(catalog.recordsByID["legacy_san_francisco_decal_cable_groove_01"])
        record.runtimePath = "RuntimeAssets/legacy_san_francisco_decal_cable_groove_01.png"
        record.runtimeRequired = true
        let entry = AssetCatalogEntry(admissionDecision: .sfCandidate, record: record)
        var entries = catalog.entries.filter { $0.record.assetId != record.assetId }
        entries.append(entry)
        let mutated = AssetCatalog(
            schemaVersion: catalog.schemaVersion,
            legacyRepository: catalog.legacyRepository,
            legacyCommit: catalog.legacyCommit,
            specificationCommit: catalog.specificationCommit,
            entries: entries
        )
        let issues = RuntimeBundleFilter.validate(catalog: mutated, reachable: reachable)
        #expect(issues.contains(.legacyEvidenceInBundle(record.assetId)))
        #expect(issues.contains(.nonSanFranciscoInBundle(record.assetId)) == false)
    }

    @Test func runtimeBundleT807CatalogContentAuditPassesForBundledCatalog() throws {
        let catalog = try AssetCatalog.bundled()
        #expect(try CivicSeamIdentity.catalogPassesContentAudit(catalog))
        #expect(try CivicSeamIdentity.catalogContentAudit(catalog).isEmpty)
    }

    @Test func presentationAssetRegistryT801MatchesBundleProjection() throws {
        let catalog = try AssetCatalog.bundled()
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let projection = RuntimeBundleFilter.project(catalog: catalog, reachable: reachable)
        let registry = try PresentationAssetRegistry.bundled()
        #expect(registry.bundleAssetIds == projection.bundleAssetIds)
        #expect(registry.requiredVisualAssetIds.count == 28)
        #expect(registry.audioEventIds.count == 24)
        #expect(registry.contains("hud_exposure_bar"))
        #expect(registry.contains("legacy_san_francisco_decal_cable_groove_01") == false)
        #expect(try registry.require("control_dodge") == "control_dodge")
    }

    @Test func presentationAssetRegistryT801RejectsUnreachableAsset() throws {
        let registry = try PresentationAssetRegistry.bundled()
        do {
            _ = try registry.require("legacy_atlanta_decal_beltline_stripe_01")
            Issue.record("expected unreachable asset failure")
        } catch PresentationAssetRegistryError.unreachable(let id) {
            #expect(id == "legacy_atlanta_decal_beltline_stripe_01")
        }
    }
}
