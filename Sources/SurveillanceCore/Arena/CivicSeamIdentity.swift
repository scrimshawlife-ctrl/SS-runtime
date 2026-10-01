/// Civic Seam identity checks for T307/T308. Pinned `civic-seam-arena-004` coordinates are not rewritten.
public enum CivicSeamIdentity {
    public static let zoneIdentities: [(id: String, name: String)] = [
        ("Z-01", "Residential Wedge"),
        ("Z-02", "Transit Cut"),
        ("Z-03", "Civic Plaza"),
        ("Z-04", "Service Seam"),
        ("Z-05", "Grid Junction"),
        ("Z-06", "Authority Court"),
        ("Z-07", "Phoenix Steps")
    ]

    /// Four landmarks the diagonal spine must remain readable from (arena.md §12).
    public static let spineLandmarks = ["Z-02", "Z-03", "Z-06", "Z-07"]

    public static let prohibitedPlaceLabels = [
        "golden gate",
        "sutro",
        "karl",
        "market street",
        "civic center",
        "soma",
        "chinatown",
        "cable car"
    ]

    public static func zoneNamesMatchContract(_ manifest: ArenaManifest) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: manifest.zones.map { ($0.id, $0.name ?? "") })
        return zoneIdentities.allSatisfy { byID[$0.id] == $0.name }
    }

    public static func diagonalSpine(_ manifest: ArenaManifest) -> Bool {
        ArenaReachability.diagonalSpine(manifest)
    }

    /// Near-orthogonal civic axis (Z-03 → Z-06, shared northing) plus rotated service layer (Z-04 north of civic).
    public static func threeGridCollision(_ manifest: ArenaManifest) -> Bool {
        guard
            let plaza = zone(manifest, "Z-03"),
            let service = zone(manifest, "Z-04"),
            let court = zone(manifest, "Z-06"),
            let spawn = zone(manifest, "Z-01")
        else { return false }
        let civicEastWest = court.center.y == plaza.center.y && court.center.x > plaza.center.x
        let serviceNorth = service.center.y > plaza.center.y && service.center.x > plaza.center.x
        let diagonal = service.center.x > spawn.center.x && service.center.y > spawn.center.y
        return civicEastWest && serviceNorth && diagonal
    }

    public static func wedgeParcels(_ manifest: ArenaManifest) -> Bool {
        guard let wedge = zone(manifest, "Z-01"), let service = zone(manifest, "Z-04") else {
            return false
        }
        let residentialWedge = wedge.halfSize.x != wedge.halfSize.y
        let serviceWedge = service.halfSize.x != service.halfSize.y
        return residentialWedge && serviceWedge
    }

    public static func landmarkSightlines(_ manifest: ArenaManifest) -> Bool {
        let landmarks = spineLandmarks.compactMap { zone(manifest, $0) }
        guard landmarks.count == 4 else { return false }
        let transit = landmarks[0]
        let plaza = landmarks[1]
        let court = landmarks[2]
        let phoenix = landmarks[3]
        let eastward = plaza.center.x > transit.center.x && court.center.x > plaza.center.x
        let northThenSouth = plaza.center.y > transit.center.y
            && court.center.y == plaza.center.y
            && phoenix.center.y < court.center.y
            && phoenix.center.x == court.center.x
        return eastward && northThenSouth
    }

    public static func presentationOmitsProhibitedLabels(
        tutorial: TutorialState = TutorialState(),
        captions: [String] = ["Phoenix Steps open"]
    ) -> Bool {
        let samples = [tutorial.copy] + captions + zoneIdentities.map(\.name)
        return samples.allSatisfy { text in
            let lowered = text.lowercased()
            return !prohibitedPlaceLabels.contains { lowered.contains($0) }
        }
    }

    public static func catalogRejectsLiteralLandmarks(_ catalog: AssetCatalog) -> Bool {
        guard let bridge = catalog.recordsByID["legacy_san_francisco_landmark_bridge_distant_01"] else {
            return false
        }
        let entry = catalog.entries.first { $0.record.assetId == bridge.assetId }
        return entry?.admissionDecision == .rejected && bridge.runtimePath == nil
    }

    /// T807: catalog-wide prohibited landmark, non-SF, seal/logo, and source-bundle audit.
    public static func catalogContentAudit(_ catalog: AssetCatalog) throws -> [String] {
        var violations: [String] = []
        if !catalogRejectsLiteralLandmarks(catalog) {
            violations.append("literal-bridge-not-rejected")
        }
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let bundleIssues = RuntimeBundleFilter.validate(catalog: catalog, reachable: reachable)
        for issue in bundleIssues {
            violations.append(contentAuditToken(issue))
        }
        for entry in catalog.entries {
            let id = entry.record.assetId
            let lowered = id.lowercased()
            if entry.record.runtimePath != nil {
                if lowered.contains("_atlanta_") {
                    violations.append("non-sf-runtime-\(id)")
                }
                if lowered.contains("landmark_bridge") || lowered.contains("_seal_") || lowered.contains("_logo_") {
                    violations.append("prohibited-runtime-\(id)")
                }
            }
            if let notes = entry.record.notes?.lowercased(),
               notes.contains("copied artwork"),
               entry.record.runtimePath != nil
            {
                violations.append("copied-artwork-runtime-\(id)")
            }
        }
        return violations.sorted()
    }

    public static func catalogPassesContentAudit(_ catalog: AssetCatalog) throws -> Bool {
        try catalogContentAudit(catalog).isEmpty
    }

    private static func contentAuditToken(_ issue: RuntimeBundleIssue) -> String {
        switch issue {
        case .legacyEvidenceInBundle(let id): "legacy-bundle-\(id)"
        case .sourceEvidenceInBundle(let id): "source-bundle-\(id)"
        case .unreachableRuntimeRequired(let id): "unreachable-bundle-\(id)"
        case .nonSanFranciscoInBundle(let id): "non-sf-bundle-\(id)"
        case .duplicateBundleAsset(let id): "duplicate-bundle-\(id)"
        }
    }

    private static func zone(_ manifest: ArenaManifest, _ id: String) -> NamedRect? {
        manifest.zones.first { $0.id == id }
    }
}
