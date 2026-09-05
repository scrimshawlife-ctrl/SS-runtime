import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct CivicSeamIdentityTests {
    @Test func civicSeamT307SpineGridsWedgesAndLandmarks() throws {
        let arena = try ArenaManifest.bundled()
        #expect(CivicSeamIdentity.zoneNamesMatchContract(arena))
        #expect(CivicSeamIdentity.diagonalSpine(arena))
        #expect(CivicSeamIdentity.threeGridCollision(arena))
        #expect(CivicSeamIdentity.wedgeParcels(arena))
        #expect(CivicSeamIdentity.landmarkSightlines(arena))
    }

    @Test func civicSeamT308IdentityOmitsLiteralMapLabels() throws {
        let catalog = try AssetCatalog.bundled()
        #expect(CivicSeamIdentity.presentationOmitsProhibitedLabels())
        #expect(CivicSeamIdentity.catalogRejectsLiteralLandmarks(catalog))
        // Admitted legacy assets now carry a runtimePath, so the identity
        // guarantee is stated directly: nothing rejected or excluded ships, and
        // no literal landmark, seal, or logo reaches the bundle.
        for entry in catalog.entries where entry.record.runtimePath != nil {
            #expect(
                entry.admissionDecision == .adaptedAdmitted
                    || entry.admissionDecision == .originalAccepted,
                "\(entry.record.assetId)"
            )
            let id = entry.record.assetId.lowercased()
            #expect(!id.contains("landmark"), "\(entry.record.assetId)")
            #expect(!id.contains("_seal_"), "\(entry.record.assetId)")
            #expect(!id.contains("_logo_"), "\(entry.record.assetId)")
            #expect(!id.contains("bridge"), "\(entry.record.assetId)")
        }
    }
}
