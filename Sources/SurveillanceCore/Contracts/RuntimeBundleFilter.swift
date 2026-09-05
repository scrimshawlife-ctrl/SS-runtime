import Foundation

public enum RuntimeBundleIssue: Equatable, Sendable {
    case legacyEvidenceInBundle(String)
    case sourceEvidenceInBundle(String)
    case unreachableRuntimeRequired(String)
    case nonSanFranciscoInBundle(String)
    case duplicateBundleAsset(String)
}

/// T805: project and validate runtime-reachable SS-001 bundle membership.
public enum RuntimeBundleFilter {
    public struct Projection: Equatable, Sendable {
        public var bundleAssetIds: [String]
        public var excludedAssetIds: [String]

        public init(bundleAssetIds: [String], excludedAssetIds: [String]) {
            self.bundleAssetIds = bundleAssetIds
            self.excludedAssetIds = excludedAssetIds
        }
    }

    public static func reachableAssetIds(presentationJSON: Data) throws -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: presentationJSON) as? [String: Any],
              let visuals = root["requiredAssetIds"] as? [String],
              let audio = root["audioEventIds"] as? [String],
              let music = root["musicAssetIds"] as? [String]
        else {
            throw AssetCatalogError.invalidJSON
        }
        return Set(visuals + audio + music)
    }

    /// Frame IDs named by `clip-metadata-001`. A frame a clip plays is
    /// runtime-reachable exactly as a presentation asset ID is, so admitted
    /// actor frames are eligible for the bundle on the same footing.
    public static func reachableClipFrameIds(clipJSON: Data) throws -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: clipJSON) as? [String: Any],
              let clips = root["clips"] as? [[String: Any]]
        else {
            throw AssetCatalogError.invalidJSON
        }
        var ids = Set<String>()
        for clip in clips {
            guard let frames = clip["frameIds"] as? [String] else {
                throw AssetCatalogError.invalidJSON
            }
            ids.formUnion(frames)
        }
        return ids
    }

    public static func reachableAssetIds() throws -> Set<String> {
        try reachableAssetIds(presentationJSON: SpecBundle.contract("presentation-assets-001"))
            .union(reachableClipFrameIds(clipJSON: SpecBundle.contract("clip-metadata-001")))
    }

    public static func project(catalog: AssetCatalog, reachable: Set<String>) -> Projection {
        var bundle: [String] = []
        var excluded: [String] = []
        for entry in catalog.entries {
            let id = entry.record.assetId
            if isBundleEligible(entry, reachable: reachable) {
                bundle.append(id)
            } else {
                excluded.append(id)
            }
        }
        return Projection(
            bundleAssetIds: bundle.sorted(),
            excludedAssetIds: excluded.sorted()
        )
    }

    public static func validate(catalog: AssetCatalog, reachable: Set<String>) -> [RuntimeBundleIssue] {
        var issues: [RuntimeBundleIssue] = []
        var seenBundle = Set<String>()
        for entry in catalog.entries {
            let record = entry.record
            let id = record.assetId
            if isBundleEligible(entry, reachable: reachable) {
                if !seenBundle.insert(id).inserted {
                    issues.append(.duplicateBundleAsset(id))
                }
                continue
            }
            if entry.admissionDecision != .plannedOriginal,
               entry.admissionDecision != .adaptedAdmitted,
               entry.admissionDecision != .originalAccepted
            {
                if record.runtimePath != nil || record.runtimeRequired {
                    issues.append(.legacyEvidenceInBundle(id))
                }
                if id.contains("_atlanta_") || entry.admissionDecision == .excluded {
                    if record.runtimePath != nil {
                        issues.append(.nonSanFranciscoInBundle(id))
                    }
                }
                continue
            }
            if record.runtimeRequired, !reachable.contains(id) {
                issues.append(.unreachableRuntimeRequired(id))
            }
            if let runtimePath = record.runtimePath {
                if runtimePath.hasPrefix("ArtSources/") {
                    issues.append(.sourceEvidenceInBundle(id))
                }
            }
        }
        return issues
    }

    private static func isBundleEligible(_ entry: AssetCatalogEntry, reachable: Set<String>) -> Bool {
        (entry.admissionDecision == .plannedOriginal
            || entry.admissionDecision == .adaptedAdmitted
            || entry.admissionDecision == .originalAccepted)
            && entry.record.runtimeRequired
            && reachable.contains(entry.record.assetId)
            && entry.record.runtimePath?.hasPrefix("ArtSources/") != true
    }
}
